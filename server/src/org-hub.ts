// The org's live feed: every app connection, the latest of every machine, and fan-out of changes.
// Machines report here from their hubs; apps subscribe and send session commands through here.
// The factory (goals, tasks and their agent sessions) lives here too, in this object's SQLite.

import { DurableObject } from "cloudflare:workers";
import { deliver } from "./trackers.ts";
import type { Env } from "./env.ts";
import { PROTOCOL_VERSION, IntegrationKindValues, type ClientMessage, type IntegrationKind, type Presence, type Machine, type MachineUpdate, type AgentLoginStatus, type Member, type RunnerRelease, type RunnerMessage, type ServerToClient, type ServerToRunner, type SessionEnd, type SessionShare, type EndedSession, type GitHubStatus, type PushDevice, type Task, type RunnerMessage_SessionEvents } from "./wire.ts";
import { machineRows, offlineMachine } from "./machines.ts";
import { audit, machineHub } from "./util.ts";
import { maySignIn, recheckEvery, revoked, revokeMember, stillMember, toMember, userToken, type MemberRow } from "./auth.ts";
import { Store } from "./factory/store.ts";
import { Secrets } from "./secrets.ts";
import { Push, deviceId } from "./push.ts";
import { Integrations } from "./integrations/store.ts";
import { Engine, FactoryError } from "./factory/engine.ts";
import { redacted } from "./factory/connectors.ts";
import { aggregatePresence, isMobileClient, type Connection } from "./presence.ts";
import { Intake, type NewRequest } from "./factory/intake.ts";
import { statsWindow, summarize } from "./factory/stats.ts";
import { dayReport } from "./factory/report.ts";
import { release } from "./releases.ts";
import { fromNotice, olderThan, onReport, shown } from "./runner-update.ts";
import { githubAppInfo } from "./github.ts";
import { applySettings } from "./settings.ts";
import { SERVER_VERSION, serverUpdate } from "./version.ts";
import { fetchGitHubStatus, notice } from "./github-status.ts";
import { recipients, refusal, sessionAccess, toClient, watchOnly, type EventSub, type Subscriber } from "./session-events.ts";

/** How often the hub reads the runner releases again while apps are connected. */
const RUNNER_CHECK_EVERY = 3_600_000;
/** How often the hub reads githubstatus.com while apps are connected. */
const GITHUB_STATUS_EVERY = 300_000;

interface Client {
  member: Member;
  subscribed: boolean;
  /** The task this connection's app is showing. */
  viewing?: string | null;
  since?: number;
  /** The iPhone or Android app: it opened the socket with `x-maple-client: mobile`. */
  mobile?: boolean;
  /** The sessions whose native-view events this connection follows (session-events.ts). */
  events?: EventSub[];
}

export class OrgHub extends DurableObject<Env> {
  private store: Store;
  private engine: Engine;
  private push: Push;
  private intake: Intake;
  private secrets: Secrets;
  private integrations: Integrations;
  /** Each machine's runner update (storage `u:<id>`), loaded before anything else runs. */
  private updates = new Map<string, MachineUpdate>();

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      for (const [key, update] of await ctx.storage.list<MachineUpdate>({ prefix: "u:" })) this.updates.set(key.slice(2), update);
    });
    this.store = new Store(ctx.storage.sql);
    this.secrets = new Secrets(ctx.storage.sql, env);
    this.integrations = new Integrations(ctx.storage.sql, env);
    this.intake = new Intake(this.store, {
      broadcast: (request) => this.broadcast({ type: "intake.updated", request }),
      waitUntil: (p) => ctx.waitUntil(p),
      deliver: (replyUrl, text) => deliver(env, replyUrl, text, {
        config: (kind) => this.integrations.config(kind),
        event: (kind, error) => this.integrationEvent(kind, error),
      }),
    });
    this.push = new Push(env, this.store);
    this.engine = new Engine(env, this.store, {
      broadcast: (message) => this.broadcast(message),
      taskSaved: (old, task) => ctx.waitUntil(this.push.taskSaved(old, task, () => this.members()).catch((e) => console.error("push:", e))),
      sendTo: (login, message) => this.sendTo(login, message),
      machines: () => this.machines(),
      members: () => this.members(),
      machineChanged: async (id) => {
        const machine = (await this.machines()).find((m) => m.id === id);
        if (machine) this.broadcast({ type: "machine.updated", machine });
      },
      waitUntil: (p) => ctx.waitUntil(p.catch((e) => console.error("factory:", e))),
      wakeIn: (ms) => ctx.waitUntil(this.wakeAt(Date.now() + ms)),
      slack: {
        token: async () => (await this.integrations.config("slack"))?.botToken ?? null,
        problem: (text) => ctx.waitUntil(this.integrationEvent("slack", text)),
      },
      userToken: (login) => userToken(env, login),
    }, this.intake, this.secrets);
  }

  /** Sets the alarm for `at` unless it's already due sooner: the earliest wake wins. */
  private async wakeAt(at: number) {
    const set = await this.ctx.storage.getAlarm();
    if (set == null || set > at) await this.ctx.storage.setAlarm(at);
  }

  /** Webhooks can't reach every server (a laptop's, say), so CI that's still running is read again;
   *  and a scheduled task whose time came starts even if no machine reports in. */
  async alarm() {
    await applySettings(this.env);
    await this.recheckConnected();
    await this.engine.pollCI();
    await this.engine.mergeDue();
    await this.engine.checkBudgets();
    await this.engine.runRecurring();
    await this.engine.pump();
    await this.engine.slack.sweep();
    await this.checkRunnerRelease();
    await this.checkGitHubStatus();
  }

  /** Apps live on one socket and rarely make a request, so the request-time membership check would miss them:
   *  while any are connected, asks again about the people behind them once their check is stale, and cuts off
   *  anyone who has left. */
  private async recheckConnected() {
    const logins = new Set(this.ctx.getWebSockets("client").map((ws) => (ws.deserializeAttachment() as Client).member.login));
    if (!logins.size) return;
    for (const login of logins) {
      const row = await this.env.DB.prepare("SELECT * FROM members WHERE login = ?").bind(login).first<MemberRow>();
      const still = row && (await stillMember(this.env, row, false));
      if (!still) await this.cutOff(login);
      else if (still.role !== row.role) await this.memberChanged(login);
    }
    await this.armRecheck();
  }

  /** The next membership sweep, while apps are connected: at most a second apart (the e2e tests check every time). */
  private async armRecheck() {
    await this.wakeAt(Date.now() + Math.max(recheckEvery(this.env), 1000));
  }

  /** While apps are connected, reads the runner releases again hourly and tells the apps when they
   *  changed, so a new runner shows without reconnecting. An idle org isn't woken for it. */
  private async checkRunnerRelease() {
    if (!this.ctx.getWebSockets("client").length) return;
    let checked = (await this.ctx.storage.get<number>("runner:checkedAt")) ?? 0;
    if (Date.now() - checked >= RUNNER_CHECK_EVERY) {
      await this.refreshRunnerRelease();
      checked = Date.now();
      await this.ctx.storage.put("runner:checkedAt", checked);
    }
    await this.armRunnerCheck(checked);
  }

  /** Reads the runner releases again, past the cache, and tells the apps if they changed. */
  private async refreshRunnerRelease() {
    const runnerLatest = await this.runnerLatest(true);
    const runnerReleases = await this.runnerReleases(true);
    const seen = JSON.stringify({ runnerLatest, runnerReleases });
    if (seen !== (await this.ctx.storage.get<string>("runner:seen"))) {
      await this.ctx.storage.put("runner:seen", seen);
      this.broadcast({ type: "runner.released", runnerLatest, runnerReleases });
    }
    return runnerLatest;
  }

  /** The next runner release check: an hour after the last one, never later than an hour from now. */
  private async armRunnerCheck(checked?: number) {
    checked ??= (await this.ctx.storage.get<number>("runner:checkedAt")) ?? Date.now();
    const now = Date.now();
    await this.wakeAt(Math.min(Math.max(checked + RUNNER_CHECK_EVERY, now + 1000), now + RUNNER_CHECK_EVERY));
  }

  /** While apps are connected, reads githubstatus.com every five minutes and tells the apps when GitHub's
   *  incidents change. A read that fails keeps the last known status. An idle org isn't woken for it. */
  private async checkGitHubStatus() {
    if (!this.ctx.getWebSockets("client").length) return;
    let checked = (await this.ctx.storage.get<number>("ghstatus:checkedAt")) ?? 0;
    if (Date.now() - checked >= GITHUB_STATUS_EVERY) {
      checked = Date.now();
      await this.ctx.storage.put("ghstatus:checkedAt", checked);
      const read = await fetchGitHubStatus(this.env.GITHUB_STATUS_URL || undefined);
      if (read) {
        const status = notice(read);
        const before = await this.githubStatus();
        const same = (s: GitHubStatus | null) => JSON.stringify(s && { ...s, checkedAt: 0 });
        if (same(status) !== same(before)) {
          await this.ctx.storage.put("ghstatus:seen", status);
          this.broadcast({ type: "github.status", status });
        }
      }
    }
    await this.armGitHubStatusCheck(checked);
  }

  /** The last githubstatus.com notice the apps were told: null while all is clear. */
  private async githubStatus(): Promise<GitHubStatus | null> {
    return (await this.ctx.storage.get<GitHubStatus | null>("ghstatus:seen")) ?? null;
  }

  /** The next githubstatus.com read: five minutes after the last one, never later than five minutes from now. */
  private async armGitHubStatusCheck(checked?: number) {
    checked ??= (await this.ctx.storage.get<number>("ghstatus:checkedAt")) ?? 0;
    const now = Date.now();
    await this.wakeAt(Math.min(Math.max(checked + GITHUB_STATUS_EVERY, now + 1000), now + GITHUB_STATUS_EVERY));
  }

  async fetch(request: Request): Promise<Response> {
    await applySettings(this.env);
    const url = new URL(request.url);
    // The Worker's webhook handlers: an integration's settings (decrypted; never sent past the Worker),
    // and how its last event went.
    const integration = /^\/integrations\/([a-z]+)\/(config|event)$/.exec(url.pathname);
    if (integration && IntegrationKindValues.includes(integration[1] as IntegrationKind)) {
      const kind = integration[1] as IntegrationKind;
      if (integration[2] === "config") return Response.json(await this.integrations.config(kind));
      const { error } = (await request.json()) as { error?: string | null };
      await this.integrationEvent(kind, error ?? undefined);
      return new Response(null, { status: 204 });
    }
    switch (url.pathname) {
      case "/connect": {
        const member = JSON.parse(request.headers.get("x-member") ?? "null") as Member;
        const pair = new WebSocketPair();
        this.ctx.acceptWebSocket(pair[1], ["client"]);
        pair[1].serializeAttachment({ member, subscribed: false, mobile: isMobileClient(request.headers.get("x-maple-client")) } satisfies Client);
        await this.armRunnerCheck();
        await this.armGitHubStatusCheck();
        await this.armRecheck();
        return new Response(null, { status: 101, webSocket: pair[0] });
      }
      case "/machine": {
        const machine = (await request.json()) as Machine;
        const before = await this.ctx.storage.get<Machine>(`m:${machine.id}`);
        await this.ctx.storage.put(`m:${machine.id}`, machine);
        const updated = onReport(this.updates.get(machine.id), machine);
        if (updated) await this.setUpdate(machine.id, updated);
        this.broadcast({ type: "machine.updated", machine: this.withSettings(machine) });
        // Coming online, or a session ending, can free a slot for waiting tasks.
        // So can a pause running out, so health reports retry whatever's waiting.
        if (machine.online) await this.engine.reap(machine, !before?.online);
        // Its running @Maple asks won't be answered now: their threads hear it.
        if (before?.online && !machine.online) await this.engine.slack.machineGone(machine.id, machine.name);
        if (machine.online && (!before?.online || before.sessions.length > machine.sessions.length || this.engine.waiting())) await this.engine.pump();
        // Back after being offline: the runner (maybe restarted) lost its event subscriptions, so ask again.
        if (machine.online && before && !before.online) this.ctx.waitUntil(this.resubscribe(machine.id));
        return new Response(null, { status: 204 });
      }
      case "/ended": {
        const { machine, end } = (await request.json()) as { machine: string; end: SessionEnd };
        this.broadcast({ type: "session.ended", machine, end });
        this.dropSubscriptions((e) => e.machine === machine && e.id === end.id);
        await this.engine.fromRunner(machine, { type: "session.ended", end });
        return new Response(null, { status: 204 });
      }
      case "/session-events": {
        // A runner's native-view events: the backfill to the connection that asked, live ones to every
        // subscriber, each only while the machine as it stands now still lets them watch.
        const { machine, msg } = (await request.json()) as { machine: string; msg: RunnerMessage_SessionEvents };
        const stored = await this.ctx.storage.get<Machine>(`m:${machine}`);
        const out = toClient(msg, machine);
        for (const ws of recipients(stored, msg, this.subscribers())) this.send(ws, out);
        return new Response(null, { status: 204 });
      }
      case "/runner": {
        // A runner message about the factory, from its machine's hub; `mcp.request`s get their answer back.
        const { machine, msg } = (await request.json()) as { machine: string; msg: RunnerMessage };
        return Response.json(await this.engine.fromRunner(machine, msg));
      }
      case "/notice": {
        const { machine, msg } = (await request.json()) as { machine: string; msg: { type: string; message?: string | null; state?: string; version?: string | null; status?: AgentLoginStatus } };
        if (msg.type === "session.error" && msg.message) this.broadcast({ type: "error", message: `${machine}: ${msg.message}`, requestId: null });
        if (msg.type === "update.status") {
          // The machine's card shows where it is; a toast only for a failure, which is worth noticing elsewhere.
          const known = (await this.machines()).find((m) => m.id === machine);
          const update = fromNotice(this.updates.get(machine), msg, known?.version ?? null);
          if (update) await this.setUpdate(machine, update, true);
          const name = known?.name ?? machine;
          if (update?.state === "failed") {
            this.broadcast({ type: "toast", text: `${name} couldn't update its runner${msg.message ? `: ${msg.message}` : "."}`, taskId: null });
          }
          if (msg.state === "newer") {
            // A newer release came out after the one they were shown; nothing was installed. The card goes back
            // to offering an update, now to the newer release, and pressing it is their go-ahead.
            this.updates.delete(machine);
            await this.ctx.storage.delete(`u:${machine}`);
            await this.refreshRunnerRelease();
            const after = (await this.machines()).find((m) => m.id === machine);
            if (after) this.broadcast({ type: "machine.updated", machine: after });
            const version = msg.version ?? "a newer release";
            this.broadcast({ type: "toast", text: `${name}: runner ${version} is out now; press Update again to install it.`, taskId: null });
          }
        }
        if (msg.type === "agent.login_status" && msg.status) {
          // The one-time code is a credential: only the machine's owner sees it, never a broadcast.
          const owner = (await this.machines()).find((m) => m.id === machine)?.owner;
          if (owner) this.sendTo(owner, { type: "machine.agent_login", machine, status: msg.status });
        }
        return new Response(null, { status: 204 });
      }
      case "/removed": {
        const id = await request.text();
        await this.ctx.storage.delete([`m:${id}`, `u:${id}`]);
        this.updates.delete(id);
        this.broadcast({ type: "machine.removed", id });
        return new Response(null, { status: 204 });
      }
      case "/push-devices": return Response.json({ devices: this.store.pushDeviceCount() });
      case "/push-changed": {
        // push.ts turned the relay on or off: read the credential again now, not in 30 s.
        this.push.forget();
        return new Response(null, { status: 204 });
      }
      case "/revoked": {
        // auth.ts revoked someone (they left the org): their apps and terminals close now.
        await this.cutOff(await request.text());
        return new Response(null, { status: 204 });
      }
      case "/member-changed": {
        // auth.ts's re-check found GitHub changed someone's role.
        await this.memberChanged(await request.text());
        return new Response(null, { status: 204 });
      }
      case "/machines": return Response.json(await this.machines());
      case "/icon": {
        // The Worker stored (or is removing) the image and checked it's an admin; this keeps the id and tells the apps.
        const { id } = (await request.json()) as { id: string | null };
        const previous = this.store.icon();
        this.store.saveIcon(id);
        this.broadcast({ type: "icon.updated", icon: id ? `/icon/${id}` : null });
        return Response.json({ previous });
      }
      case "/name": {
        // The Worker checked it's an admin and the name's length; this keeps it and tells the apps.
        const { name } = (await request.json()) as { name: string | null };
        this.store.saveName(name);
        this.broadcast({ type: "name.updated", name });
        return new Response(null, { status: 204 });
      }
      case "/dev/alarm": {
        // Local dev (the Worker checked): run the alarm now, as if `stale` the runner and GitHub status checks were due.
        if (new URL(request.url).searchParams.has("stale")) await this.ctx.storage.delete(["runner:checkedAt", "ghstatus:checkedAt"]);
        await this.alarm();
        return Response.json({ alarm: await this.ctx.storage.getAlarm(), now: Date.now() });
      }
      case "/dev/age-tasks": {
        // Local dev (the Worker checked), for e2e-snapshot-window: set tasks' state and updatedAt as if they finished long ago.
        const { tasks } = (await request.json()) as { tasks: { id: string; state: Task["state"]; updatedAt: number }[] };
        for (const t of tasks) {
          const task = this.store.task(t.id);
          if (task) this.store.saveTask({ ...task, state: t.state, updatedAt: t.updatedAt });
        }
        return new Response(null, { status: 204 });
      }
      case "/dev/age-sessions": {
        // Local dev (the Worker checked), for a task's time budget: its sessions (and any over-budget nudge) as if `ms` earlier.
        const { task, ms } = (await request.json()) as { task: string; ms: number };
        this.store.ageSessions(task, ms);
        const priv = this.store.private(task);
        if (priv.budgetAskedAt != null) this.store.savePrivate(task, { ...priv, budgetAskedAt: priv.budgetAskedAt - ms });
        return new Response(null, { status: 204 });
      }
      case "/intake": {
        // A new request from an integration or the API (the Worker checked who's asking).
        const input = (await request.json()) as NewRequest;
        return Response.json(this.intake.create(input));
      }
      case "/intake/reply": {
        const { id, replyUrl, author, text } = (await request.json()) as { id?: string; replyUrl?: string; author: string; text: string };
        const updated = replyUrl ? this.intake.replyFrom(replyUrl, author, text) : this.intake.reply(id ?? "", author, text);
        return updated ? Response.json(updated) : new Response("No such request.", { status: 404 });
      }
      // @Maple, from slack.ts (which checked Slack's signature): an event seen before, a mention to answer,
      // a click, and Maple joining a channel (or `@Maple goals`).
      case "/slack/seen": {
        const { id } = (await request.json()) as { id: string };
        return Response.json({ seen: this.engine.slack.seen(id) });
      }
      case "/slack/ask": {
        await this.engine.slack.ask(await request.json());
        // The status line's last mention.
        await this.integrationEvent("slack");
        return new Response(null, { status: 204 });
      }
      case "/slack/action": {
        await this.engine.slack.action(await request.json());
        return new Response(null, { status: 204 });
      }
      case "/slack/joined": {
        const { channel, threadTs } = (await request.json()) as { channel: string; threadTs?: string };
        await this.engine.slack.picker(channel, threadTs);
        this.broadcast({ type: "integrations.updated", integrations: await this.integrationList() });
        return new Response(null, { status: 204 });
      }
      case "/github": {
        await this.engine.fromGitHub(await request.json());
        return new Response(null, { status: 204 });
      }
      case "/github/repos": {
        await this.engine.refreshRepos();
        return new Response(null, { status: 204 });
      }
      case "/usage/goals": {
        // Agent time per goal over the last week: which goals the machines' plans went on.
        const rows = this.store.sessionTime(Date.now() - 7 * 86_400_000);
        const goals = new Map<string, { goal: string; name: string; ms: number; tasks: { id: string; ms: number }[] }>();
        for (const r of rows) {
          const g = goals.get(r.goal) ?? { goal: r.goal, name: this.store.goal(r.goal)?.name ?? "No goal", ms: 0, tasks: [] };
          g.ms += r.ms;
          g.tasks.push({ id: r.task, ms: r.ms });
          goals.set(r.goal, g);
        }
        const list = [...goals.values()].sort((a, b) => b.ms - a.ms);
        for (const g of list) g.tasks.sort((a, b) => b.ms - a.ms);
        return Response.json(list);
      }
      case "/stats": {
        const summary = this.stats(Number(url.searchParams.get("days")), url.searchParams.get("goal"));
        if (url.searchParams.get("raw") !== "1") return Response.json(summary);
        const events = this.store.statEvents(summary.since).filter((e) => !summary.goal || e.goal === summary.goal);
        return Response.json({ ...summary, events });
      }
      case "/report": {
        // The Worker passes who's asking as `login`; since and until are their local day's bounds (ms).
        const login = url.searchParams.get("login") ?? "";
        const since = Number(url.searchParams.get("since"));
        const until = Number(url.searchParams.get("until"));
        if (!login || !Number.isFinite(since) || !Number.isFinite(until) || until <= since) return new Response("Pass since and until (ms), since first.", { status: 400 });
        return Response.json(this.report(login, since, until));
      }
      case "/threads": {
        try {
          return Response.json(await this.engine.threads(url.searchParams.get("task") ?? ""));
        } catch (e) {
          return new Response(e instanceof Error ? e.message : String(e), { status: 502 });
        }
      }
      case "/commits": return Response.json(this.engine.commits(url.searchParams.get("task") ?? ""));
      case "/diff": {
        const patch = this.engine.patch(url.searchParams.get("task") ?? "", url.searchParams.get("commit"));
        return patch == null ? new Response("No diff yet.", { status: 404 }) : new Response(patch, { headers: { "content-type": "text/x-diff; charset=utf-8" } });
      }
    }
    return new Response("Not found.", { status: 404 });
  }

  /** Every integration as the apps see it, with Slack's channels. */
  private integrationList() {
    return this.integrations.list((kind, values) => {
      if (kind !== "slack") return null;
      if (!("botToken" in values)) return "Slash command only: add the bot token so people can mention @Maple.";
      return this.engine.slack.status();
    });
  }

  /** How an integration's last event went, told to the apps. */
  private async integrationEvent(kind: IntegrationKind, error?: string) {
    if (error) this.integrations.noteError(kind, error);
    else this.integrations.noteEvent(kind);
    this.broadcast({ type: "integrations.updated", integrations: await this.integrationList() });
  }

  /** The factory icon's link, if it has one. */
  private iconPath(): string | null {
    const id = this.store.icon();
    return id ? `/icon/${id}` : null;
  }

  /** The statistics over the last `days` (1, 3, 7, 30 or 90; anything else reads as 30). */
  private stats(days: number, goal?: string | null) {
    const window = statsWindow(days);
    const at = Date.now();
    const since = at - window * 86_400_000;
    // The window's rows, and the earlier review rounds of the tasks it merged (rounds per merge counts them all).
    const recent = this.store.statEvents(since);
    const merged = [...new Set(recent.filter((e) => e.kind === "merged").map((e) => e.task))];
    const events = [...this.store.statRoundsBefore(merged, since), ...recent];
    const costs = this.store.sessionCosts(since, goal || null);
    return summarize(events, this.store.tasks(), { days: window, goal: goal || null, goals: this.store.goals(), now: at, costs });
  }

  /** `login`'s day report for [since, until) (at most two days, so a stray range can't read the whole log). */
  private report(login: string, since: number, until: number) {
    const end = Math.min(until, since + 2 * 86_400_000);
    const events = this.store.statEvents(since).filter((e) => e.at < end);
    return dayReport(login, since, end, this.store.tasks(), events, this.store.goals(), this.env.PUBLIC_URL ?? "");
  }

  private latest: { version: string | null; at: number } | null = null;
  private changes: { releases: RunnerRelease[]; at: number } | null = null;

  /** The newest released runner, from the releases manifest (the org's bucket, else the feed); read again every ten minutes, or now when `force`. */
  private async runnerLatest(force = false): Promise<string | null> {
    if (!force && this.latest && Date.now() - this.latest.at < 600_000) return this.latest.version;
    let version: string | null = null;
    try {
      const manifest = await release(this.env, "maple-runner/latest.json");
      version = manifest ? ((await manifest.json()) as { version?: string }).version ?? null : null;
    } catch {}
    this.latest = { version, at: Date.now() };
    return version;
  }

  /** The runner releases' notes, newest first (maple-runner/changes.json); read again every ten minutes, or now when `force`. */
  private async runnerReleases(force = false): Promise<RunnerRelease[]> {
    if (!force && this.changes && Date.now() - this.changes.at < 600_000) return this.changes.releases;
    let releases: RunnerRelease[] = [];
    try {
      const file = await release(this.env, "maple-runner/changes.json");
      const list = file ? ((await file.json()) as { releases?: unknown }).releases : null;
      if (Array.isArray(list)) {
        releases = list.filter((r): r is RunnerRelease => typeof r?.version === "string")
          .map((r) => ({ version: r.version, publishedAt: r.publishedAt ?? null, notes: r.notes ?? null }));
      }
    } catch {}
    this.changes = { releases, at: Date.now() };
    return releases;
  }

  /** Moves a machine's runner update along, and tells the apps when `broadcast` (else the caller does). */
  private async setUpdate(id: string, update: MachineUpdate, broadcast = false) {
    this.updates.set(id, update);
    await this.ctx.storage.put(`u:${id}`, update);
    if (!broadcast) return;
    const machine = (await this.machines()).find((m) => m.id === id);
    if (machine) this.broadcast({ type: "machine.updated", machine });
  }

  /** Every enrolled machine, live where its hub has reported. */
  private async machines(): Promise<Machine[]> {
    const live = await this.ctx.storage.list<Machine>({ prefix: "m:" });
    const rows = await machineRows(this.env);
    // Removed machines drop out here: D1 is the list, the hubs only add what's live.
    return rows.map((row) => {
      const reported = live.get(`m:${row.id}`);
      return this.withSettings(reported ? { ...reported, name: row.name ?? row.id, owner: row.owner } : offlineMachine(row));
    });
  }

  /** A machine with the factory's settings for it, and the capacity they come to. */
  private withSettings(machine: Machine): Machine {
    const settings = this.store.settings(machine.id);
    return { ...machine, settings, capacity: this.engine.capacity({ ...machine, settings }), update: shown(this.updates.get(machine.id)) };
  }

  private async members(): Promise<Member[]> {
    const { results } = await this.env.DB.prepare("SELECT * FROM members ORDER BY login").all<MemberRow>();
    return results.map(toMember);
  }

  /** Grants or takes back an admin grant; GitHub's owners stay admins whatever happens here. The reason it's refused, if it is. */
  private async setAdmin(by: Member, login: string, grant: boolean): Promise<string | null> {
    if (by.role !== "admin") return "Only admins can change who's an admin.";
    const row = await this.env.DB.prepare("SELECT * FROM members WHERE login = ? COLLATE NOCASE").bind(login).first<MemberRow>();
    if (!row) return `${login} hasn't signed in to this factory yet.`;
    const target = toMember(row);
    if (grant && target.role === "admin") return `${target.login} is already an admin.`;
    if (grant) {
      // A grant to someone who's left can't let them back in, but it shouldn't look as if it does.
      let allowed: boolean;
      try {
        allowed = await maySignIn(this.env, target.login);
      } catch (e) {
        return `Couldn't check with GitHub that ${target.login} may still sign in: ${(e as Error).message}`;
      }
      if (!allowed) {
        const gone = this.env.GITHUB_OWNER_TYPE === "User" ? "isn't on GITHUB_ALLOWED_LOGINS any more" : `isn't in ${this.env.GITHUB_ORG} any more`;
        return `${target.login} ${gone}, so they can't sign in to this factory.`;
      }
    }
    if (!grant) {
      if (target.adminSource === "github") return `${target.login} owns the GitHub organization, so they're an admin there; change it on GitHub.`;
      if (target.role !== "admin") return `${target.login} isn't an admin.`;
      if (target.login === by.login) return "You can't take back your own admin; ask another admin.";
    }
    await this.env.DB.prepare("UPDATE members SET admin_granted_by = ?, admin_granted_at = ? WHERE login = ?")
      .bind(grant ? by.login : null, grant ? Date.now() : null, row.login).run();
    await audit(this.env, by.login, grant ? "admin.granted" : "admin.revoked", row.login);
    await this.memberChanged(row.login);
    return null;
  }

  /** Someone's role changed (an admin grant, or GitHub's role at a re-check): their open apps act with it straight
   *  away, without reconnecting; if they're no longer an admin, the terminals they opened on others' machines as
   *  one close (their own stay open); and everyone sees the members change. */
  private async memberChanged(login: string) {
    const members = await this.members();
    const updated = members.find((m) => m.login === login);
    if (!updated) return;
    for (const ws of this.ctx.getWebSockets("client")) {
      const c = ws.deserializeAttachment() as Client;
      if (c.member.login === login) ws.serializeAttachment({ ...c, member: updated });
    }
    if (updated.role !== "admin") await this.dropViewers(login, "admin");
    this.broadcast({ type: "members.updated", members });
  }

  /** An admin's "Revoke access": signs someone out everywhere now. The reason it's refused, if it is. */
  private async revokeAccess(by: Member, login: string): Promise<string | null> {
    if (by.role !== "admin") return "Only admins can revoke someone's access.";
    const row = await this.env.DB.prepare("SELECT * FROM members WHERE login = ? COLLATE NOCASE").bind(login).first<MemberRow>();
    if (!row) return `${login} hasn't signed in to this factory.`;
    const target = toMember(row);
    if (target.login === by.login) return "You can't revoke your own access.";
    if (target.adminSource === "github") return `${target.login} owns the GitHub organization; remove them on GitHub.`;
    await revokeMember(this.env, row.login, by.login, false);
    await this.cutOff(row.login);
    return null;
  }

  /** Someone's push devices as the apps see them: never the token. */
  private async pushDevices(login: string): Promise<PushDevice[]> {
    return Promise.all(this.store.pushDevices(login).map(async (d) => ({ id: await deviceId(d.token), platform: d.platform, environment: d.environment, createdAt: d.createdAt, lastSeen: d.lastSeen })));
  }

  /** Closes a revoked person's feed sockets and terminals, and tells everyone the members changed. */
  private async cutOff(login: string) {
    this.store.removePushDevices(login);
    for (const ws of this.ctx.getWebSockets("client")) {
      if ((ws.deserializeAttachment() as Client).member.login === login) ws.close(4003, "access revoked");
    }
    await this.dropViewers(login);
    this.broadcast({ type: "members.updated", members: await this.members() });
  }

  /** Asks every machine to close `login`'s terminals (with `role`, only those they opened with that role). */
  private async dropViewers(login: string, role?: string) {
    const query = new URLSearchParams({ login, ...(role ? { role } : {}) });
    await Promise.all((await machineRows(this.env)).map((m) =>
      machineHub(this.env, m.id).fetch(`https://hub/drop-viewers?${query}`, { method: "POST" })));
  }

  private async recentEnds(): Promise<EndedSession[]> {
    const since = Date.now() - 7 * 24 * 3600 * 1000;
    const { results } = await this.env.DB.prepare("SELECT * FROM session_ends WHERE at > ? AND ended_by IS NOT 'factory' ORDER BY at DESC LIMIT 20").bind(since).all<{
      id: string; machine: string; cause: SessionEnd["cause"]; code: number | null; signal: string | null; detail: string | null; at: number; last_output: string; ended_by: string | null;
    }>();
    return results.map((r) => ({
      machine: r.machine,
      end: { id: r.id, cause: r.cause, code: r.code, signal: r.signal, detail: r.detail, at: r.at, lastOutput: JSON.parse(r.last_output), by: r.ended_by },
    }));
  }

  /** One entry per person with the app open: the most recent of their connections' views, and whether they're only on a phone. */
  private online(except?: WebSocket): Presence[] {
    const connections: Connection[] = [];
    for (const ws of this.ctx.getWebSockets("client")) {
      if (ws === except) continue;
      const c = ws.deserializeAttachment() as Client;
      if (c.subscribed) connections.push({ login: c.member.login, viewing: c.viewing, since: c.since, mobile: c.mobile });
    }
    return aggregatePresence(connections);
  }

  async webSocketClose(ws: WebSocket) {
    this.broadcast({ type: "presence", online: this.online(ws) });
    const events = (ws.deserializeAttachment() as Client | null)?.events ?? [];
    for (const sub of events) await this.stopIfUnwatched(sub.machine, sub.id, ws);
  }

  /** Connections following some session's events. */
  private subscribers(except?: WebSocket): Subscriber<WebSocket>[] {
    const out: Subscriber<WebSocket>[] = [];
    for (const ws of this.ctx.getWebSockets("client")) {
      if (ws === except) continue;
      const c = ws.deserializeAttachment() as Client;
      if (c.events?.length) out.push({ conn: ws, member: c.member, events: c.events });
    }
    return out;
  }

  /** Forgets the subscriptions `drop` matches, on every connection (a session that ended, say). */
  private dropSubscriptions(drop: (e: EventSub) => boolean) {
    for (const { conn, events } of this.subscribers()) {
      if (!events.some(drop)) continue;
      const c = conn.deserializeAttachment() as Client;
      conn.serializeAttachment({ ...c, events: events.filter((e) => !drop(e)) });
    }
  }

  /** Tells the runner to stop sending a session's events once no connection follows them. */
  private async stopIfUnwatched(machine: string, id: string, except?: WebSocket) {
    if (this.subscribers(except).some((s) => s.events.some((e) => e.machine === machine && e.id === id))) return;
    const command: ServerToRunner = { type: "session.events.subscribe", id, stop: true };
    await machineHub(this.env, machine).fetch("https://hub/command", { method: "POST", body: JSON.stringify(command) }).catch(() => {});
  }

  /** Asks the runner again for every session someone follows on `machine`, each with a fresh nonce; events
   *  have stable ids, so apps drop the repeated backfill's duplicates. */
  private async resubscribe(machine: string) {
    for (const { conn } of this.subscribers()) {
      const c = conn.deserializeAttachment() as Client;
      const events = (c.events ?? []).map((e) => (e.machine === machine ? { ...e, nonce: crypto.randomUUID() } : e));
      conn.serializeAttachment({ ...c, events });
      for (const e of events.filter((e) => e.machine === machine)) {
        const command: ServerToRunner = { type: "session.events.subscribe", id: e.id, nonce: e.nonce };
        await machineHub(this.env, machine).fetch("https://hub/command", { method: "POST", body: JSON.stringify(command) }).catch(() => {});
      }
    }
  }

  async webSocketError(ws: WebSocket) {
    await this.webSocketClose(ws);
  }

  private send(ws: WebSocket, message: ServerToClient) {
    try {
      ws.send(JSON.stringify(message));
    } catch {
      // The socket closed under us; its close handler tidies up.
    }
  }

  /** To one person's apps only (their notes, say). */
  private sendTo(login: string, message: ServerToClient) {
    for (const ws of this.ctx.getWebSockets("client")) {
      const c = ws.deserializeAttachment() as Client;
      if (c.subscribed && c.member.login === login) this.send(ws, message);
    }
  }

  private broadcast(message: ServerToClient) {
    for (const ws of this.ctx.getWebSockets("client")) {
      if ((ws.deserializeAttachment() as Client).subscribed) this.send(ws, message);
    }
  }

  async webSocketMessage(ws: WebSocket, raw: string | ArrayBuffer) {
    if (typeof raw !== "string") return;
    await applySettings(this.env);
    const client = ws.deserializeAttachment() as Client;
    const msg = JSON.parse(raw) as ClientMessage;
    switch (msg.type) {
      case "presence":
        ws.serializeAttachment({ ...client, viewing: msg.viewing ?? null, since: Date.now() });
        this.broadcast({ type: "presence", online: this.online() });
        return;
      case "subscribe": {
        const window = this.store.snapshotTasks();
        ws.serializeAttachment({ ...client, subscribed: true, since: Date.now() });
        this.broadcast({ type: "presence", online: this.online() });
        this.send(ws, {
          type: "snapshot",
          org: this.env.GITHUB_ORG || "local",
          me: client.member,
          members: await this.members(),
          machines: await this.machines(),
          ended: await this.recentEnds(),
          goals: this.store.goals(),
          tasks: window.tasks,
          tallies: this.store.tallies(),
          olderTasks: window.left,
          policy: this.store.policy(),
          acceptances: this.store.acceptances(),
          prompts: this.store.prompts(),
          connectors: redacted(this.store.connectors()),
          integrations: await this.integrationList(),
          online: this.online(),
          notes: this.store.notes(client.member.login),
          follows: this.store.follows(client.member.login),
          quietHours: this.store.quietHours(client.member.login),
          intake: this.intake.list(),
          secrets: this.secrets.list(),
          repos: this.store.repos(),
          repoOwners: this.store.repoOwners(),
          githubApp: githubAppInfo(this.env),
          scripts: this.store.repoScripts(),
          setupRuns: this.engine.setupRuns(),
          scoutRuns: this.engine.scoutRuns(),
          recurring: this.engine.recurring(),
          runnerLatest: await this.runnerLatest(),
          runnerReleases: await this.runnerReleases(),
          serverVersion: SERVER_VERSION,
          serverUpdate: client.member.role === "admin" ? await serverUpdate(this.env) : null,
          githubStatus: await this.githubStatus(),
          icon: this.iconPath(),
          name: this.store.name(),
          protocolVersion: PROTOCOL_VERSION,
        });
        // The app's repos change on GitHub's side; read them again when they're an hour old.
        if (Date.now() - this.store.reposAt() > 3_600_000) this.ctx.waitUntil(this.engine.refreshRepos().catch(() => {}));
        return;
      }
      case "tasks.older": {
        // Finished tasks the snapshot left out, for whoever asked; nothing changed, so nothing to broadcast.
        const page = this.store.olderTasks(msg.goal ?? null, msg.before ?? null, msg.beforeId ?? null, msg.limit ?? null);
        this.send(ws, { type: "tasks.page", goal: msg.goal ?? null, tasks: page.tasks, more: page.more });
        return;
      }
      case "task.get": {
        const task = this.store.task(msg.id);
        if (!task) return this.send(ws, { type: "error", message: `No task ${msg.id}.`, requestId: `task.get:${msg.id}` });
        this.send(ws, { type: "task.updated", task });
        return;
      }
      case "session.open":
      case "session.kill":
      case "session.resize": {
        const machine = (await this.machines()).find((m) => m.id === msg.machine);
        if (!machine) return this.send(ws, { type: "error", message: `No machine ${msg.machine}.`, requestId: null });
        // Starting, ending and resizing sessions is for the machine's owner (and admins), as its terminals are.
        if (machine.owner !== client.member.login && client.member.role !== "admin") {
          const what = msg.type === "session.resize" ? "resize sessions" : "start or end sessions";
          return this.send(ws, { type: "error", message: `Only ${machine.owner} or an admin can ${what} on ${machine.name}.`, requestId: null });
        }
        let command: ServerToRunner;
        if (msg.type === "session.open") {
          command = { type: "session.open", id: crypto.randomUUID(), agent: msg.agent, cwd: msg.cwd, cols: msg.cols, rows: msg.rows, prompt: msg.prompt ?? null, resume: false, taskId: null, connectors: this.engine.connectors() };
          await audit(this.env, client.member.login, "session.opened", msg.machine, { agent: msg.agent, cwd: msg.cwd, id: command.id });
        } else if (msg.type === "session.kill") {
          command = { type: "session.kill", id: msg.id };
          await audit(this.env, client.member.login, "session.killed", msg.machine, { id: msg.id });
        } else {
          command = { type: "session.resize", id: msg.id, cols: msg.cols, rows: msg.rows };
        }
        const res = await machineHub(this.env, msg.machine).fetch("https://hub/command", {
          method: "POST",
          body: JSON.stringify(command),
          headers: { "x-by": client.member.login },
        });
        if (!res.ok) this.send(ws, { type: "error", message: await res.text(), requestId: null });
        return;
      }
      case "session.subscribeEvents":
      case "session.sendInput": {
        // The terminal's rule (session-events.ts): owner and admins type, a share watches (or types with canType).
        const machine = (await this.machines()).find((m) => m.id === msg.machine);
        if (!machine) return this.send(ws, { type: "error", message: `No machine ${msg.machine}.`, requestId: null });
        if (!machine.sessions.some((s) => s.session.id === msg.id)) return this.send(ws, { type: "error", message: "That session has ended.", requestId: null });
        const access = sessionAccess(machine, msg.id, client.member);
        if (!access) return this.send(ws, { type: "error", message: refusal(machine), requestId: null });
        let command: ServerToRunner;
        if (msg.type === "session.sendInput") {
          // Watching only: refused, and the events keep streaming.
          if (access !== "type") return this.send(ws, { type: "error", message: watchOnly(machine), requestId: null });
          command = { type: "session.input", id: msg.id, input: msg.input, by: client.member.login };
        } else {
          // One subscription per connection and session; a new one replaces it, with a fresh nonce for its backfill.
          const nonce = crypto.randomUUID();
          const now = ws.deserializeAttachment() as Client;
          const events = (now.events ?? []).filter((e) => !(e.machine === machine.id && e.id === msg.id));
          ws.serializeAttachment({ ...now, events: [...events, { machine: machine.id, id: msg.id, nonce }] });
          command = { type: "session.events.subscribe", id: msg.id, since: msg.since ?? null, epoch: msg.epoch ?? null, limit: msg.limit ?? null, nonce };
        }
        const res = await machineHub(this.env, machine.id).fetch("https://hub/command", { method: "POST", body: JSON.stringify(command), headers: { "x-by": client.member.login } });
        if (!res.ok) this.send(ws, { type: "error", message: await res.text(), requestId: null });
        return;
      }
      case "session.unsubscribeEvents": {
        const now = ws.deserializeAttachment() as Client;
        const events = now.events ?? [];
        if (!events.some((e) => e.machine === msg.machine && e.id === msg.id)) return;
        ws.serializeAttachment({ ...now, events: events.filter((e) => !(e.machine === msg.machine && e.id === msg.id)) });
        await this.stopIfUnwatched(msg.machine, msg.id);
        return;
      }
      case "session.share": {
        const machine = (await this.machines()).find((m) => m.id === msg.machine);
        if (!machine) return this.send(ws, { type: "error", message: `No machine ${msg.machine}.`, requestId: null });
        if (machine.owner !== client.member.login && client.member.role !== "admin") {
          return this.send(ws, { type: "error", message: `Only ${machine.owner} or an admin can share sessions on ${machine.name}.`, requestId: null });
        }
        const live = machine.sessions.find((s) => s.session.id === msg.id);
        if (!live) return this.send(ws, { type: "error", message: "That session has ended.", requestId: null });
        const { results } = await this.env.DB.prepare("SELECT * FROM members").all<MemberRow>();
        const before = live.shares ?? [];
        const shares: SessionShare[] = [];
        for (const grant of msg.shares) {
          const row = results.find((r) => r.login.toLowerCase() === grant.login.toLowerCase());
          if (!row || revoked(row)) return this.send(ws, { type: "error", message: `${grant.login} isn't a member of this factory.`, requestId: null });
          if (row.login === machine.owner) return this.send(ws, { type: "error", message: `${row.login} owns ${machine.name}; it's theirs already.`, requestId: null });
          if (shares.some((s) => s.login === row.login)) continue;
          const was = before.find((s) => s.login === row.login);
          shares.push(was && was.canType === grant.canType ? was : { login: row.login, canType: grant.canType, by: client.member.login, at: Date.now() });
        }
        const res = await machineHub(this.env, machine.id).fetch("https://hub/share", { method: "POST", body: JSON.stringify({ session: msg.id, shares }) });
        if (!res.ok) return this.send(ws, { type: "error", message: await res.text(), requestId: null });
        for (const share of shares) {
          if (!before.some((s) => s.login === share.login && s.canType === share.canType)) {
            await audit(this.env, client.member.login, "session.shared", machine.id, { id: msg.id, with: share.login, canType: share.canType });
          }
        }
        for (const was of before) {
          if (!shares.some((s) => s.login === was.login)) await audit(this.env, client.member.login, "session.unshared", machine.id, { id: msg.id, with: was.login });
        }
        return;
      }
      case "machine.rename": {
        const machine = (await this.machines()).find((m) => m.id === msg.machine);
        if (!machine) return this.send(ws, { type: "error", message: `No machine ${msg.machine}.`, requestId: null });
        if (machine.owner !== client.member.login && client.member.role !== "admin") {
          return this.send(ws, { type: "error", message: `Only ${machine.owner} or an admin can rename ${machine.name}.`, requestId: null });
        }
        const name = msg.name.trim().replace(/\s+/g, " ");
        if (name.length > 40) return this.send(ws, { type: "error", message: "Keep a machine's name to 40 characters.", requestId: null });
        await this.env.DB.prepare("UPDATE machines SET name = ? WHERE id = ?").bind(name || null, machine.id).run();
        await machineHub(this.env, machine.id).fetch("https://hub/rename", { method: "POST", body: name || machine.id });
        await audit(this.env, client.member.login, "machine.renamed", machine.id, { from: machine.name, to: name || machine.id });
        return;
      }
      case "machine.update": {
        const machine = (await this.machines()).find((m) => m.id === msg.machine);
        if (!machine) return this.send(ws, { type: "error", message: `No machine ${msg.machine}.`, requestId: null });
        if (machine.owner !== client.member.login && client.member.role !== "admin") {
          return this.send(ws, { type: "error", message: `Only ${machine.owner} or an admin can update ${machine.name}.`, requestId: null });
        }
        const res = await machineHub(this.env, msg.machine).fetch("https://hub/command", {
          method: "POST",
          // The version they were shown: a newer release isn't installed without them pressing Update again.
          body: JSON.stringify({ type: "runner.update", version: msg.version ?? null }),
          headers: { "x-by": client.member.login },
        });
        if (!res.ok) return this.send(ws, { type: "error", message: await res.text(), requestId: null });
        await this.setUpdate(machine.id, { state: "checking", target: msg.version ?? (await this.runnerLatest()), from: machine.version ?? null, message: null, at: Date.now() }, true);
        await audit(this.env, client.member.login, "runner.update", msg.machine, msg.version ? { version: msg.version } : undefined);
        return;
      }
      case "machine.agent_login": {
        // Its owner only, not even an admin: a device code signs the machine into whoever finishes it in the browser.
        const machine = (await this.machines()).find((m) => m.id === msg.machine);
        if (!machine) return this.send(ws, { type: "error", message: `No machine ${msg.machine}.`, requestId: null });
        if (machine.owner !== client.member.login) {
          return this.send(ws, { type: "error", message: `Only ${machine.owner} can sign ${machine.name} in to ${msg.agent}.`, requestId: null });
        }
        const cancel = msg.cancel ?? false;
        const res = await machineHub(this.env, msg.machine).fetch("https://hub/command", {
          method: "POST",
          body: JSON.stringify({ type: "agent.login", agent: msg.agent, cancel }),
          headers: { "x-by": client.member.login },
        });
        if (!res.ok) return this.send(ws, { type: "error", message: await res.text(), requestId: null });
        await audit(this.env, client.member.login, cancel ? "agent.login.cancelled" : "agent.login", msg.machine, { agent: msg.agent });
        return;
      }
      case "runner.check": {
        // Only looks: no command reaches the runner and its update state is left alone.
        const machine = (await this.machines()).find((m) => m.id === msg.machine);
        if (!machine) return this.send(ws, { type: "error", message: `No machine ${msg.machine}.`, requestId: null });
        const latest = await this.refreshRunnerRelease();
        const text = !latest
          ? "Couldn't read the runner releases."
          : machine.version && olderThan(machine.version, latest)
            ? `Runner ${latest} is available for ${machine.name}.`
            : `${machine.name} is on the latest runner (${latest}).`;
        return this.send(ws, { type: "toast", text, taskId: null });
      }
      case "note.save": {
        const existing = this.store.note(msg.note.id);
        if (existing && existing.owner !== client.member.login) return this.send(ws, { type: "error", message: "That note isn't yours.", requestId: null });
        if (msg.note.body.length > 200_000) return this.send(ws, { type: "error", message: "That note is too long (200,000 characters at most).", requestId: null });
        const note = { ...msg.note, owner: client.member.login, updatedAt: Date.now() };
        this.store.saveNote(note);
        this.sendTo(client.member.login, { type: "note.updated", note });
        return;
      }
      case "goal.follow": {
        if (!this.store.goal(msg.id)) return this.send(ws, { type: "error", message: "That goal isn't there any more.", requestId: null });
        this.store.setFollow(client.member.login, msg.id, msg.following);
        this.sendTo(client.member.login, { type: "follows.updated", follows: this.store.follows(client.member.login) });
        return;
      }
      case "push.register": {
        const { platform, token, environment } = msg;
        if (platform !== "apns" && platform !== "fcm") return this.send(ws, { type: "error", message: "A push device is apns or fcm.", requestId: "push.register" });
        if (environment !== "sandbox" && environment !== "production") return this.send(ws, { type: "error", message: "A push device's environment is sandbox or production.", requestId: "push.register" });
        if (typeof token !== "string" || !/^[A-Za-z0-9:_\-.]{8,4096}$/.test(token)) return this.send(ws, { type: "error", message: "That isn't a push token.", requestId: "push.register" });
        try {
          this.store.registerPushDevice(client.member.login, { platform, token, environment });
        } catch (e) {
          return this.send(ws, { type: "error", message: (e as Error).message, requestId: "push.register" });
        }
        return this.sendTo(client.member.login, { type: "push.devices", devices: await this.pushDevices(client.member.login) });
      }
      case "push.unregister": {
        const login = client.member.login;
        if (msg.token) this.store.removePushDevice(msg.token, login);
        else if (msg.id) for (const d of this.store.pushDevices(login)) if ((await deviceId(d.token)) === msg.id) this.store.removePushDevice(d.token, login);
        return this.sendTo(login, { type: "push.devices", devices: await this.pushDevices(login) });
      }
      case "push.devices":
        return this.send(ws, { type: "push.devices", devices: await this.pushDevices(client.member.login) });
      case "quietHours.set": {
        let quietHours;
        try {
          quietHours = this.store.setQuietHours(client.member.login, msg.quietHours ?? null);
        } catch (e) {
          return this.send(ws, { type: "error", message: (e as Error).message, requestId: "quietHours.set" });
        }
        this.sendTo(client.member.login, { type: "quietHours.updated", quietHours });
        return;
      }
      case "note.delete": {
        const existing = this.store.note(msg.id);
        if (!existing || existing.owner !== client.member.login) return;
        this.store.deleteNote(msg.id);
        this.sendTo(client.member.login, { type: "note.removed", id: msg.id });
        return;
      }
      case "stats.get": {
        if (client.member.role !== "admin") return this.send(ws, { type: "error", message: "Only admins can see statistics.", requestId: null });
        this.send(ws, { type: "stats", summary: this.stats(msg.days, msg.goal) });
        return;
      }
      case "report.get": {
        // Anyone signed in, for themselves: their own tasks and the approvals they gave.
        this.send(ws, { type: "report", report: this.report(client.member.login, msg.since, msg.until) });
        return;
      }
      case "task.checkLog": {
        // A log can be large and goes stale: read from GitHub for whoever asked, never broadcast or kept.
        // A refusal carries `checkLog:<task>/<check>` as its requestId so the app ties it to that log.
        try {
          this.send(ws, await this.engine.checkLog(msg.id, msg.check));
        } catch (e) {
          if (!(e instanceof FactoryError)) console.error("factory:", e);
          this.send(ws, { type: "error", message: e instanceof FactoryError ? e.message : "Something went wrong reading that log.", requestId: `checkLog:${msg.id}/${msg.check}` });
        }
        return;
      }
      case "integrations.save": {
        if (client.member.role !== "admin") {
          this.send(ws, { type: "error", message: "Only admins can change the factory's integrations.", requestId: null });
          return;
        }
        try {
          await this.integrations.save(msg.kind, msg.enabled, msg.values ?? {}, client.member.login);
        } catch (e) {
          this.send(ws, { type: "error", message: e instanceof Error ? e.message : String(e), requestId: null });
          return;
        }
        const integrations = await this.integrationList();
        await audit(this.env, client.member.login, "integrations.saved", msg.kind, integrations.find((i) => i.kind === msg.kind));
        this.broadcast({ type: "integrations.updated", integrations });
        return;
      }
      case "members.revoke": {
        const error = await this.revokeAccess(client.member, msg.login);
        if (error) this.send(ws, { type: "error", message: error, requestId: null });
        return;
      }
      case "admins.grant":
      case "admins.revoke": {
        const error = await this.setAdmin(client.member, msg.login, msg.type === "admins.grant");
        if (error) this.send(ws, { type: "error", message: error, requestId: null });
        return;
      }
      case "session.attach":
      case "session.detach":
        // Terminals stream over their own socket (/client/terminal).
        return;
      default:
        try {
          await this.engine.command(msg, client);
        } catch (e) {
          if (!(e instanceof FactoryError)) console.error("factory:", e);
          this.send(ws, { type: "error", message: e instanceof FactoryError ? e.message : "Something went wrong in the factory.", requestId: null });
        }
    }
  }
}

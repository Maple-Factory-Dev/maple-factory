// The factory: tasks moving through planning, approval, building, review and merge, and the agent
// sessions doing the work. It lives in OrgHub (one per org), so every change here is serialized.
//
// A task's sessions all run in one worktree on one machine, branch `agent/<id>`: the planner makes
// it, the builder and reviewer reopen it. Agents report only through the `maple` MCP tools
// (tools.ts); a session that ends without reporting is classified by its end's cause (`ended`).

import type { Env } from "../env.ts";
import type {
  ChangeRequest, ClientMessage, Comment, Evidence, Finding, Goal, Hand, OrgRepo, Machine, Member, Mockup, ReviewCheck, ReviewThread, Role, RunnerMessage, ServerToClient,
  McpConnector, PromptAdditions, ServerToRunner, SessionEnd, Task, WorktreeScripts,
} from "../wire.ts";
import { audit, machineHub } from "../util.ts";
import { isAttachmentKey } from "../attachments.ts";
import { byRank, needsSession, Store, type TaskSession } from "./store.ts";
import { builderPrompt, cleanPrompts, MERGE_ANCHOR, type Moving, plannerPrompt, reviewerPrompt } from "./prompts.ts";
import { goalRepos, OWNER, REPO, taskRepo } from "./repos.ts";
import { affectedBy, emptyForecast, inFlight, refreshOverlaps, type Lane } from "./forecast.ts";
import { allowed, toolsFor } from "./tools.ts";
import { Drafts } from "./drafts.ts";
import { Scout, SCOUT_PREFIX, type Candidate, type ScoutPick } from "./scout.ts";
import { RepoSetup, SCRIPT_VARIABLES, scriptsProblem, SETUP_PREFIX, tidyScripts } from "./repo-setup.ts";
import { merged, redacted } from "./connectors.ts";
import { assess, validPolicy } from "./policy.ts";
import { findingDetail, type StatKind } from "./stats.ts";
import type { Intake } from "./intake.ts";
import type { Secrets } from "../secrets.ts";
import { mentionsIn } from "./mentions.ts";
import { checkLog, checks, closePullRequest, createPullRequest, deleteBranch, reopenPullRequest, GitHubError, type GitHubApp, githubApp, installedRepos, mergePullRequest, PERMISSIONS, repoToken, rerunCheck, rerunFailed, reviewThreads } from "../github.ts";

const MAX_REVIEW_ROUNDS = 5;
/// Restarts after ends nobody chose (sleep, lost tmux, an update) before a person is asked.
/** How old a session must be before `reap` takes it for a leftover rather than one still starting. */
const REAP_AFTER_MS = 30_000;
const MAX_RESTARTS = 2;
/// How long a session that reported its last word gets to wrap up before it's closed.
const CLOSE_AFTER_MS = 8_000;
const MAX_EVENTS = 200;
const COLS = 160;
const ROWS = 48;

type Ctx = { member: Member };
type Reply = { result?: { summary: string; data?: unknown }; error?: string };
type Hooks = {
  broadcast(message: ServerToClient): void;
  /** To one person's apps only. */
  sendTo(login: string, message: ServerToClient): void;
  machines(): Promise<Machine[]>;
  /** The org's members, for working out who a comment @mentions. */
  members(): Promise<Member[]>;
  /** Tell the apps a machine's settings changed. */
  machineChanged(id: string): Promise<void>;
  waitUntil(p: Promise<unknown>): void;
  /** Call `pollCI`, `mergeDue` and `pump` again in about `ms`: for CI that webhooks may never report (a local server), auto-merge countdowns and scheduled tasks. */
  wakeIn(ms: number): void;
};

/** What a runner says while Claude Code waits on its folder-trust prompt (runner/src/trust.rs). */
const TRUST_PROMPT = "Claude Code is asking whether to trust this folder";
const TRUST_HAND = "Claude Code is asking whether to trust its folder";

/** How often CI is read again while a pull request's checks are still running. */
const CI_POLL_MS = 30_000;
// The ways forward on a "didn't merge" hand (the clients pick them by title).
const MERGE_FIX = "Send it back to fix";
const MERGE_RETRY = "Try the merge again";
/** Times the factory sends a task that didn't merge back to fix it before asking a person. */
const MERGE_FIX_TRIES = 2;
/** How long an auto-merge waits for its dry-run merge's answer before merging anyway. */
const MERGE_CHECK_WAIT_MS = 60_000;
/** How long a pull request with no checks yet waits for some to show up. */
const CI_APPEAR_MS = 10 * 60_000;
/** How long an auto-merge counts down before it merges, so a person can hold it (env MERGE_GRACE_MS). */
const MERGE_GRACE_MS = 10_000;

export class FactoryError extends Error {}

const now = () => Date.now();
const branchName = (task: Task) => task.id.toLowerCase();
/** A task's id releases its repo's secrets to its machine only in these states. */
const SECRET_STATES = new Set<Task["state"]>(["planning", "building", "reviewing"]);
/** Where a review note sits: `path:L12` or `path:L12–18`. */
const lineAnchor = (n: { path: string; start: number; end: number }) => `${n.path}:L${n.start}${n.end > n.start ? `–${n.end}` : ""}`;

/** Code as a fenced block, with a fence longer than any backtick run inside it. */
const fence = (code: string) => {
  const ticks = "`".repeat(Math.max(3, ...[...code.matchAll(/`+/g)].map((m) => m[0].length + 1)));
  return `${ticks}diff\n${code.replace(/\n+$/, "")}\n${ticks}`;
};

const fail = (message: string): never => {
  throw new FactoryError(message);
};

export class Engine {
  private drafts: Drafts;
  private scout: Scout;
  private setup: RepoSetup;

  constructor(private env: Env, private store: Store, private hooks: Hooks, private intake: Intake, private secrets: Secrets) {
    this.drafts = new Drafts(store, {
      sendTo: (login, message) => hooks.sendTo(login, message),
      machines: () => hooks.machines(),
      hasAgent: (m, agent) => this.hasAgent(m, agent),
      paused: (m) => this.store.settings(m.id).paused,
      toRunner: (machine, command) => this.toRunner(machine, command),
    });
    this.scout = new Scout(store, {
      broadcast: (message) => hooks.broadcast(message),
      machines: () => hooks.machines(),
      hasAgent: (m, agent) => this.hasAgent(m, agent),
      paused: (m) => this.store.settings(m.id).paused,
      toRunner: (machine, command) => this.toRunner(machine, command),
      make: (goal, by, picks, shown) => this.scouted(goal, by, picks, shown),
    });
    this.setup = new RepoSetup(store, {
      broadcast: (message) => hooks.broadcast(message),
      machines: () => hooks.machines(),
      hasAgent: (m, agent) => this.hasAgent(m, agent),
      paused: (m) => this.store.settings(m.id).paused,
      isAdmin: (login) => this.isAdmin(login),
      toRunner: (machine, command) => this.toRunner(machine, command),
    });
  }

  /** Whether someone who has signed in is an admin here (a GitHub owner, or granted). */
  private async isAdmin(login: string): Promise<boolean> {
    return (await this.hooks.members()).some((m) => m.login.toLowerCase() === login.toLowerCase() && m.role === "admin");
  }

  /** Every repo's latest Set up with AI run, for an app that's just connected. */
  setupRuns() {
    return this.setup.runs();
  }

  // ---------------------------------------------------------------------------
  // Apps

  /** A command from an app. Throws FactoryError with a message for the person. */
  async command(msg: ClientMessage, { member }: Ctx): Promise<void> {
    const who = member.login;
    switch (msg.type) {
      case "draft.start":
      case "draft.goal":
      case "draft.cancel":
        try {
          if (msg.type === "draft.start") await this.drafts.start(who, msg.id, msg.idea, msg.goal ?? null, msg.agent ?? null);
          else if (msg.type === "draft.goal") await this.drafts.pickGoal(who, msg.id, msg.goal);
          else await this.drafts.cancel(who, msg.id);
        } catch (e) {
          fail((e as Error).message);
        }
        return;
      case "goal.scout":
        try {
          await this.scout.start(who, msg.goal);
        } catch (e) {
          fail((e as Error).message);
        }
        return;
      case "repo.setup.start":
      case "repo.setup.cancel":
        try {
          if (msg.type === "repo.setup.start") await this.setup.start(who, msg.repo, msg.agent ?? null);
          else await this.setup.cancel(who, msg.repo);
        } catch (e) {
          fail((e as Error).message);
        }
        return;
      case "goal.save": {
        const goal = { ...msg.goal, prefix: msg.goal.prefix.trim().toUpperCase() };
        if (!/^[A-Z][A-Z0-9]{0,9}$/.test(goal.prefix)) fail("A goal's prefix is 1–10 letters or digits, starting with a letter.");
        if (!goal.name.trim()) fail("A goal needs a name.");
        // Epoch ms, or none: an empty due means no due date.
        goal.due ??= null;
        if (goal.due !== null && !(Number.isSafeInteger(goal.due) && goal.due > 0)) fail("A goal's due date is a time in epoch milliseconds, or none.");
        if (!goal.id) goal.id = crypto.randomUUID();
        // Whoever makes a goal leads it unless they named someone, so it's in their sidebar.
        if (!goal.lead?.trim()) goal.lead = who;
        goal.team = goal.team?.trim().replace(/^@/, "").toLowerCase() || null;
        if (goal.team && !/^[a-z0-9][a-z0-9_.-]*$/.test(goal.team)) fail(`${goal.team} isn't a GitHub team's name.`);
        goal.repos = goalRepos({ ...goal, repo: goal.repo?.trim() || null, repos: (goal.repos ?? []).map((r) => r.trim()).filter(Boolean) });
        for (const r of goal.repos) if (!REPO.test(r)) fail(`${r} isn't a GitHub owner/name.`);
        goal.repo = goal.repos[0] ?? null;
        const known = this.store.repos();
        const unknown = goal.repos.find((r) => known.length && !known.some((k) => k.name.toLowerCase() === r.toLowerCase()));
        if (unknown) fail(`${unknown} isn't one of the org's repos. Add it in Settings → Repositories (or grant the GitHub App access) first.`);
        if (this.store.goals().some((g) => g.prefix === goal.prefix && g.id !== goal.id)) fail(`Another goal already uses ${goal.prefix}.`);
        const before = this.store.goal(goal.id);
        // None (an older app) keeps what it had; all empty is none.
        goal.prompts = goal.prompts ? cleanPrompts(goal.prompts) : (before?.prompts ?? null);
        if (goal.prompts && !goal.prompts.planner && !goal.prompts.builder && !goal.prompts.reviewer) goal.prompts = null;
        if (JSON.stringify(goal.prompts ?? null) !== JSON.stringify(before?.prompts ?? null) && member.role !== "admin") {
          // Its lead before this save, so nobody can make themselves lead and change the prompts in one go.
          const lead = before ? before.lead : goal.lead;
          if (lead !== who) fail(`Only admins or ${lead}, its lead, can change ${goal.name}'s agent instructions.`);
        }
        this.store.saveGoal(goal);
        this.hooks.broadcast({ type: "goal.updated", goal });
        return;
      }
      case "repos.refresh":
        return this.refreshRepos(true);
      case "repos.add": {
        if (member.role !== "admin") fail("Only admins can add repos.");
        const name = msg.name.trim().replace(/^https:\/\/github\.com\//, "").replace(/\.git$/, "");
        if (!REPO.test(name)) fail(`${name} isn't a GitHub owner/name.`);
        const repos = this.store.repos();
        if (repos.some((r) => r.name.toLowerCase() === name.toLowerCase())) fail(`${name} is already there.`);
        this.store.saveRepos([...repos, { name, defaultBranch: null, isPrivate: true, source: "manual" }]);
        await audit(this.env, who, "repo.added", null, { name });
        this.reposUpdated();
        return;
      }
      case "repos.owners.set": {
        if (member.role !== "admin") fail("Only admins can change which GitHub accounts add repos.");
        const org = (this.env.GITHUB_ORG ?? "").toLowerCase();
        const owners: string[] = [];
        for (const raw of msg.owners) {
          const login = raw.trim().replace(/^@/, "").replace(/^https:\/\/github\.com\//, "").replace(/\/$/, "");
          if (!login) continue;
          if (!OWNER.test(login)) fail(`${login} isn't a GitHub account's login.`);
          if (login.toLowerCase() !== org && !owners.some((o) => o.toLowerCase() === login.toLowerCase())) owners.push(login);
        }
        this.store.saveRepoOwners(owners);
        await audit(this.env, who, "repo.owners_set", null, { owners });
        this.reposUpdated();
        // Their repos come in (or the removed ones' go) once the app's installations are read again.
        return this.refreshRepos(true);
      }
      case "repos.remove": {
        if (member.role !== "admin") fail("Only admins can remove repos.");
        const repos = this.store.repos();
        const repo = repos.find((r) => r.name.toLowerCase() === msg.name.toLowerCase()) ?? fail(`${msg.name} isn't in the list.`);
        if (repo.source === "github") fail(`${repo.name} comes from the GitHub App; remove the app's access to it on GitHub.`);
        this.store.saveRepos(repos.filter((r) => r !== repo));
        await audit(this.env, who, "repo.removed", null, { name: repo.name });
        this.reposUpdated();
        return;
      }
      case "secrets.set":
      case "secrets.delete": {
        if (member.role !== "admin") fail("Only admins can change a repo's secrets.");
        const repo = this.store.repos().find((r) => r.name.toLowerCase() === msg.repo.trim().toLowerCase())?.name
          ?? fail(`${msg.repo} isn't one of the org's repos.`);
        const name = msg.name.trim();
        if (msg.type === "secrets.set") {
          try {
            await this.secrets.set(repo, name, msg.value, who);
          } catch (e) {
            fail((e as Error).message);
          }
        } else if (!this.secrets.delete(repo, name)) fail(`${repo} has no secret called ${name}.`);
        // Which one and who, never the value.
        await audit(this.env, who, msg.type === "secrets.set" ? "secret.set" : "secret.deleted", repo, { repo, name });
        this.hooks.broadcast({ type: "secrets.updated", secrets: this.secrets.list() });
        return;
      }
      case "repos.scripts.set": {
        if (member.role !== "admin") fail("Only admins can change a repo's worktree scripts.");
        await this.saveRepoSetup(who, msg.repo, msg.scripts, msg.prompts, null);
        return;
      }
      case "policy.save": {
        if (member.role !== "admin") fail("Only admins can change the risk policy.");
        const problem = validPolicy(msg.policy);
        if (problem) fail(problem);
        this.store.savePolicy(msg.policy);
        await audit(this.env, who, "policy.saved", null, msg.policy);
        return this.policyChanged();
      }
      case "prompts.save": {
        if (member.role !== "admin") fail("Only admins can change the org's prompts.");
        const prompts = cleanPrompts(msg.prompts);
        this.store.savePrompts(prompts);
        await audit(this.env, who, "prompts.saved", null, prompts);
        this.hooks.broadcast({ type: "prompts.updated", prompts });
        return;
      }
      case "connectors.save": {
        if (member.role !== "admin") fail("Only admins can change the factory's connectors.");
        const result = merged(msg.connectors, this.store.connectors());
        const connectors = typeof result === "string" ? fail(result) : result;
        this.store.saveConnectors(connectors);
        const shown = redacted(connectors);
        await audit(this.env, who, "connectors.saved", null, shown);
        this.hooks.broadcast({ type: "connectors.updated", connectors: shown });
        return;
      }
      case "goal.acceptRisk": {
        const goal = this.store.goal(msg.goal) ?? fail("That goal isn't there any more.");
        if (member.role !== "admin" && goal.lead !== who) fail(`Only admins or ${goal.lead}, its lead, can accept risk for ${goal.name}.`);
        const rest = this.store.acceptances().filter((a) => a.goal !== goal.id);
        this.store.saveAcceptances(msg.upTo ? [...rest, { goal: goal.id, upTo: msg.upTo, by: who, at: now(), note: msg.note ?? null }] : rest);
        await audit(this.env, who, msg.upTo ? "risk.accepted" : "risk.withdrawn", goal.id, { upTo: msg.upTo, note: msg.note });
        return this.policyChanged();
      }
      case "machine.settings": {
        const machine = (await this.hooks.machines()).find((m) => m.id === msg.machine) ?? fail("That machine isn't there any more.");
        if (machine.owner !== who && member.role !== "admin") fail(`Only ${machine.owner} can change ${machine.name}'s settings.`);
        const s = msg.settings;
        if (s.capacity != null && (s.capacity < 0 || s.capacity > 16)) fail("A machine takes 0 to 16 sessions.");
        if (s.teamSlots > (s.capacity ?? this.capacity(machine))) fail("It can't lend more slots than it has.");
        const pausing = s.paused && !this.store.settings(machine.id).paused;
        this.store.saveSettings(machine.id, { ...s, loadCap: Math.min(1, Math.max(0.1, s.loadCap)) });
        await audit(this.env, who, "machine.settings", machine.id, s);
        if (pausing && msg.handOff) {
          // Teammates' tasks shouldn't wait out the owner's pause: their work goes to other machines.
          for (const session of this.store.liveSessions().filter((x) => x.machine === machine.id && x.kind === "team" && x.role !== "reviewer")) {
            const task = this.store.task(session.task);
            if (!task || task.worker?.session !== session.id) continue;
            this.event(task, who, `paused ${machine.name} and handed it off`);
            if (!(await this.handOff(task, who))) {
              this.relocate(task, who, machine.name, null);
            }
          }
        }
        await this.hooks.machineChanged(machine.id);
        await this.pump();
        return;
      }
      case "intake.attach": {
        const request = this.intake.get(msg.id) ?? fail("That request isn't there any more.");
        const task = this.store.task(msg.task) ?? fail("That task isn't there any more.");
        for (const t of request.tickets) if (!task.tickets.some((x) => x.key === t.key)) task.tickets.push(t);
        task.comments.push(await this.comment(request.requester, request.thread.filter((m) => !m.bot).map((m) => m.text).join("\n\n"), { via: sourceTitle(request) }));
        this.event(task, who, `added ${request.requester}'s request (${request.id}) to it`);
        this.save(task);
        this.intake.accepted(request, task, "attached", who);
        return;
      }
      case "goal.archive": {
        const goal = this.store.goal(msg.id) ?? fail("That goal isn't there any more.");
        if (member.role !== "admin" && goal.lead !== who) fail(`Only admins or ${goal.lead}, its lead, can archive ${goal.name}.`);
        const unfinished = this.store.tasks().filter((t) => t.goal === goal.id && t.state !== "merged" && t.state !== "cancelled");
        if (msg.archived && unfinished.length) {
          const ids = unfinished.map((t) => t.id).join(", ");
          if (!msg.unfinished) fail(`${ids} ${unfinished.length === 1 ? "isn't" : "aren't"} finished; say whether to end ${unfinished.length === 1 ? "it" : "them"} or let ${unfinished.length === 1 ? "it" : "them"} finish.`);
          if (msg.unfinished !== "finish") {
            for (const task of unfinished) {
              if (msg.unfinished === "cleanup") this.store.savePrivate(task.id, { ...this.store.private(task.id), discard: true });
              await this.cancel(task, who, `cancelled it, archiving ${goal.name}`);
              await this.cleanup(task);
            }
            await this.pump();
          }
        }
        const saved = { ...goal, archived: msg.archived || null };
        this.store.saveGoal(saved);
        this.hooks.broadcast({ type: "goal.updated", goal: saved });
        await audit(this.env, who, msg.archived ? "goal.archived" : "goal.unarchived", goal.id);
        return;
      }
      case "intake.ask": {
        const request = this.intake.get(msg.id) ?? fail("That request isn't there any more.");
        this.intake.ask(request, msg.text.trim() || fail("Say what to ask."));
        return;
      }
      case "intake.decline": {
        const request = this.intake.get(msg.id) ?? fail("That request isn't there any more.");
        this.intake.decline(request, who, msg.note ?? null);
        return;
      }
      case "task.create": {
        const goal = this.store.goal(msg.goal) ?? fail("That goal isn't there any more.");
        if (goal.archived) fail(`${goal.name} is archived; unarchive it to add tasks.`);
        if (!msg.title.trim()) fail("A task needs a title.");
        const repo = msg.repo ? goalRepos(goal).find((r) => r.toLowerCase() === msg.repo!.toLowerCase()) ?? fail(`${goal.name} doesn't work in ${msg.repo}; add it to the goal's repos first.`) : null;
        const after = msg.after ?? [];
        for (const id of after) if (!this.store.task(id)) fail(`There's no task ${id} for it to wait on.`);
        const request = msg.intake ? this.intake.get(msg.intake) : null;
        const task = this.newTask(goal, who, { title: msg.title.trim(), brief: msg.brief, tickets: msg.tickets, shareable: msg.shareable, agent: msg.agent || "claude", intake: request?.id ?? null, repo, after, effort: effortName(msg.effort) });
        if (request) {
          for (const t of request.tickets) if (!task.tickets.some((x) => x.key === t.key)) task.tickets.push(t);
          for (const m of request.thread.filter((m) => !m.bot)) task.comments.push(await this.comment(m.author, m.text, { at: m.at, via: sourceTitle(request) }));
        }
        this.save(task);
        await audit(this.env, who, "task.created", task.id, { title: task.title });
        if (msg.plan) await this.startPlanning(task, who);
        if (request) this.intake.accepted(request, this.store.task(task.id) ?? task, "created", who);
        return;
      }
    }

    const task = this.store.task(msg.type === "subscribe" ? "" : (msg as { id: string }).id) ?? fail("That task isn't there any more.");
    switch (msg.type) {
      case "task.edit": {
        // A backlog task without a plan is still a draft, just parked.
        const unplanned = task.state === "drafting" || (task.state === "backlog" && !task.plan.length);
        if (!unplanned && msg.brief != null && msg.brief !== task.brief) fail("The brief can only change while it's a draft; steer it instead.");
        if (msg.title != null && msg.title.trim()) {
          task.title = msg.title.trim();
          // The person named it; the planner's suggestion is moot.
          task.suggestedTitle = null;
        }
        if (msg.brief != null) task.brief = msg.brief;
        if (msg.shareable != null) task.shareable = msg.shareable;
        if (msg.repo != null && msg.repo !== task.repo) {
          if (!unplanned) fail("Its repo can only change while it's a draft: the plan is for the repo it has.");
          const goal = this.store.goal(task.goal);
          task.repo = (goal && goalRepos(goal).find((r) => r.toLowerCase() === msg.repo!.toLowerCase())) ?? fail(`Its goal doesn't work in ${msg.repo}.`);
        }
        if (msg.agent != null || msg.model != null) {
          // Any state until it's done: the change applies from its next session, and one running keeps going.
          if (task.state === "merged" || task.state === "cancelled") fail(`It's ${task.state}; there's nothing left to build.`);
          const agent = msg.agent != null ? msg.agent.trim() : task.agent;
          if (!["claude", "codex"].includes(agent)) fail(`${agent || "That"} isn't an agent the factory runs: claude or codex.`);
          const was = task.model ?? null;
          let model = msg.model != null ? msg.model.trim() || null : was;
          // A model the old agent knew means nothing to the new one.
          if (msg.model == null && agent !== task.agent && model && !modelFits(agent, model)) model = null;
          if (agent !== task.agent) this.event(task, who, `switched it to ${agent}${model ? ` · ${model}` : ""}`);
          else if (model !== was) this.event(task, who, model ? `set its model to ${model}` : "set its model back to the default");
          task.agent = agent;
          task.model = model;
        }
        const effort = msg.effort != null ? effortName(msg.effort) : undefined;
        const onlyEffort = msg.title == null && msg.brief == null && msg.shareable == null && msg.repo == null;
        if (effort !== undefined && effort !== (task.effort ?? null)) {
          // Any state: an effort only groups tasks, it doesn't change the work.
          const was = task.effort;
          task.effort = effort;
          this.event(task, who, effort ? `put it in effort ${effort}` : `took it out of effort ${was}`);
        }
        if (!onlyEffort) this.event(task, who, "edited it");
        this.save(task);
        await this.pump();
        return;
      }
      case "task.assign": {
        if (task.state === "merged" || task.state === "cancelled") fail("It's already finished.");
        const owner = msg.owner.trim().replace(/^@/, "");
        if (owner.toLowerCase() === task.owner.toLowerCase()) fail(`${task.owner} already owns it.`);
        const to = (await this.hooks.members()).find((m) => m.login.toLowerCase() === owner.toLowerCase()) ?? fail(`${owner} isn't in the org.`);
        if (to.login !== who && task.owner !== who && member.role !== "admin") fail(`Only ${task.owner}, its owner, or an admin can give it to someone else; you can take it over yourself.`);
        const was = task.owner;
        task.owner = to.login;
        // Its open hand is the owner's to resolve.
        if (task.hand && task.hand.assignee === was) task.hand.assignee = to.login;
        this.event(task, who, to.login === who ? "took it over" : `assigned it to @${to.login}`);
        await audit(this.env, who, "task.assigned", task.id, { from: was, to: to.login });
        this.save(task);
        // What hasn't started yet goes to the new owner's machines; a running session keeps its machine (as a team slot).
        await this.pump();
        return;
      }
      case "task.plan":
        if (task.state !== "drafting" && task.state !== "backlog") fail("It's already past drafting.");
        // Picked up from the backlog with a plan: the planner revises the plan it has.
        return this.startPlanning(task, who, task.state === "backlog" && task.plan.length > 0);
      case "task.backlog": {
        if (task.state !== "drafting" && task.state !== "awaitingApproval") fail("Only a draft or a plan waiting for approval can go to the backlog.");
        this.closeWorker(task, "done");
        task.state = "backlog";
        task.approvals = [];
        task.waiting = null;
        task.startAt = null;
        this.event(task, who, "sent it to the backlog");
        this.save(task);
        return;
      }
      case "task.comment": {
        const text = msg.text.trim() || fail("Say something.");
        task.comments.push(await this.comment(who, text, { anchor: msg.anchor ?? null }));
        this.save(task);
        return;
      }
      case "task.steer": {
        const text = msg.text.trim() || fail("Say what to change.");
        return this.steer(task, who, text, msg.anchor ?? null, `asked for a change: ${text}`);
      }
      case "task.review": {
        const notes = msg.notes.map((n) => ({ ...n, text: n.text.trim() })).filter((n) => n.text);
        if (!notes.length) fail("Add a comment to a line first.");
        this.steerable(task);
        const summary = msg.summary?.trim() || null;
        // Each note on its own in the comment log, anchored to its lines, with the code it's about.
        for (const n of notes) task.comments.push(await this.comment(who, `${fence(n.snippet)}\n${n.text}`, { anchor: lineAnchor(n) }));
        if (summary) task.comments.push(await this.comment(who, summary, { anchor: "Review" }));
        // The builder (or planner) gets the batch as one change request.
        const text = [summary, ...notes.map((n, i) => `${i + 1}. ${lineAnchor(n)}${n.side === "old" ? " (removed lines)" : ""}: ${n.text}`)].filter(Boolean).join("\n");
        const count = `${notes.length} comment${notes.length === 1 ? "" : "s"}`;
        return this.steer(task, who, text, `Review · ${count}`, `asked for a change: a review of ${count}`);
      }
      case "task.approvePlan": {
        if (task.state === "backlog") {
          if (!task.plan.length) fail("It isn't planned yet; send it to planning first.");
          // Picked up from the backlog: it waits for the rest of its approvals, if it needs more.
          task.state = "awaitingApproval";
          this.event(task, who, "picked it up from the backlog");
        }
        if (task.state !== "awaitingApproval") fail("There's no plan waiting for approval.");
        if (task.approvals.includes(who)) fail("You've already approved it.");
        if (msg.keepTitle && task.suggestedTitle) {
          task.suggestedTitle = null;
          this.event(task, who, "kept the title");
        }
        task.approvals.push(who);
        for (const m of task.mockups) if (m.status === "proposed") m.status = "approved";
        this.event(task, who, "approved the plan");
        if (task.approvals.length >= task.approvalsNeeded) await this.approved(task, "queued it for building");
        this.save(task);
        await this.pump();
        return;
      }
      case "task.answer": {
        const q = task.question ?? fail("There's no question waiting.");
        task.question = null;
        this.stat(task, "question.answered", { waitMs: now() - q.at }, who, q.role);
        task.comments.push(await this.comment(who, msg.text, { anchor: `Q: ${q.text}` }));
        this.event(task, who, `answered: ${msg.text}`);
        this.save(task);
        if (!(await this.type(task, `${who} answered your question ("${q.text}"): ${msg.text}`))) await this.pump();
        return;
      }
      case "task.answerPrompt": {
        // Only ever a keypress into a permission menu: anything else waiting, or working, is refused.
        const w = task.worker ?? fail("Nothing's running on it.");
        const machine = (await this.hooks.machines()).find((m) => m.id === w.machine);
        const activity = machine?.sessions.find((s) => s.session.id === w.session)?.activity;
        const permission = activity?.state === "waiting" ? (activity.question as { permission?: { tool?: string } } | null)?.permission : undefined;
        if (!activity || !permission) fail(`Its ${w.role} isn't waiting on a permission prompt.`);
        if (this.store.get(`answered:${w.session}`) === String(activity!.at)) fail("That prompt has already been answered.");
        // 1 is always "Yes" (once). No is whichever number comes last ("2. Yes, and don't ask again" can
        // sit before it), so it's Esc, Claude's own way out of the menu, which denies the tool call.
        const ok = await this.press(task, msg.choice === "yes" ? "1" : "\x1b");
        if (!ok) fail(`${machine?.name ?? w.machine} is offline.`);
        this.store.set(`answered:${w.session}`, String(activity!.at));
        const tool = permission!.tool ?? "it";
        if (msg.choice === "no") {
          // Allowed, its PostToolUse moves it on; denied, Claude stops and says nothing, so the factory does.
          const stopped = { ...activity!, message: `Stopped: ${who} denied ${tool}. Steer it, or answer in its session.`, question: null };
          await machineHub(this.env, w.machine).fetch("https://hub/activity", { method: "POST", body: JSON.stringify({ session: w.session, activity: stopped }) });
        }
        this.event(task, who, `${msg.choice === "yes" ? "allowed" : "denied"} ${tool}`);
        this.stat(task, "prompt.answered", { choice: msg.choice, tool: permission!.tool ?? null }, who, w.role);
        this.save(task);
        return;
      }
      case "task.resolveHand": {
        const hand = task.hand ?? fail("Nobody's asking for a hand.");
        const option = msg.option ? hand.options.find((o) => o.title === msg.option) : undefined;
        if (hand.reason === "mergeFailed") return this.resolveMergeFailed(task, who, option?.title ?? null, msg.note.trim());
        this.lowerHand(task, who, option?.title ?? null);
        const decision = [option ? `Go with: ${option.title} — ${option.detail}` : null, msg.note.trim() || null].filter(Boolean).join("\n");
        if (decision) task.comments.push(await this.comment(who, decision, { anchor: `Hand: ${hand.summary}` }));
        this.event(task, who, option ? `picked "${option.title}"` : "resolved the hand raise");
        if (hand.reason === "reviewLoop" && task.autoReview) task.autoReview.maxRounds += 2;
        this.store.savePrivate(task.id, { ...this.store.private(task.id), restarts: 0, discard: false, cleaned: false });
        this.save(task);
        if (!(await this.type(task, `${who} answered your raised hand: ${decision || "carry on."}`))) await this.pump();
        return;
      }
      case "task.approveChanges": {
        if (task.state !== "reviewing" || task.autoReview?.rounds.at(-1)?.verdict !== "passed") fail("It isn't ready for review yet.");
        if (task.reviews.includes(who)) fail("You've already approved it.");
        task.reviews.push(who);
        this.event(task, who, "approved the changes");
        this.save(task);
        await this.autoMerge(task);
        return;
      }
      case "task.merge": {
        if (task.state !== "reviewing" || !task.pr) fail("There's nothing to merge.");
        if (task.hand?.reason === "mergeFailed") fail("It didn't merge last time; pick a way forward on its hand.");
        if (this.store.private(task.id).merging) fail("It's merging now.");
        if (task.autoReview?.rounds.at(-1)?.verdict !== "passed") fail("It hasn't passed automatic review.");
        if (task.reviews.length < task.reviewsNeeded) fail("It needs its approvals first.");
        if (task.pr!.checks.some((c) => c.status === "failed")) fail("CI is failing; run the failed checks again or fix them first.");
        if (task.pr!.checks.some((c) => c.status !== "passed")) fail("CI is still running.");
        task.mergeAt = null;
        await this.startMerge(task, who);
        return;
      }
      case "task.holdMerge": {
        if (task.mergeAt == null) fail("It isn't counting down to merge.");
        const head = task.pr?.head ?? task.pr?.branch ?? null;
        task.mergeAt = null;
        this.store.savePrivate(task.id, { ...this.store.private(task.id), mergeHeld: head });
        this.event(task, who, "held the auto-merge; a person merges it");
        this.save(task);
        return;
      }
      case "task.cancel": {
        if (task.state === "merged" || task.state === "cancelled") fail("It's already finished.");
        await this.cancel(task, who);
        await this.pump();
        return;
      }
      case "task.queue": {
        if (task.state === "merged" || task.state === "cancelled") fail("It's already finished.");
        if (task.state === "backlog") fail("It's in the backlog. Pick it up first: send it to planning, or approve its plan.");
        if (msg.force) {
          if (task.worker || task.hand || task.question) fail("It's already running.");
          if (task.state !== "drafting" && !this.roleFor(task)) fail("It isn't waiting for a session.");
          const queue = this.store.queued();
          const top = queue.find((t) => t.id !== task.id);
          if (top) task.queueRank = this.store.rankBefore(task.id, top, queue);
          task.startAt = null;
          task.force = true;
          this.event(task, who, "ran it now, over its machine's slot limit");
          if (task.state === "drafting") return this.startPlanning(task, who);
          task.waiting = null;
          this.save(task);
          await this.pump();
          return;
        }
        const scheduling = msg.startAt != null || msg.clearSchedule;
        if (msg.before === task.id) fail("It can't go ahead of itself.");
        const queue = this.store.queued();
        const before = msg.before === "top" ? queue.find((t) => t.id !== task.id) ?? null
          : msg.before ? this.store.task(msg.before) ?? fail(`${msg.before} isn't there any more.`) : null;
        const moved = msg.before != null || !scheduling;
        if (moved && (msg.before !== "top" || before)) {
          task.queueRank = this.store.rankBefore(task.id, before, queue);
          this.event(task, who, msg.before === "top" ? "moved it to the top of the queue" : before ? `moved it ahead of ${before.id} in the queue` : "moved it to the back of the queue");
        }
        if (msg.startAt != null) {
          task.startAt = msg.startAt;
          this.event(task, who, `scheduled it for ${new Date(msg.startAt).toISOString()}`);
        } else if (msg.clearSchedule && task.startAt != null) {
          task.startAt = null;
          this.event(task, who, "cleared its schedule");
        }
        if (task.state === "drafting") return this.startPlanning(task, who);
        task.waiting = null;
        this.save(task);
        await this.pump();
        return;
      }
      case "task.rankDraft": {
        if (task.state !== "drafting") fail("Only a draft can be reordered among the drafts.");
        if (msg.before === task.id) fail("It can't go ahead of itself.");
        const drafts = this.store.drafts(task.goal);
        let before: Task | null = null;
        if (msg.before === "top") before = drafts.find((t) => t.id !== task.id) ?? null;
        else if (msg.before) {
          before = drafts.find((t) => t.id === msg.before) ?? fail(`${msg.before} isn't a draft in this goal.`);
        }
        if (msg.before !== "top" || before) task.draftRank = this.store.draftRankBefore(task.id, before, drafts);
        this.event(task, who, msg.before === "top" ? "moved it to the top of the drafts" : before ? `moved it ahead of ${before.id} in the drafts` : "moved it to the bottom of the drafts");
        this.save(task);
        return;
      }
      case "task.retry": {
        if (task.state === "merged") fail("It's already merged.");
        if (task.state === "drafting") fail("It hasn't started yet; send it to planning.");
        if (task.state === "backlog") fail("Nothing runs on it in the backlog; send it to planning or approve its plan.");
        const goal = this.store.goal(task.goal);
        if (goal?.archived) fail(`${goal.name} is archived; unarchive it to pick this back up.`);
        const priv = this.store.private(task.id);
        // Archived with "clean up": its worktree is gone, so a new session would start in nothing.
        if (priv.discard || priv.cleaned) fail("Its worktree was cleaned up when its goal was archived.");
        if (task.state === "awaitingApproval") fail("Nothing is running; its plan is waiting for approval. Request changes to plan it again.");
        if (priv.merging) fail("It's merging now.");
        if (priv.finishing) fail("It's pushing its work now; retry once that's done.");
        // Its first session hasn't said where its worktree is yet; a new one would make it again.
        if (task.worker && !priv.worktree) fail("It's still starting; retry in a moment.");
        // Whatever's running stops, and a new session starts in its place.
        this.closeWorker(task, "cancelled");
        task.liveLog = null;
        const was = task.state;
        if (was === "cancelled") {
          // Back to the stage it was in: reviewing what it pushed, building its approved plan, its plan
          // waiting for approval, or planning.
          task.state = task.pr ? "reviewing"
            : !task.plan.length ? "planning"
            : task.approvals.length >= task.approvalsNeeded ? "building"
            : "awaitingApproval";
          // A pull request GitHub won't reopen is forgotten: building again pushes and opens a new one.
          if (task.pr?.state === "closed" && !(await this.reopenPull(task, who))) task.state = "building";
        }
        if (task.state === "reviewing") {
          // A new automated-review round on what's pushed.
          if (task.autoReview?.rounds.at(-1)?.verdict === "inProgress") task.autoReview.rounds.pop();
          const review = task.autoReview ?? { maxRounds: MAX_REVIEW_ROUNDS, rounds: [], summary: "", ask: [], proofs: [], findings: [] };
          if (review.rounds.length >= review.maxRounds) review.maxRounds = review.rounds.length + 1;
          review.rounds.push({ number: review.rounds.length + 1, verdict: "inProgress", found: 0, at: now(), fix: null });
          task.autoReview = review;
          task.reviews = [];
        }
        this.lowerHand(task, who);
        task.question = null;
        task.waiting = null;
        this.store.savePrivate(task.id, { ...this.store.private(task.id), restarts: 0 });
        this.event(task, who, was === "cancelled" ? `picked it back up (${task.state})` : task.state === "reviewing" ? "ran its review again" : "retried it");
        this.save(task);
        await this.pump();
        return;
      }
      case "task.move": {
        if (task.state === "merged" || task.state === "cancelled" || task.state === "drafting" || task.state === "backlog") fail("There's nothing running to move.");
        if (!task.machine) fail("It hasn't started on a machine yet.");
        if (this.store.private(task.id).handingOff) fail("It's already being handed off.");
        const from = (await this.hooks.machines()).find((m) => m.id === task.machine);
        const stuck = !from || !from.online || this.store.settings(from.id).paused || !task.worker;
        if (!stuck) fail(`It's running on ${from!.name}; it moves when that machine is offline or paused, or once it stops.`);
        await audit(this.env, who, "task.moved", task.id, { from: from?.id ?? task.machine });
        // A machine that's still there pushes the work it has first, so nothing stays behind on it.
        if (from?.online && (await this.handOff(task, who))) return;
        this.relocate(task, who, from?.name ?? task.machine ?? "its machine", null);
        await this.pump();
        return;
      }
      case "task.rerunChecks": {
        const app = githubApp(this.env);
        const priv = this.store.private(task.id);
        if (!app || !priv.gh || !task.pr) fail("Its checks aren't on GitHub.");
        const failed = (priv.checks ?? []).filter((c) => c.status === "failed");
        if (!failed.length) fail("No checks have failed.");
        const asked = await rerunFailed(app!, priv.gh!.owner, priv.gh!.repo, failed).catch((e) => fail((e as Error).message));
        for (const c of task.pr!.checks) if (c.status === "failed") c.status = "queued";
        this.event(task, who, `ran ${failed.map((c) => c.name).join(", ")} again`);
        this.save(task);
        await audit(this.env, who, "task.rerunChecks", task.id, { asked });
        return;
      }
      case "task.rerunCheck": {
        const app = githubApp(this.env);
        const priv = this.store.private(task.id);
        if (!app || !priv.gh || !task.pr) fail("Its checks aren't on GitHub.");
        if (task.pr!.state !== "open") fail("Its pull request isn't open.");
        const check = (priv.checks ?? []).find((c) => c.name === msg.check);
        if (!check) fail(`There's no check ${msg.check} on it.`);
        if (check!.status === "queued" || check!.status === "running") fail(`${check!.name} is still running.`);
        await rerunCheck(app!, priv.gh!.owner, priv.gh!.repo, check!).catch((e) => fail((e as Error).message));
        for (const c of task.pr!.checks) if (c.name === check!.name) c.status = "queued";
        this.store.savePrivate(task.id, { ...priv, checks: (priv.checks ?? []).map((c) => (c.name === check!.name ? { ...c, status: "queued" as const, duration: null } : c)) });
        this.event(task, who, `ran ${check!.name} again`);
        this.save(task);
        this.hooks.wakeIn(CI_POLL_MS);
        await audit(this.env, who, "task.rerunCheck", task.id, { check: check!.name });
        return;
      }
      case "task.checkLog":
        // The org hub answers this one on the asking connection (checkLog).
        return;
      case "task.split": {
        if (task.state !== "awaitingApproval" && task.state !== "building") fail("Only a planned task that isn't finished can be split.");
        const steps = task.plan;
        const parts = Math.max(2, Math.min(msg.parts, steps.length));
        if (steps.length < 2) fail("It needs at least two steps to split.");
        // Building keeps everything up to the step it's on; otherwise it keeps an even share.
        const reached = steps.reduce((last, s, i) => (s.progress ? i : last), -1);
        const keep = Math.min(steps.length - parts + 1, Math.max(task.state === "building" ? reached + 1 : Math.ceil(steps.length / parts), 1));
        const rest = steps.slice(keep);
        const per = Math.ceil(rest.length / (parts - 1));
        const created: Task[] = [];
        for (let i = 0; i < rest.length; i += per) {
          const chunk = rest.slice(i, i + per);
          const t = now();
          const part: Task = {
            ...structuredClone(task),
            id: this.store.nextId(this.store.goal(task.goal)?.prefix ?? task.id.split("-")[0]),
            title: chunk.length > 1 ? `${chunk[0].text} (+${chunk.length - 1} more)` : chunk[0].text,
            state: "drafting",
            brief: `Split from ${task.id} (${task.title}) to stay inside the PR budget. This task does these steps of its plan:\n\n${chunk.map((s) => `- ${s.text}${s.file ? ` (${s.file})` : ""}`).join("\n")}\n\n## ${task.id}'s brief\n\n${task.brief}`,
            createdAt: t,
            updatedAt: t,
            plan: [],
            planVersion: 0,
            doneWhen: [],
            approvals: [],
            reviews: [],
            comments: [],
            changes: [],
            events: [{ who, text: `split it off ${task.id}`, at: t }],
            mockups: [],
            question: null,
            hand: null,
            worker: null,
            liveLog: null,
            waiting: null,
            pr: null,
            diff: null,
            footprint: null,
            risk: null,
            autoReview: null,
            branch: null,
            machine: null,
            intake: null,
            splitFrom: task.id,
            suggestedTitle: null,
            followUps: [],
          };
          this.save(part);
          created.push(part);
        }
        const moved = created.map((p) => p.id).join(", ");
        task.plan = steps.slice(0, keep);
        this.event(task, who, `split it into ${created.length + 1} tasks: ${[task.id, ...created.map((p) => p.id)].join(", ")}`);
        await audit(this.env, who, "task.split", task.id, { into: created.map((p) => p.id) });
        if (task.state === "awaitingApproval") {
          // The plan isn't approved: the planner rescopes it (and its checks) to what's left.
          task.changes.push({ id: `C${task.changes.length + 1}`, author: who, text: `Split: keep only the first ${keep} step${keep === 1 ? "" : "s"}; the rest moved to ${moved}. Rescope the plan, its checks and mockups to match.`, at: now(), anchor: null, status: "queued", timing: null });
          task.approvals = [];
          this.save(task);
          await this.startPlanning(task, who, true);
        } else {
          const change: ChangeRequest = { id: `C${task.changes.length + 1}`, author: who, text: `Stop after step ${keep}: steps ${keep + 1}–${steps.length} moved to ${moved}. Leave them out of this change.`, at: now(), anchor: null, status: "queued", timing: null };
          task.changes.push(change);
          if (task.worker && (await this.type(task, `Change request ${change.id} from ${who}: ${change.text}\nApply it, then report it with \`progress\` (applied: ["${change.id}"]).`))) change.status = "applying";
          this.save(task);
        }
        for (const part of created) await this.startPlanning(part, who);
        return;
      }
      case "task.checkedIt": {
        const item = task.doneWhen[msg.item] ?? fail("There's no such Done when item.");
        if (task.state !== "building" && task.state !== "reviewing") fail("You can attest to it while it's building or in review.");
        const reason = msg.note?.trim() || null;
        item.status = "proven";
        item.evidence = { kind: item.proof, summary: `Attested by ${who}${reason ? `: ${reason}` : ""}`, output: [], by: who, at: now(), attested: true, reason };
        this.event(task, who, `attested "${item.text}"${reason ? `: ${reason}` : ""}`);
        this.save(task);
        return;
      }
      case "task.mockupChange": {
        const mockup = task.mockups.find((m) => m.id === msg.mockup) ?? fail("That mockup isn't there any more.");
        mockup.status = "changesRequested";
        task.changes.push({ id: `C${task.changes.length + 1}`, author: who, text: msg.text, at: now(), anchor: `Mockup: ${mockup.title}`, status: "queued", timing: null });
        this.event(task, who, `asked for a change to the "${mockup.title}" mockup`);
        if (task.state === "awaitingApproval") {
          task.approvals = [];
          this.save(task);
          return this.startPlanning(task, who, true);
        }
        this.save(task);
        return;
      }
    }
  }

  private async startPlanning(task: Task, who: string, revise = false) {
    task.state = "planning";
    task.waiting = null;
    this.event(task, who, revise ? "sent it back to the planner" : "sent it to planning");
    this.save(task);
    await this.pump();
  }

  // ---------------------------------------------------------------------------
  // Dispatch

  /** Starts a session for every task that should have one and doesn't, where there's room. */
  private pumping: Promise<void> | null = null;
  private pumpAgain = false;

  /** One pump at a time (they await the machines, so two could start the same task twice); a pump
   *  asked for while one runs happens once it's done. */
  async pump(): Promise<void> {
    if (this.pumping) {
      this.pumpAgain = true;
      return this.pumping;
    }
    this.pumping = (async () => {
      do {
        this.pumpAgain = false;
        await this.pumpOnce();
      } while (this.pumpAgain);
    })().finally(() => (this.pumping = null));
    return this.pumping;
  }

  private async pumpOnce(): Promise<void> {
    const machines = await this.hooks.machines();
    // Front of the queue first.
    for (const listed of this.store.tasks().sort(byRank)) {
      // Read it again: what an earlier dispatch awaited may have changed it (a cancel, a move).
      const task = this.store.task(listed.id);
      if (!task) continue;
      const role = this.roleFor(task);
      if (!role || task.worker || task.hand || task.question) continue;
      const waiting = await this.dispatch(task, role, machines);
      if (waiting !== (task.waiting ?? null)) {
        task.waiting = waiting;
        this.save(task);
      }
    }
  }

  /** Whether any task is waiting for a machine. */
  waiting(): boolean {
    return this.store.tasks().some((t) => t.waiting && !t.worker);
  }

  /** A new draft task in `goal`, saved. */
  private newTask(goal: Goal, who: string, f: Pick<Task, "title" | "brief" | "tickets" | "shareable" | "agent" | "model" | "intake" | "repo" | "after" | "effort">): Task {
    const t = now();
    const task: Task = {
      id: this.store.nextId(goal.prefix),
      goal: goal.id,
      state: "drafting",
      owner: who,
      createdAt: t,
      updatedAt: t,
      plan: [],
      planVersion: 0,
      doneWhen: [],
      approvals: [],
      approvalsNeeded: 1,
      reviews: [],
      reviewsNeeded: 1,
      comments: [],
      changes: [],
      events: [{ who, text: "created it", at: t }],
      mockups: [],
      followUps: [],
      queueRank: t,
      draftRank: t,
      ...f,
    };
    this.save(task);
    return task;
  }

  /** A Scout run's picks: a backlog task is picked up, a finding becomes a task; all go to planning. */
  private async scouted(goal: Goal, by: string, picks: ScoutPick[], shown: Candidate[]): Promise<string[]> {
    const ids: string[] = [];
    for (const pick of picks) {
      const c = shown.find((x) => x.from === pick.from);
      const source = c && this.store.task(c.task);
      if (!c || !source) continue;
      if (c.kind === "backlog") {
        if (source.state !== "backlog") continue;
        this.event(source, "factory", `Scout picked it up from the backlog for @${by}`);
        await this.startPlanning(source, by, source.plan.length > 0);
        ids.push(source.id);
        continue;
      }
      // Made since by someone else (or a run that overlapped): don't make it twice.
      if (this.store.tasks().some((t) => t.scoutedFrom === pick.from)) continue;
      const checks = pick.doneWhen.map((d) => `- ${d}`).join("\n");
      const brief = checks ? `${pick.brief}\n\n## Done when\n${checks}` : pick.brief;
      const task = this.newTask(goal, by, { title: pick.title, brief, tickets: [], shareable: source.shareable, agent: source.agent, model: source.model ?? null, intake: null, repo: source.repo ?? null, after: [], effort: source.effort ?? null });
      task.scoutedFrom = pick.from;
      this.event(task, "factory", `Scouted from ${source.id}`);
      await audit(this.env, by, "task.created", task.id, { title: task.title, scoutedFrom: pick.from });
      await this.startPlanning(task, by);
      ids.push(task.id);
    }
    return ids;
  }

  /** A plan just got its approvals: it builds, and its other repos' parts become tasks that wait on it. */
  private async approved(task: Task, why: string) {
    task.state = "building";
    task.waiting = null;
    if (task.suggestedTitle) {
      const old = task.title;
      task.title = task.suggestedTitle;
      task.suggestedTitle = null;
      this.event(task, "factory", `renamed it from "${old}"`);
    }
    this.event(task, "factory", why);
    this.stat(task, "plan.approved", { version: task.planVersion, approvals: task.approvals.length }, task.approvals.at(-1) ?? "factory");
    const goal = this.store.goal(task.goal);
    if (!goal) return;
    for (const f of task.followUps.filter((f) => !f.task)) {
      const part = this.newTask(goal, task.owner, { title: f.title, brief: f.brief, tickets: [], shareable: task.shareable, agent: task.agent, model: task.model ?? null, intake: null, repo: f.repo, after: [task.id], effort: task.effort ?? null });
      f.task = part.id;
      this.event(task, "factory", `made ${part.id} for its ${f.repo} part`);
      await this.startPlanning(part, "factory");
    }
  }

  /** The session a task needs now, if any. */
  private roleFor(task: Task): Role | null {
    if (!needsSession(task, this.store.private(task.id))) return null;
    return task.state === "planning" ? "planner" : task.state === "building" ? "builder" : "reviewer";
  }

  /** Starts `role` for `task`, or says why it can't yet. */
  private async dispatch(task: Task, role: Role, machines: Machine[]): Promise<string | null> {
    const goal = this.store.goal(task.goal);
    if (!goal) return "Its goal is gone.";
    if (!goal.folder && !taskRepo(task, goal)) return `The goal ${goal.name} doesn't say where its code is: set a repo or folder.`;
    if (task.startAt != null && task.startAt > now()) {
      this.hooks.wakeIn(task.startAt - now());
      return `Scheduled to start at ${new Date(task.startAt).toISOString()}.`;
    }
    if (role === "builder") {
      // Work that builds on another repo's change starts once that change is in.
      const before = task.after.map((id) => this.store.task(id)).filter((t): t is Task => !!t && t.state !== "merged");
      const dropped = before.find((t) => t.state === "cancelled");
      if (dropped) return `${dropped.id}, which it builds on, was cancelled. Take it off its "after" list or cancel this too.`;
      if (before.length) return `Waiting for ${before.map((t) => t.id).join(" and ")} to merge first.`;
    }
    const priv = this.store.private(task.id);
    const live = this.store.liveSessions();
    const busy = (m: string, kind?: string) => live.filter((s) => s.machine === m && (!kind || s.kind === kind)).length;

    let machine: Machine | undefined;
    let kind: TaskSession["kind"] = "personal";
    if (task.machine && priv.worktree) {
      // Its worktree is on one machine: the rest of its sessions run there.
      machine = machines.find((m) => m.id === task.machine);
      if (!machine) return `${task.machine} was removed; move it to start over elsewhere.`;
      if (!machine.online) return `Waiting for ${machine.name} to come back online.`;
      if (this.store.settings(machine.id).paused) return `${machine.name} is paused.`;
      const capped = this.overCap(machine, task.agent, task.owner);
      if (capped) return capped;
      kind = machine.owner === task.owner ? "personal" : "team";
    } else {
      const usable = machines.filter((m) => m.online && !this.store.settings(m.id).paused && this.hasAgent(m, task.agent) && !this.overCap(m, task.agent, task.owner));
      // Forced: any of its owner's own machines, full or not; never a teammate's past what they lend.
      const own = usable.filter((m) => m.owner === task.owner && (task.force || busy(m.id) < this.capacity(m)));
      machine = own.sort((a, b) => busy(a.id) - busy(b.id))[0];
      if (!machine && task.shareable) {
        const lent = usable.filter((m) => {
          const s = this.store.settings(m.id);
          const load = m.health ? m.health.load1 / Math.max(1, m.health.cores) : 0;
          const lendable = s.lendIdle ? this.capacity(m) : s.teamSlots;
          return m.owner !== task.owner && busy(m.id, "team") < lendable && busy(m.id) < this.capacity(m) && load < s.loadCap;
        });
        machine = lent.sort((a, b) => busy(a.id) - busy(b.id))[0];
        kind = "team";
      }
      if (!machine) {
        // Named for its owner: a teammate reads it too, and it changes hands when the task does.
        const mine = machines.filter((m) => m.owner === task.owner);
        const theirs = `${task.owner}'s machines`;
        if (!mine.length) return task.shareable ? `Waiting for a free team slot (${task.owner} has no machines).` : `Waiting for one of ${theirs}: add one under Machines.`;
        const online = mine.filter((m) => m.online);
        const listed = (ms: Machine[]) => ms.map((m) => m.name).join(", ");
        if (!online.length) return task.shareable ? `${theirs} (${listed(mine)}) are offline; waiting for them or a team slot.` : `Waiting for one of ${theirs} (${listed(mine)}) to come online.`;
        const running = online.filter((m) => !this.store.settings(m.id).paused);
        if (!running.length) {
          const names = online.map((m) => m.name).join(", ");
          return task.shareable ? `${names} ${online.length === 1 ? "is" : "are"} paused; waiting for a team slot.` : `${names} ${online.length === 1 ? "is" : "are"} paused.`;
        }
        if (!running.some((m) => this.hasAgent(m, task.agent))) return `None of ${task.owner}'s online machines (${listed(running)}) has ${task.agent} installed.`;
        const capped = running.map((m) => this.overCap(m, task.agent, task.owner)).find(Boolean);
        if (capped && !running.some((m) => this.hasAgent(m, task.agent) && !this.overCap(m, task.agent, task.owner))) return capped;
        return `Waiting for a free slot on ${theirs} (${listed(running)})${task.shareable ? " or the team's" : ""}.`;
      }
    }

    const id = crypto.randomUUID();
    const resumed = priv.movedFrom
      ? { reason: `This task was moved here from ${priv.movedFrom.machine}${priv.movedFrom.commit ? `; its work so far is on the branch, up to ${priv.movedFrom.commit.slice(0, 7)} (any "WIP" commit is unfinished)` : ""}.` }
      : priv.restarts > 0 ? { reason: "Your last session ended before you finished." } : null;
    const org = this.store.prompts();
    const others = role === "reviewer" ? [] : this.moving(task);
    const repoPrompts = this.store.repoPrompts(taskRepo(task, goal));
    const prompt = role === "planner" ? plannerPrompt(task, goal, org, others, repoPrompts) : role === "builder" ? builderPrompt(task, goal, resumed, org, others, repoPrompts) : reviewerPrompt(task, goal, priv.base ?? goal.base ?? "main", org, repoPrompts);
    const existing = Boolean(priv.worktree && task.machine === machine.id);
    const command: ServerToRunner = {
      type: "session.open",
      id,
      agent: task.agent,
      // No folder: the runner finds its checkout of the task's repo, or clones it.
      cwd: existing ? priv.worktree! : (goal.folder ?? ""),
      cols: COLS,
      rows: ROWS,
      prompt,
      resume: false,
      taskId: task.id,
      worktree: { name: branchName(task), base: goal.base ?? null, existing },
      task: { id: task.id, repo: taskRepo(task, goal), scripts: this.store.scriptsFor(taskRepo(task, goal)) },
      unattended: { mode: this.store.get("unattended") ?? "project", commands: [] },
      model: task.model ?? null,
      connectors: this.connectors(),
    };
    if (!(await this.toRunner(machine.id, command))) return `Couldn't reach ${machine.name}.`;
    const now_ = this.store.task(task.id);
    if (!now_ || now_.worker || this.roleFor(now_) !== role) {
      // It was cancelled, moved or started elsewhere while the machine was opening this one.
      this.hooks.waitUntil(this.toRunner(machine.id, { type: "session.kill", id }, "factory"));
      return null;
    }
    Object.assign(task, now_);
    this.store.addSession({ id, task: task.id, role, machine: machine.id, agent: task.agent, started: now(), ended: null, cause: null, kind });
    if (priv.movedFrom) this.store.savePrivate(task.id, { ...this.store.private(task.id), movedFrom: null });
    task.worker = { role, agent: task.agent, machine: machine.id, session: id, startedAt: now() };
    task.startAt = null;
    task.force = null;
    task.machine = machine.id;
    task.branch = `agent/${branchName(task)}`;
    task.liveLog = role === "planner" ? "Reading the code…" : role === "builder" ? "Starting…" : "Reading the change…";
    this.event(task, role, `started on ${machine.name}${kind === "team" ? ` (a team slot from ${machine.owner})` : ""}`);
    this.save(task);
    return null;
  }

  /** Why a machine's usage cap stops new work for `agent` there (for a task of `owner`'s), if it does. */
  private overCap(machine: Machine, agent: string, owner: string): string | null {
    const s = this.store.settings(machine.id);
    if (s.capsTeamOnly && owner === machine.owner) return null;
    const usage = machine.usage?.find((u) => u.agent === agent);
    if (!usage) return null;
    const own = s.agentCaps?.find((c) => c.agent === agent);
    const sessionCap = own ? own.session ?? null : s.sessionCap ?? null;
    const weeklyCap = own ? own.weekly ?? null : s.weeklyCap ?? null;
    for (const w of usage.windows) {
      const cap = w.label === "5h" ? sessionCap : w.label === "7d" && !w.name ? weeklyCap : null;
      if (cap != null && w.usedPercent >= cap * 100) {
        const window = w.label === "5h" ? "5-hour session" : "week";
        return `${machine.name}'s ${agent} account has used ${Math.round(w.usedPercent)}% of its ${window} (the cap is ${Math.round(cap * 100)}%).`;
      }
    }
    return null;
  }

  /** The enabled MCP connectors for a session.open, secrets included: these go to runners only. */
  connectors(): McpConnector[] {
    return this.store.connectors().filter((c) => c.enabled);
  }

  private hasAgent(machine: Machine, agent: string) {
    // Before its first health report a machine's agents aren't known; let it try.
    // Health lists the agents it knows to look for; others (agents.toml) are assumed present.
    if (!["claude", "codex"].includes(agent)) return true;
    return !machine.health || machine.health.agents.some((a) => a.name === agent);
  }

  /** The factory sessions a machine takes now: its setting, else from its cores. */
  capacity(machine: Machine) {
    const set = this.store.settings(machine.id).capacity;
    if (set != null) return set;
    const cores = machine.health?.cores ?? 4;
    return Math.max(1, Math.min(4, Math.floor(cores / 4)));
  }

  // ---------------------------------------------------------------------------
  // Runners

  /** What a runner said that's about the factory. `mcp.request` gets an answer for the runner. */
  async fromRunner(machine: string, msg: RunnerMessage): Promise<Reply | null> {
    switch (msg.type) {
      case "mcp.request": return this.tool(msg.session, msg.tool, (msg.args ?? {}) as Record<string, unknown>);
      case "draft.progress":
        // A Scout run only reports what it picked, at the end; a setup run shows what it's reading.
        if (msg.id.startsWith(SETUP_PREFIX)) this.setup.progress(msg.id, machine, msg.text, msg.kind ?? "tool");
        else if (!msg.id.startsWith(SCOUT_PREFIX)) this.drafts.progress(msg.id, machine, msg.text, msg.kind ?? "tool");
        return null;
      case "draft.done":
        if (msg.id.startsWith(SCOUT_PREFIX)) await this.scout.done(msg.id, machine, msg.output ?? null, msg.error ?? null);
        else if (msg.id.startsWith(SETUP_PREFIX)) this.setup.done(msg.id, machine, msg.output ?? null, msg.error ?? null);
        else await this.drafts.done(msg.id, machine, msg.output ?? null, msg.error ?? null);
        return null;
      case "session.opened": {
        const s = msg.session.taskId ? this.store.session(msg.session.id) : null;
        if (!s) return null;
        const task = this.store.task(s.task);
        if (!task) return null;
        const priv = this.store.private(task.id);
        // The planner's session opens in the worktree it made.
        if (!priv.worktree || task.machine !== machine) this.store.savePrivate(task.id, { ...priv, worktree: msg.session.cwd });
        return null;
      }
      case "session.error": {
        const s = this.store.session(msg.id);
        if (!s) return null;
        this.store.endSession(msg.id, "error");
        const task = this.store.task(s.task);
        if (!task || task.worker?.session !== msg.id) return null;
        task.worker = null;
        task.liveLog = null;
        this.raise(task, s.role, "sessionEnded", `Its ${s.role} couldn't start on ${machine}: ${msg.message}`);
        this.save(task);
        return null;
      }
      case "session.activity": {
        const s = this.store.session(msg.id);
        const task = s && this.store.task(s.task);
        if (!task || task.worker?.session !== msg.id) return null;
        const trusting = msg.activity.state === "waiting" && msg.activity.message === TRUST_PROMPT;
        if (trusting && !task.hand) {
          const where = (await this.hooks.machines()).find((m) => m.id === s.machine)?.name ?? s.machine;
          this.raise(task, s.role, "needsInput", `${TRUST_HAND} on ${where}. Approve it in the Session tab (or on ${where}) and it carries on.`);
          // Answering this hand would type into the prompt: approving it in the session is the way.
          task.hand!.options = [];
          this.save(task);
          return null;
        }
        if (!trusting && task.hand?.summary.startsWith(TRUST_HAND)) {
          this.lowerHand(task, "factory");
          this.event(task, s.role, "carried on once its folder was trusted");
          this.save(task);
        }
        const line = msg.activity.state === "waiting" ? `Waiting: ${msg.activity.message ?? "a permission prompt"}` : (msg.activity.step ?? msg.activity.message);
        if (line && line !== task.liveLog) {
          task.liveLog = line;
          this.save(task, false);
        }
        return null;
      }
      case "session.ended": {
        await this.ended(msg.end);
        return null;
      }
      case "session.cost": {
        // Filed under the session's task and role; anything the factory didn't start is dropped.
        const c = msg.cost;
        const s = this.store.session(c.session);
        const task = s && this.store.task(s.task);
        if (!s || !task) return null;
        this.store.recordSessionCost({
          session: s.id, task: task.id, goal: task.goal, role: s.role, agent: c.agent || s.agent, model: c.model ?? null,
          costUsd: c.costUsd ?? null,
          tokens: { input: c.inputTokens, output: c.outputTokens, cacheRead: c.cacheReadTokens, cacheWrite: c.cacheWriteTokens },
          updated: Date.now(),
        });
        return null;
      }
      case "task.started": {
        const task = this.store.task(msg.taskId);
        if (!task) return null;
        this.store.savePrivate(task.id, { ...this.store.private(task.id), repoDir: msg.repoDir, base: msg.base });
        return null;
      }
      case "task.progress":
      case "task.cleaned": {
        // A worktree script's line, or how cleaning up went: on the task's timeline.
        const task = this.store.task(msg.taskId);
        if (!task || task.machine !== machine) return null;
        const text = msg.type === "task.progress" ? msg.text : msg.ok ? `cleaned up: ${msg.message ?? "its worktree was removed"}` : `couldn't clean up: ${msg.message ?? "no reason given"}`;
        this.event(task, "factory", text.slice(0, 2000));
        if (msg.type === "task.progress" && task.worker) task.liveLog = msg.text.split("\n")[0].slice(0, 200);
        this.save(task, false);
        return null;
      }
      case "task.finished": return this.finished(msg), null;
      case "task.handed_off": return this.handedOff(machine, msg), null;
      case "task.diff": {
        const task = this.store.task(msg.taskId);
        if (!task || !msg.ok) return null;
        this.store.set(`patch:${task.id}`, msg.patch);
        task.diff = {
          added: msg.files.reduce((n, f) => n + f.added, 0),
          removed: msg.files.reduce((n, f) => n + f.removed, 0),
          files: msg.files.map((f) => f.path),
        };
        // Measured now, not estimated: the size can change its risk.
        this.applyPolicy(task);
        this.save(task, false);
        this.refreshForecasts(task);
        await this.autoMerge(task);
        return null;
      }
      case "task.merged": return this.merged(msg), null;
      case "task.merge_check": {
        const task = this.store.task(msg.taskId);
        if (!task || task.machine !== machine) return null;
        await this.mergeChecked(task, msg);
        return null;
      }
      case "task.token_request": {
        // A token for the task's repo, only for the machine it's on; without the app the runner
        // fetches and pushes with the machine's own credentials.
        const reply = (token: string | null, error: string | null, code: string | null) =>
          this.toRunner(machine, { type: "task.token", reqId: msg.reqId, token, error, code });
        const app = githubApp(this.env);
        if (!app) return await reply(null, "The factory has no GitHub App installed.", "not_installed"), null;
        if (this.drafts.forRun(msg.taskId, machine) || this.scout.forRun(msg.taskId, machine) || this.setup.forRun(msg.taskId, machine)) {
          // Draft with AI and Scout read their goal's code, Set up with AI its repo's: a fetch of one of those repos, nothing more.
          const full = `${msg.owner}/${msg.repo}`;
          const mayFetch = msg.taskId.startsWith(SCOUT_PREFIX) ? this.scout.mayFetch(msg.taskId, machine, full)
            : msg.taskId.startsWith(SETUP_PREFIX) ? this.setup.mayFetch(msg.taskId, machine, full)
            : this.drafts.mayFetch(msg.taskId, machine, full);
          if (msg.purpose !== "fetch" || !mayFetch) {
            return await reply(null, "A draft can only fetch its goal's repos.", "api"), null;
          }
          try {
            await reply((await repoToken(app, msg.owner, msg.repo, PERMISSIONS.fetch)).token, null, null);
          } catch (e) {
            await reply(null, (e as Error).message, e instanceof GitHubError ? e.code : "api");
          }
          return null;
        }
        const task = this.store.task(msg.taskId);
        const goal = task && this.store.goal(task.goal);
        if (!task || task.machine !== machine) return await reply(null, "That task isn't running on this machine.", "api"), null;
        const repo = taskRepo(task, goal ?? null);
        if (repo && repo.toLowerCase() !== `${msg.owner}/${msg.repo}`.toLowerCase()) return await reply(null, `${task.id} works on ${repo}, not ${msg.owner}/${msg.repo}.`, "api"), null;
        try {
          const { token } = await repoToken(app, msg.owner, msg.repo, msg.purpose === "fetch" ? PERMISSIONS.fetch : PERMISSIONS.push);
          await reply(token, null, null);
        } catch (e) {
          await reply(null, (e as Error).message, e instanceof GitHubError ? e.code : "api");
        }
        return null;
      }
      case "secrets.request": return this.releaseSecrets(machine, msg), null;
      default:
        return null;
    }
  }

  /** A repo's secret values, to a machine with a planning, building or reviewing task on that repo assigned to it, or (no task: the
   *  `maple-runner secrets pull` CLI) to a machine whose owner is an admin. Every release is audited. The runner's own check that the
   *  CLI was run by a person isn't relied on: an agent on the machine can get around it. */
  private async releaseSecrets(machine: string, msg: Extract<RunnerMessage, { type: "secrets.request" }>) {
    const reply = (values: Record<string, string> | null, error: string | null, code: string | null) =>
      this.toRunner(machine, { type: "secrets.reply", reqId: msg.reqId, values, error, code });
    const repo = this.store.repos().find((r) => r.name.toLowerCase() === msg.repo.trim().toLowerCase())?.name;
    if (!repo) return reply(null, `${msg.repo} isn't one of the org's repos.`, "unknown_repo");
    let actor: string;
    if (msg.taskId) {
      const task = this.store.task(msg.taskId);
      if (!task || task.machine !== machine) return reply(null, "That task isn't assigned to this machine.", "forbidden");
      // Only while an agent works on it there: a merged or cancelled task keeps its last machine.
      if (!SECRET_STATES.has(task.state)) return reply(null, `${task.id} isn't being planned, built or reviewed (it's ${task.state}).`, "forbidden");
      const taskRepoName = taskRepo(task, this.store.goal(task.goal) ?? null);
      if (taskRepoName?.toLowerCase() !== repo.toLowerCase()) return reply(null, `${task.id} works on ${taskRepoName ?? "no repo"}, not ${repo}.`, "forbidden");
      actor = task.id;
    } else {
      const owner = (await this.hooks.machines()).find((m) => m.id === machine)?.owner;
      const member = owner ? (await this.hooks.members()).find((m) => m.login === owner) : undefined;
      if (!member) return reply(null, "This machine's owner isn't a member of the org.", "forbidden");
      if (member.role !== "admin") return reply(null, "Only an admin's machine can pull secrets; ask an admin to pull, or run it from a task.", "forbidden");
      actor = owner!;
    }
    let values: Record<string, string>;
    try {
      values = await this.secrets.values(repo);
    } catch (e) {
      console.error("secrets: couldn't open", repo, e);
      return reply(null, "The factory couldn't decrypt this repo's secrets (was SECRETS_KEY changed?).", "decrypt");
    }
    // Every task session asks; only a release of something is worth a row.
    if (!Object.keys(values).length) return reply(values, null, null);
    await audit(this.env, `machine:${machine}`, "secret.pulled", repo, { machine, repo, task: msg.taskId ?? null, for: actor, names: Object.keys(values).sort() });
    return reply(values, null, null);
  }

  /** A session ended. The ones the factory closed are already marked; anything else is unplanned. */
  private async ended(end: SessionEnd) {
    const s = this.store.session(end.id);
    if (!s) return;
    const planned = s.ended != null;
    this.store.endSession(end.id, end.cause);
    const task = this.store.task(s.task);
    if (!task) return;
    if (task.worker?.session !== end.id) return this.cleanup(task);
    task.worker = null;
    task.liveLog = null;
    if (planned || task.state === "cancelled" || task.state === "merged") {
      this.save(task);
      await this.cleanup(task);
      return this.pump();
    }
    const priv = this.store.private(task.id);
    const where = (await this.hooks.machines()).find((m) => m.id === s.machine)?.name ?? s.machine;
    if (priv.restarts >= MAX_RESTARTS || !["machineSlept", "tmuxLost", "runnerUpdated", "signaled", "outOfMemory"].includes(end.cause)) {
      this.stat(task, "session.ended", { cause: end.cause }, end.cause === "killed" ? end.by ?? null : null, s.role);
    }
    switch (end.cause) {
      case "machineSlept":
      case "tmuxLost":
      case "runnerUpdated":
      case "signaled":
      case "outOfMemory":
        if (priv.restarts < MAX_RESTARTS) {
          this.store.savePrivate(task.id, { ...priv, restarts: priv.restarts + 1 });
          this.event(task, "factory", `its ${s.role} ended (${describeCause(end)}); starting it again`);
          this.stat(task, "session.restarted", { cause: end.cause }, null, s.role);
          this.save(task);
          return this.pump();
        }
        this.raise(task, s.role, "sessionEnded", `Its ${s.role} on ${where} keeps ending (${describeCause(end)}).`);
        break;
      case "authExpired":
        this.raise(task, s.role, "sessionEnded", `${task.agent}'s login on ${where} expired. Sign in again there, then pick Retry.`);
        break;
      case "usageLimit":
        this.raise(task, s.role, "sessionEnded", `The ${task.agent} account on ${where} hit its usage limit. Retry when it resets, or move it.`);
        break;
      case "killed":
        this.raise(task, s.role, "sessionEnded", `${end.by ?? "Someone"} ended its ${s.role} session.`);
        break;
      default:
        this.raise(task, s.role, "sessionEnded", `Its ${s.role} exited before it reported back${end.code != null ? ` (code ${end.code})` : ""}.`);
    }
    this.save(task);
  }

  private finished(msg: Extract<RunnerMessage, { type: "task.finished" }>) {
    const task = this.store.task(msg.taskId);
    if (!task) return;
    const priv = this.store.private(task.id);
    this.store.savePrivate(task.id, { ...priv, finishing: false });
    // A push that was already under way when the task was cancelled (or merged): it stays that way.
    if (task.state === "cancelled" || task.state === "merged") return;
    if (!msg.ok) {
      this.raise(task, "builder", "needsInput", `Pushing failed: ${msg.message ?? "no reason given"}.`);
      this.save(task);
      return;
    }
    const goal = this.store.goal(task.goal);
    const base = msg.base ?? priv.base ?? goal?.base ?? "main";
    task.pr = task.pr
      ? { ...task.pr, head: msg.commit ?? null, state: "open" }
      : { number: Number(this.store.nextId("PR").split("-")[1]), url: null, state: "open", head: msg.commit ?? null, branch: msg.branch, base, checks: [] };
    this.closeWorker(task, "done");
    task.state = "reviewing";
    task.reviews = [];
    // Conflicts found on the old head: what it pushed is checked again before it merges.
    if (task.mergeForecast) task.mergeForecast = { ...task.mergeForecast, conflicts: [], since: null, checkedAt: null };
    const review = task.autoReview ?? { maxRounds: MAX_REVIEW_ROUNDS, rounds: [], summary: "", ask: [], proofs: [], findings: [] };
    review.rounds.push({ number: review.rounds.length + 1, verdict: "inProgress", found: 0, at: now(), fix: null });
    task.autoReview = review;
    this.event(task, "builder", `pushed ${msg.commit?.slice(0, 7) ?? msg.branch}${msg.pushed === "fallback" ? " with the machine's credentials" : ""}`);
    this.save(task);
    if (task.machine && priv.worktree) this.hooks.waitUntil(this.toRunner(task.machine, { type: "task.diff", taskId: task.id, cwd: priv.worktree, base }));
    if (msg.pushed === "app" && msg.owner && msg.repo) this.hooks.waitUntil(this.openPull(task.id, msg.owner, msg.repo));
    this.hooks.waitUntil(this.pump());
  }

  // ---------------------------------------------------------------------------
  // GitHub: the pull request and its CI, when the app pushed the branch

  /** Opens the task's pull request on GitHub (or finds it, pushed again), then reads its CI. */
  private async openPull(id: string, owner: string, repo: string) {
    const app = githubApp(this.env);
    let task = this.store.task(id);
    if (!app || !task?.pr) return;
    try {
      if (!task.pr.url) {
        const pr = await createPullRequest(app, owner, repo, { title: `${task.id}: ${task.title}`, head: task.pr.branch, base: task.pr.base, body: pullBody(task) });
        task = this.store.task(id);
        if (!task?.pr) return;
        task.pr.number = pr.number;
        task.pr.url = pr.url;
        this.event(task, "factory", `opened pull request #${pr.number} on ${owner}/${repo}`);
      }
      this.store.savePrivate(task.id, { ...this.store.private(task.id), gh: { owner, repo }, prOpenedAt: now() });
      this.save(task);
      await this.refreshChecks(task.id);
    } catch (e) {
      const t = this.store.task(id);
      if (!t) return;
      this.event(t, "factory", `couldn't open a pull request on ${owner}/${repo}: ${(e as Error).message}`);
      this.save(t);
    }
  }

  /** Whether a task's CI may still change: checks running, or none yet on a fresh pull request. */
  private ciPending(task: Task): boolean {
    const priv = this.store.private(task.id);
    if (!priv.gh || !task.pr?.head || task.pr.state !== "open" || task.state === "merged" || task.state === "cancelled") return false;
    if (task.pr.checks.some((c) => c.status === "queued" || c.status === "running")) return true;
    return task.pr.checks.length === 0 && now() - (priv.prOpenedAt ?? 0) < CI_APPEAR_MS;
  }

  /** The review threads on a task's GitHub pull request; none for a local repo or a task without one. */
  async threads(id: string): Promise<ReviewThread[]> {
    const app = githubApp(this.env);
    const task = this.store.task(id);
    const gh = task && this.store.private(id).gh;
    if (!app || !task?.pr || !gh) return [];
    return reviewThreads(app, gh.owner, gh.repo, task.pr.number);
  }

  /** One of a task's CI checks' log, for `task.checkLog`: read from GitHub each time, never kept. */
  async checkLog(id: string, name: string): Promise<ServerToClient & { type: "checkLog" }> {
    const app = githubApp(this.env);
    const task = this.store.task(id);
    if (!task) fail("That task isn't there any more.");
    const priv = this.store.private(id);
    if (!app || !priv.gh || !task!.pr) fail("Its checks aren't on GitHub.");
    const check = (priv.checks ?? []).find((c) => c.name === name);
    if (!check) fail(`There's no check ${name} on it.`);
    const url = check!.url ?? (task!.pr!.url ? `${task!.pr!.url}/checks` : null);
    const log = await checkLog(app!, priv.gh!.owner, priv.gh!.repo, check!).catch((e) => fail((e as Error).message));
    return { type: "checkLog", id, check: check!.name, url, text: log.text, truncated: log.truncated, failedStep: log.failedStep };
  }

  /** Reads CI again for every pull request still waiting on it; the hub's alarm calls this. */
  async pollCI() {
    for (const task of this.store.tasks().filter((t) => this.ciPending(t))) await this.refreshChecks(task.id);
  }

  /** Reads the task's CI from GitHub; all passed may let it merge. Keeps reading while it runs. */
  async refreshChecks(id: string) {
    const app = githubApp(this.env);
    const task = this.store.task(id);
    const gh = task && this.store.private(id).gh;
    if (!app || !task?.pr?.head || !gh) return;
    const found = await checks(app, gh.owner, gh.repo, task.pr.head).catch(() => null);
    const now_ = this.store.task(id);
    if (!now_?.pr) return;
    if (!found) {
      if (this.ciPending(now_)) this.hooks.wakeIn(CI_POLL_MS);
      return;
    }
    const before = now_.pr.checks.map((c) => `${c.name}:${c.status}`).join();
    const links = now_.pr.checks.map((c) => c.url ?? "").join();
    now_.pr.checks = found.map((c) => ({ name: c.name, status: c.status, duration: c.duration, required: true, url: c.url ?? null }));
    this.store.savePrivate(id, { ...this.store.private(id), checks: found });
    if (this.ciPending(now_)) this.hooks.wakeIn(CI_POLL_MS);
    if (now_.pr.checks.map((c) => `${c.name}:${c.status}`).join() === before) {
      // Same results, but a check's link changed (a re-run is a new job): the apps get the new one.
      if (now_.pr.checks.map((c) => c.url ?? "").join() !== links) this.save(now_);
      return;
    }
    const failed = found.filter((c) => c.status === "failed");
    if (failed.length) this.event(now_, "factory", `CI failed: ${failed.map((c) => c.name).join(", ")}`);
    else if (found.length && found.every((c) => c.status === "passed")) this.event(now_, "factory", "CI passed");
    this.save(now_);
    await this.autoMerge(now_);
  }

  /** A GitHub webhook about a repo's checks or pull requests: the tasks it's about read their CI again. */
  /** Reads the repos the GitHub App is installed on, keeping the ones added by hand. `asked`: a
   *  person pressed Refresh, so failures are theirs to see. */
  async refreshRepos(asked = false) {
    const app = githubApp(this.env);
    if (!app) {
      if (asked) fail("There's no GitHub App set up, so repos are added by hand.");
      return;
    }
    let granted: OrgRepo[];
    try {
      // The factory's own account, and the others an admin approved: the app is public, so anyone
      // can install it, and their installations mustn't add repos here.
      const owners = new Set([this.env.GITHUB_ORG, ...this.store.repoOwners()].filter(Boolean).map((o) => o.toLowerCase()));
      granted = await installedRepos(app, (login) => owners.has(login.toLowerCase()));
    } catch (e) {
      if (asked) fail(`Couldn't read the app's repos: ${(e as Error).message}`);
      return;
    }
    const manual = this.store.repos().filter((r) => r.source === "manual" && !granted.some((g) => g.name.toLowerCase() === r.name.toLowerCase()));
    this.store.saveRepos([...granted, ...manual]);
    this.reposUpdated();
  }

  async fromGitHub(event: { owner: string; repo: string; sha?: string | null; number?: number | null; merged?: boolean; closed?: boolean }) {
    const repo = `${event.owner}/${event.repo}`.toLowerCase();
    for (const task of this.store.tasks()) {
      const gh = this.store.private(task.id).gh;
      if (!gh || `${gh.owner}/${gh.repo}`.toLowerCase() !== repo || !task.pr) continue;
      if (!(event.sha && task.pr.head === event.sha) && !(event.number && task.pr.number === event.number)) continue;
      if (event.closed && task.state !== "merged" && task.state !== "cancelled") {
        if (event.merged) this.merged({ type: "task.merged", taskId: task.id, ok: true, commit: null, message: null });
        else {
          task.pr.state = "closed";
          this.event(task, "factory", `pull request #${task.pr.number} was closed on GitHub`);
          this.save(task);
        }
        continue;
      }
      await this.refreshChecks(task.id);
    }
  }

  private merged(msg: Extract<RunnerMessage, { type: "task.merged" }>) {
    const task = this.store.task(msg.taskId);
    // Already merged: a second answer (a webhook after the merge call's own) changes nothing.
    if (!task || !task.pr || task.state === "merged") return;
    task.liveLog = null;
    this.store.savePrivate(task.id, { ...this.store.private(task.id), merging: false });
    if (!msg.ok) {
      const why = msg.message ?? "no reason given";
      // With the policy's say-so, a builder fixes it (a few times at most) before a person is asked.
      const tries = this.store.private(task.id).mergeFixes ?? 0;
      const autoFix = this.store.policy().autoFixMerges !== false;
      if (autoFix && tries < MERGE_FIX_TRIES) {
        const n = tries + 1;
        this.store.savePrivate(task.id, { ...this.store.private(task.id), mergeFixes: n });
        this.event(task, "factory", `couldn't merge: ${why}; sent it back to fix the merge (try ${n} of ${MERGE_FIX_TRIES})`);
        this.hooks.broadcast({ type: "toast", text: `${task.id} didn't merge; a builder is fixing it (try ${n} of ${MERGE_FIX_TRIES}).`, taskId: task.id });
        this.save(task);
        this.hooks.waitUntil(this.sendBackToFixMerge(task, "factory", why));
        return;
      }
      this.event(task, "factory", `couldn't merge: ${why}`);
      this.hooks.broadcast({ type: "toast", text: `${task.id} didn't merge: ${why}`, taskId: task.id });
      // A person picks the way forward.
      // The runner's message already says it didn't merge; GitHub's may not.
      const gaveUp = autoFix ? ` (after ${MERGE_FIX_TRIES} tries)` : "";
      const summary = (/merge/i.test(why) ? why : `It didn't merge into ${task.pr.base}: ${why}`) + gaveUp;
      this.raise(task, "factory", "mergeFailed", summary, [
        { title: MERGE_FIX, detail: `A builder updates the branch from ${task.pr.base}, resolves the conflicts and pushes; review and approvals run again.`, recommended: true },
        { title: MERGE_RETRY, detail: "Merge it again as it is.", recommended: false },
        { title: "Cancel it", detail: "Stop the task; its branch stays.", recommended: false },
      ]);
      this.save(task);
      return;
    }
    const by = this.store.private(task.id).mergeBy ?? null;
    this.stat(task, "merged", { auto: by === "factory", cycleMs: now() - task.createdAt }, by);
    task.state = "merged";
    task.pr.state = "merged";
    this.event(task, "factory", `merged into ${task.pr.base} (${msg.commit?.slice(0, 7) ?? ""})`);
    // The runner's merge (no GitHub App) deleted the branch on origin, or says why not.
    const branch = msg.branch ? branchNote(task.pr.branch, msg.branch) : null;
    if (branch) this.event(task, "factory", branch.text);
    this.intake.forTask(task, `${task.id} is merged into ${task.pr.base}. Thanks for asking!`);
    this.save(task);
    this.hooks.broadcast({ type: "toast", text: `${task.id} merged into ${task.pr.base}.`, taskId: task.id });
    const priv = this.store.private(task.id);
    this.store.savePrivate(task.id, { ...priv, mergedAs: msg.commit ?? null, mergeFixes: 0, remoteBranch: branch?.outcome ?? priv.remoteBranch ?? null });
    this.hooks.waitUntil(this.cleanup(task));
    // What it overlapped may not merge any more: each of those still in review gets a dry-run merge now,
    // rather than finding out when its own merge fails.
    const affected = affectedBy(task, this.store.tasks());
    this.refreshForecasts(task);
    for (const other of affected) if (other.state === "reviewing") this.hooks.waitUntil(this.checkMerge(other, task.id));
    // Tasks waiting on this one ("after") can build now.
    if (this.store.tasks().some((t) => t.after.includes(task.id))) this.hooks.waitUntil(this.pump());
  }

  /** Ends a task's work: its session, its pull request, anything waiting on a person. */
  private async cancel(task: Task, who: string, why = "cancelled it") {
    this.stat(task, "cancelled", { state: task.state }, who);
    await this.closeWorker(task, "cancelled");
    task.state = "cancelled";
    // Nothing's reviewing it or going to merge it now.
    if (task.pr && (task.pr.state === "open" || task.pr.state === "draft")) {
      task.pr.state = "closed";
      const app = githubApp(this.env);
      const gh = this.store.private(task.id).gh;
      if (app && gh && task.pr.url) {
        this.hooks.waitUntil(closePullRequest(app, gh.owner, gh.repo, task.pr.number, `${who} cancelled ${task.id} in Maple Factory.`).catch(() => {}));
      }
    }
    if (task.autoReview?.rounds.at(-1)?.verdict === "inProgress") task.autoReview.rounds.pop();
    task.waiting = null;
    task.question = null;
    this.lowerHand(task, who);
    this.event(task, who, why);
    this.save(task);
    this.refreshForecasts(task);
    await audit(this.env, who, "task.cancelled", task.id);
  }

  /** Reopens a cancelled task's closed pull request. When GitHub won't (its branch is gone, say),
   *  the task forgets it and this says false, so the task builds again and its push opens a new one. */
  private async reopenPull(task: Task, who: string): Promise<boolean> {
    const pr = task.pr!;
    const app = githubApp(this.env);
    const gh = this.store.private(task.id).gh;
    if (!app || !gh || !pr.url) {
      pr.state = "open";
      return true;
    }
    try {
      await reopenPullRequest(app, gh.owner, gh.repo, pr.number, `${who} picked ${task.id} back up in Maple Factory.`);
      pr.state = "open";
      this.event(task, "factory", `reopened pull request #${pr.number}`);
      return true;
    } catch (e) {
      this.event(task, "factory", `couldn't reopen pull request #${pr.number} (${(e as Error).message}); it builds again and opens a new one`);
      task.pr = null;
      return false;
    }
  }

  /**
   * Removes a merged task's worktree (or a cancelled one's, when its goal was archived with "clean up")
   * once none of its sessions are still in it (the runner refuses otherwise, and whenever anything
   * would be lost).
   */
  private async cleanup(task: Task) {
    const priv = this.store.private(task.id);
    const finished = task.state === "merged" || (task.state === "cancelled" && priv.discard);
    if (!finished || !task.machine || !priv.worktree || !priv.repoDir || priv.cleaned) return;
    const machine = (await this.hooks.machines()).find((m) => m.id === task.machine);
    if (machine?.sessions.some((s) => s.session.taskId === task.id)) return; // its last end calls this again
    this.store.savePrivate(task.id, { ...priv, cleaned: true });
    // The factory merged it, and its branch may still be on origin (a delete that failed, or no word
    // of one): one more try, through the GitHub App here or by the runner with the cleanup.
    let deleteRemote = false;
    if (task.state === "merged" && priv.mergeBy && task.pr) {
      const app = githubApp(this.env);
      if (app && priv.gh && task.pr.url) {
        await this.branchDeletes.get(task.id);
        await this.deleteMergedBranch(task.id, app, priv.gh, task.pr);
      } else deleteRemote = priv.remoteBranch !== "deleted" && priv.remoteBranch !== "kept";
    }
    await this.toRunner(task.machine, {
      type: "task.cleanup",
      deleteRemote,
      taskId: task.id,
      cwd: priv.worktree,
      repoDir: priv.repoDir,
      branch: task.pr?.branch ?? `agent/${branchName(task)}`,
      merged: task.state === "merged",
      heads: [task.pr?.head, priv.mergedAs].filter((h): h is string => Boolean(h)),
      repo: taskRepo(task, this.store.goal(task.goal) ?? null),
      scripts: this.store.scriptsFor(taskRepo(task, this.store.goal(task.goal) ?? null)),
    });
  }

  /** A repo's worktree scripts and prompt additions, saved by an admin (from an app, or an admin's
   *  own agent session through the maple MCP, `via`). No prompts (an older app) keeps the stored ones. */
  private async saveRepoSetup(who: string, name: string, raw: WorktreeScripts, rawPrompts: PromptAdditions | null | undefined, via: string | null) {
    const repo = this.store.repos().find((r) => r.name.toLowerCase() === name.trim().toLowerCase())?.name
      ?? fail(`${name} isn't one of the org's repos.`);
    const scripts = cleanScripts(raw);
    const beforePrompts = this.store.repoPrompts(repo);
    let prompts = rawPrompts ? cleanPrompts(rawPrompts) : beforePrompts;
    if (prompts && !prompts.planner && !prompts.builder && !prompts.reviewer) prompts = null;
    const before = this.store.scriptsFor(repo) ?? {};
    const changed: string[] = SCRIPT_FIELDS.filter((f) => (scripts?.[f] ?? null) !== (before[f as keyof WorktreeScripts] ?? null));
    for (const role of ["planner", "builder", "reviewer"] as const) {
      if ((prompts?.[role] ?? "") !== (beforePrompts?.[role] ?? "")) changed.push(`prompts.${role}`);
    }
    this.store.saveRepoScripts(repo, scripts, who, prompts);
    // Which ones changed, not the commands or prompts (they can carry hosts and paths).
    await audit(this.env, who, "repo.scripts", repo, { repo, changed, ...(via ? { via } : {}) });
    this.reposUpdated();
    return repo;
  }

  // ---------------------------------------------------------------------------
  // Agents' tools

  private async tool(sessionId: string, name: string, args: Record<string, unknown>): Promise<Reply> {
    const s = this.store.session(sessionId);
    if (name === "tools/list") return { result: { summary: "", data: { tools: s ? toolsFor(s.role) : [] } } };
    if (!s) return { error: "This session isn't working on a factory task." };
    if (!allowed(s.role, name)) return { error: `${name} isn't one of the ${s.role}'s tools.` };
    const task = this.store.task(s.task);
    if (!task) return { error: "The task isn't there any more." };
    if (task.worker?.session !== sessionId) return { error: "This session isn't the task's current worker any more; stop here." };
    if (name !== "get_task" && this.store.private(task.id).handingOff) return { error: "The task is being handed off to another machine; stop here." };
    try {
      const out = this.run(task, s, name, args);
      this.save(task);
      if (name === "submit_review") await this.autoMerge(task);
      return { result: out };
    } catch (e) {
      return { error: e instanceof Error ? e.message : String(e) };
    }
  }

  private run(task: Task, s: TaskSession, name: string, a: Record<string, unknown>): { summary: string; data?: unknown } {
    const goal = this.store.goal(task.goal);
    switch (name) {
      case "get_task":
        return { summary: `${task.id} · ${task.title} (${task.state})`, data: { task, goal } };

      case "submit_plan": {
        if (task.state !== "planning") fail("The plan isn't open for changes right now.");
        const steps = arr(a.steps).map((x) => obj(x));
        const done = arr(a.doneWhen).map((x) => obj(x));
        if (!steps.length) fail("steps: at least one.");
        if (!done.length) fail("doneWhen: at least one.");
        // Work for the goal's other repos becomes tasks of their own once this plan is approved.
        const goal = this.store.goal(task.goal);
        const repos = goal ? goalRepos(goal) : [];
        const mine = taskRepo(task, goal)?.toLowerCase();
        task.followUps = arr(a.otherRepos).map((x) => {
          const f = obj(x);
          const named = str(f.repo, "otherRepos[].repo");
          const repo = repos.find((r) => r.toLowerCase() === named.toLowerCase()) ?? fail(`otherRepos: ${named} isn't one of this goal's repos (${repos.join(", ")}).`);
          if (repo.toLowerCase() === mine) fail(`otherRepos: ${repo} is this task's own repo; put that work in steps.`);
          return { repo, title: str(f.title, "otherRepos[].title"), brief: str(f.brief, "otherRepos[].brief"), task: null };
        });
        const before = task.plan;
        task.plan = steps.map((st, i) => {
          const prev = before[i];
          const text = str(st.text, "steps[].text");
          return {
            text,
            file: str(st.file, "steps[].file"),
            progress: "pending",
            added: task.planVersion > 0 && !prev,
            from: prev && prev.text !== text ? prev.text : null,
          };
        });
        task.doneWhen = done.map((d) => ({ text: str(d.text, "doneWhen[].text"), proof: proofKind(d.proof), status: "pending", evidence: null }));
        task.planSummary = str(a.summary, "summary");
        // A revised plan replaces (or drops) the earlier suggestion.
        const title = typeof a.title === "string" ? a.title.trim().slice(0, 120).trim() : "";
        task.suggestedTitle = title && title !== task.title ? title : null;
        task.planVersion += 1;
        this.stat(task, "plan.submitted", { version: task.planVersion, steps: task.plan.length }, null, s.role);
        const risk = obj(a.risk);
        const level = ["low", "medium", "high"].includes(risk.level as string) ? (risk.level as "low" | "medium" | "high") : "medium";
        task.risk = { level, reasons: arr(risk.reasons).map(String), areas: arr(risk.areas).map(String) };
        const fp = obj(a.footprint);
        task.footprint = { files: num(fp.files), lines: num(fp.lines), estimated: true };
        const version = task.planVersion;
        task.mockups = arr(a.mockups).map((x, i) => {
          const m = obj(x);
          return {
            id: `M${i + 1}`,
            title: str(m.title, "mockups[].title"),
            kind: m.kind === "terminal" ? "terminal" : "screen",
            url: typeof m.url === "string" ? m.url : null,
            html: typeof m.html === "string" ? m.html : null,
            lines: arr(m.lines).map((l) => {
              const line = obj(l);
              return { text: String(line.text ?? ""), style: String(line.style ?? "output"), callout: line.callout != null ? num(line.callout) : null };
            }),
            notes: arr(m.notes).map(String),
            status: "proposed",
            version,
            visualMatch: null,
            differences: [],
          } satisfies Mockup;
        });
        this.applyPolicy(task);
        task.approvals = [];
        for (const c of task.changes) if (c.status !== "applied") c.status = "applied";
        task.state = "awaitingApproval";
        this.event(task, "planner", task.planVersion > 1 ? `revised the plan (v${task.planVersion})` : "wrote the plan");
        this.closeWorker(task, "done");
        return { summary: `Plan v${task.planVersion} submitted for approval. Your work here is done; end your turn.` };
      }

      case "ask": {
        const question = str(a.question, "question");
        task.question = { text: question, options: arr(a.options).map(String), role: s.role, at: now() };
        this.stat(task, "question.asked", {}, null, s.role);
        this.event(task, s.role, `asked: ${question}`);
        this.intake.forTask(task, `${task.id}'s ${s.role} asks: ${question}`, true);
        this.hooks.broadcast({ type: "toast", text: `${task.id}'s ${s.role} has a question.`, taskId: task.id });
        return { summary: "Asked. End your turn now; the answer will be typed into this session." };
      }

      case "raise_hand": {
        const reason = ["proofBurden", "needsInput", "overBudget"].includes(a.reason as string) ? (a.reason as Hand["reason"]) : "needsInput";
        const options = arr(a.options).map((o) => {
          const x = obj(o);
          return { title: str(x.title, "options[].title"), detail: String(x.detail ?? ""), recommended: x.recommended === true };
        });
        this.lowerHand(task, "factory");
        task.hand = { reason, summary: str(a.summary, "summary"), at: now(), assignee: task.owner, options };
        this.event(task, s.role, "raised a hand");
        this.stat(task, "hand.raised", { reason }, null, s.role);
        this.hooks.broadcast({ type: "toast", text: `${task.id} needs a hand.`, taskId: task.id });
        return { summary: "Hand raised. End your turn now; a person's decision will be typed into this session." };
      }

      case "progress": {
        if (a.step != null) {
          const step = task.plan[num(a.step) - 1] ?? fail(`There's no step ${a.step}; the plan has ${task.plan.length}.`);
          step.progress = a.status === "done" ? "done" : "active";
          if (step.progress === "active") for (const other of task.plan) if (other !== step && other.progress === "active") other.progress = "pending";
        }
        if (typeof a.note === "string" && a.note.trim()) task.liveLog = a.note.trim();
        for (const id of arr(a.applied).map(String)) {
          const c = task.changes.find((x) => x.id === id);
          if (c) {
            c.status = "applied";
            this.event(task, "builder", `applied ${c.author}'s change: ${c.text}`);
          }
        }
        const done = task.plan.filter((p) => p.progress === "done").length;
        return { summary: `Noted. ${done} of ${task.plan.length} steps done.` };
      }

      case "prove": {
        // The runner's own `prove` names the item `criterion`; the factory's names it `item`.
        const which = a.item ?? a.criterion;
        const item = task.doneWhen[num(which) - 1] ?? fail(`There's no item ${which}; Done when has ${task.doneWhen.length}.`);
        // The runner uploaded the file (PUT /runner/proof/<task>) and put `{key, name, type, bytes}` in its place.
        const key = a.file && typeof a.file === "object" ? (a.file as { key?: unknown }).key : null;
        const evidence: Evidence = {
          kind: proofKind(a.kind ?? item.proof),
          summary: str(a.summary, "summary"),
          command: typeof a.command === "string" ? a.command : null,
          output: arr(a.output).map(String).slice(-60),
          passed: a.passed != null ? num(a.passed) : null,
          failed: a.failed != null ? num(a.failed) : null,
          file: isAttachmentKey(key) ? key : null,
          by: "builder",
          at: now(),
        };
        // A person's attestation stands unless the agent's own proof shows it failing.
        if (item.evidence?.attested && item.status === "proven" && !evidence.failed) {
          const left = task.doneWhen.filter((d) => d.status !== "proven").length;
          return { summary: `${item.evidence.by} already attested to it; kept their sign-off. ${left ? `${left} item${left === 1 ? "" : "s"} left to prove.` : "Every item is proven."}` };
        }
        item.evidence = evidence;
        item.status = evidence.failed ? "failed" : "proven";
        this.event(task, "builder", `${item.status === "proven" ? "proved" : "couldn't prove"} "${item.text}"`);
        const left = task.doneWhen.filter((d) => d.status !== "proven").length;
        return { summary: left ? `Attached. ${left} item${left === 1 ? "" : "s"} left to prove.` : "Attached. Every item is proven." };
      }

      case "finish": {
        if (task.state !== "building") fail("It isn't building.");
        const unproven = task.doneWhen.filter((d) => d.status !== "proven");
        if (unproven.length) fail(`Prove these first (or raise a hand): ${unproven.map((d) => `"${d.text}"`).join(", ")}.`);
        const priv = this.store.private(task.id);
        if (!priv.worktree || !priv.repoDir) fail("The factory doesn't know where this worktree came from; raise a hand.");
        this.store.savePrivate(task.id, { ...priv, finishing: true });
        task.liveLog = "Committing and pushing…";
        task.comments.push({ id: crypto.randomUUID(), author: "builder", text: str(a.summary, "summary"), at: now(), anchor: "Summary", via: null });
        this.hooks.waitUntil(this.toRunner(task.machine!, {
          type: "task.finish",
          taskId: task.id,
          cwd: priv.worktree!,
          repoDir: priv.repoDir!,
          branch: task.branch ?? `agent/${branchName(task)}`,
          base: priv.base ?? goal?.base ?? null,
          title: `${task.id}: ${task.title}`,
          fallback: true,
        }));
        return { summary: "Finishing: the factory is committing and pushing, then the review starts. End your turn now." };
      }

      case "submit_review": {
        const review = task.autoReview ?? fail("There's no review open.");
        const round = review.rounds.at(-1) ?? fail("There's no review round open.");
        if (round.verdict !== "inProgress") fail("This round is already in.");
        const check = (x: unknown): ReviewCheck => {
          const c = obj(x);
          const verdict = ["met", "partial", "missed"].includes(c.verdict as string) ? (c.verdict as ReviewCheck["verdict"]) : "partial";
          return { text: str(c.text, "text"), verdict, note: typeof c.note === "string" ? c.note : null };
        };
        review.ask = arr(a.ask).map(check);
        review.proofs = arr(a.proofs).map(check);
        review.summary = str(a.summary, "summary");
        for (const id of arr(a.fixed).map(String)) {
          const f = review.findings.find((x) => x.id === id);
          if (f) {
            f.status = "fixed";
            f.fixedIn = round.number;
          }
        }
        const found: Finding[] = arr(a.findings).map((x, i) => {
          const f = obj(x);
          return {
            id: `R${round.number}.${i + 1}`,
            kind: ["scope", "proof", "code", "risk"].includes(f.kind as string) ? (f.kind as Finding["kind"]) : "code",
            severity: ["blocker", "major", "minor"].includes(f.severity as string) ? (f.severity as Finding["severity"]) : "major",
            text: str(f.text, "findings[].text"),
            file: typeof f.file === "string" ? f.file : null,
            raisedIn: round.number,
            status: "open",
            fixedIn: null,
          };
        });
        review.findings.push(...found);
        const serious = review.findings.some((f) => f.status === "open" && f.severity !== "minor");
        round.verdict = a.verdict === "passed" && !serious ? "passed" : "changesRequested";
        round.found = found.length;
        round.at = now();
        const fixed = arr(a.fixed).length;
        const reviewed = () => this.stat(task, "review.round", { number: round.number, verdict: round.verdict, found: found.length, fixed, findings: found.map(findingDetail) }, null, s.role);
        this.closeWorker(task, "done");
        if (round.verdict === "passed") {
          this.event(task, "reviewer", `passed round ${round.number}`);
          reviewed();
          this.hooks.broadcast({ type: "toast", text: `${task.id} passed review; it's ready for yours.`, taskId: task.id });
          return { summary: "Review in: passed. End your turn now." };
        }
        if (round.number >= review.maxRounds) {
          round.verdict = "escalated";
          reviewed();
          this.raise(task, "reviewer", "reviewLoop", `${round.number} review rounds and it still has open findings.`);
          return { summary: "Review in. The rounds ran out, so a person takes it from here. End your turn now." };
        }
        round.fix = `${found.length} finding${found.length === 1 ? "" : "s"} to fix`;
        reviewed();
        task.state = "building";
        this.event(task, "reviewer", `asked for changes in round ${round.number}`);
        this.hooks.waitUntil(this.pump());
        return { summary: "Review in: changes requested. The builder picks it up. End your turn now." };
      }
    }
    return fail(`Unknown tool ${name}.`);
  }

  // ---------------------------------------------------------------------------
  // Policy and merging

  private assessment(task: Task) {
    return assess(task, this.store.policy(), this.store.acceptances().find((a) => a.goal === task.goal));
  }

  /** The risk level, approvals and reviews the policy gives this task now. */
  private applyPolicy(task: Task) {
    const a = this.assessment(task);
    task.risk = { level: a.level, reasons: task.risk?.reasons ?? [], areas: task.risk?.areas ?? [] };
    task.approvalsNeeded = a.approvals;
    task.reviewsNeeded = a.reviews;
  }

  private async policyChanged() {
    this.hooks.broadcast({ type: "policy.updated", policy: this.store.policy(), acceptances: this.store.acceptances() });
    for (const task of this.store.tasks()) {
      if (task.state === "merged" || task.state === "cancelled" || !task.risk) continue;
      const before = `${task.risk.level}/${task.approvalsNeeded}/${task.reviewsNeeded}`;
      this.applyPolicy(task);
      if (`${task.risk.level}/${task.approvalsNeeded}/${task.reviewsNeeded}` !== before) {
        this.save(task, false);
        if (task.state === "awaitingApproval" && task.approvals.length >= task.approvalsNeeded) {
          await this.approved(task, "queued it for building (the policy needs fewer approvals now)");
          this.save(task);
        }
      }
      // Even with its level unchanged: turning autoMerges back on merges what was waiting.
      await this.autoMerge(task);
    }
    await this.pump();
  }

  /** Ready to merge on its own: reviewed, proven, CI green, nothing in the way. */
  private mergeReady(task: Task) {
    if (task.state !== "reviewing" || !task.pr || task.autoReview?.rounds.at(-1)?.verdict !== "passed") return false;
    if (task.reviews.length < task.reviewsNeeded || task.doneWhen.some((d) => d.status !== "proven")) return false;
    if (task.pr.checks.some((c) => c.status !== "passed")) return false; // CI first
    return !this.store.private(task.id).merging && !task.hand;
  }

  private mergeGraceMs() {
    const ms = Number(this.env.MERGE_GRACE_MS);
    return this.env.MERGE_GRACE_MS && Number.isFinite(ms) && ms >= 0 ? ms : MERGE_GRACE_MS;
  }

  /** Merges on the factory's own say-so when the policy (or the goal's accepted risk) allows it, after
   *  counting down `mergeAt` so a person can hold it. */
  private async autoMerge(task: Task) {
    // A gate that dropped stops a countdown even when nothing else here saves the task.
    const stop = () => { if (task.mergeAt != null) this.save(task); };
    if (!this.mergeReady(task)) return stop();
    const a = this.assessment(task);
    const priv = this.store.private(task.id);
    const head = task.pr!.head ?? task.pr!.branch;
    if (!a.autoMerge) {
      // Ready, but the org merges by hand: say so once per head, so it isn't mistaken for stuck.
      if (this.store.policy().autoMerges === false && priv.pendingMerge !== head) {
        this.store.savePrivate(task.id, { ...priv, pendingMerge: head });
        this.event(task, "factory", "is ready; waiting for a person to merge it (auto-merge is off)");
        this.save(task);
        this.hooks.broadcast({ type: "toast", text: `${task.id} is ready to merge; it's waiting for you.`, taskId: task.id });
      }
      return stop();
    }
    if (priv.mergeHeld === head) return stop(); // a person held this head's auto-merge
    if (task.mergeAt == null) {
      const grace = this.mergeGraceMs();
      task.mergeAt = now() + grace;
      this.store.savePrivate(task.id, { ...priv, mergeHead: head });
      this.event(task, "factory", `will auto-merge in ${+(grace / 1000).toFixed(1)}s`);
      this.save(task);
      this.hooks.wakeIn(grace);
      return;
    }
    if (task.mergeAt > now()) return this.hooks.wakeIn(task.mergeAt - now());
    // A dry-run merge first, once per head: a conflict goes back to its builder without a failed merge.
    if (priv.mergeChecked !== head && task.machine && priv.worktree) {
      const asked = priv.mergeCheck;
      if (asked?.head !== head) {
        if (await this.checkMerge(task, null)) return this.hooks.wakeIn(MERGE_CHECK_WAIT_MS);
      } else if (now() - asked.at < MERGE_CHECK_WAIT_MS) return this.hooks.wakeIn(asked.at + MERGE_CHECK_WAIT_MS - now());
      // Its machine is offline, or never answered: merge anyway; a conflict still shows up there.
    }
    task.mergeAt = null;
    await this.startMerge(task, "factory", a.accepted ? "auto-merged it (the goal accepted this risk)" : `auto-merged it (${a.level} risk)`).catch(() => this.save(task));
  }

  /** Auto-merges whose countdown ran out (one still running wakes the hub again); the hub's alarm calls this. */
  async mergeDue() {
    for (const task of this.store.tasks()) if (task.state === "reviewing" && task.mergeAt != null) await this.autoMerge(task);
  }

  private async startMerge(task: Task, who: string, text = "merged it") {
    const priv = this.store.private(task.id);
    const app = githubApp(this.env);
    // A repo on GitHub merges through its pull request, never around it and its CI.
    if (app && priv.gh && !task.pr?.url) fail("Its pull request isn't open on GitHub; it can't be merged without one.");
    if (app && priv.gh && task.pr?.url) {
      // On GitHub: squash-merge the pull request, pinned to the head that was reviewed.
      this.store.savePrivate(task.id, { ...priv, merging: true, mergeBy: who });
      this.event(task, who, text);
      task.liveLog = "Merging…";
      this.save(task);
      await audit(this.env, who, "task.merged", task.id);
      const pr = task.pr;
      this.hooks.waitUntil(
        mergePullRequest(app, priv.gh.owner, priv.gh.repo, pr.number, { sha: pr.head ?? null, title: `${task.id}: ${task.title}` })
          .then(
            (m) => {
              this.merged({ type: "task.merged", taskId: task.id, ok: true, commit: m.sha, message: null });
              return this.deleteMergedBranch(task.id, app, priv.gh!, pr);
            },
            (e) => this.merged({ type: "task.merged", taskId: task.id, ok: false, commit: null, message: (e as Error).message }),
          ),
      );
      return;
    }
    if (!task.machine || !priv.worktree || !task.pr) fail("Its worktree isn't known; it can't be merged from here.");
    const sent = await this.toRunner(task.machine!, {
      type: "task.merge",
      taskId: task.id,
      cwd: priv.worktree!,
      branch: task.pr!.branch,
      base: task.pr!.base,
      title: `Merge ${task.id}: ${task.title}`,
    });
    if (!sent) fail(`${(await this.hooks.machines()).find((m) => m.id === task.machine)?.name ?? task.machine} is offline; it merges when it's back.`);
    this.store.savePrivate(task.id, { ...priv, merging: true, mergeBy: who });
    this.event(task, who, text);
    task.liveLog = "Merging…";
    this.save(task);
    await audit(this.env, who, "task.merged", task.id);
  }

  /** After the factory merged a pull request: deletes its agent/ branch on GitHub, if it's still the head
   *  that merged. Best-effort: the merge stands whatever happens here. One already under way is joined,
   *  and one that's settled (deleted or kept) isn't tried again. */
  private deleteMergedBranch(taskId: string, app: GitHubApp, gh: { owner: string; repo: string }, pr: NonNullable<Task["pr"]>): Promise<void> {
    const running = this.branchDeletes.get(taskId);
    if (running) return running;
    const settled = this.store.private(taskId).remoteBranch;
    if (settled === "deleted" || settled === "kept") return Promise.resolve();
    const deleting = this.deleteBranchOnGitHub(taskId, app, gh, pr).finally(() => this.branchDeletes.delete(taskId));
    this.branchDeletes.set(taskId, deleting);
    return deleting;
  }

  private async deleteBranchOnGitHub(taskId: string, app: GitHubApp, gh: { owner: string; repo: string }, pr: NonNullable<Task["pr"]>) {
    const branch = pr.branch;
    if (!branch.startsWith("agent/") || branch === pr.base) return;
    let text: string;
    let outcome: "deleted" | "kept" | "failed";
    if (!pr.head) [text, outcome] = [`kept branch ${branch} on GitHub (its merged head isn't known)`, "kept"];
    else {
      try {
        const r = await deleteBranch(app, gh.owner, gh.repo, branch, pr.head);
        [text, outcome] = r === "moved" ? [`kept branch ${branch} on GitHub (it moved after the merge)`, "kept"] : [`deleted branch ${branch} on GitHub`, "deleted"];
      } catch (e) {
        [text, outcome] = [`couldn't delete branch ${branch} on GitHub: ${(e as Error).message}`, "failed"];
      }
    }
    const task = this.store.task(taskId);
    if (!task) return;
    this.store.savePrivate(taskId, { ...this.store.private(taskId), remoteBranch: outcome });
    this.event(task, "factory", text);
    this.save(task, false);
  }

  /** Fails unless something is working on the task that a change request can steer. */
  private steerable(task: Task) {
    if (task.state === "backlog" && !task.plan.length) fail("It isn't planned yet; edit its brief or send it to planning.");
    if (!["planning", "awaitingApproval", "backlog", "building", "reviewing"].includes(task.state)) fail("There's nothing working on it to steer.");
    if (task.state === "reviewing" && this.store.private(task.id).merging) fail("It's merging now.");
  }

  /** A change request from a person: the planner revises an unapproved plan, a reviewing task goes
   *  back to its builder, and a live session has it typed in. */
  private async steer(task: Task, who: string, text: string, anchor: string | null, said: string) {
    this.steerable(task);
    const change: ChangeRequest = { id: `C${task.changes.length + 1}`, author: who, text, at: now(), anchor, status: "queued", timing: null };
    task.changes.push(change);
    this.event(task, who, said);
    this.stat(task, "steer", { state: task.state }, who);
    if (task.state === "awaitingApproval" || task.state === "backlog") {
      // The plan isn't approved yet: the planner revises it (picking it up from the backlog).
      task.approvals = [];
      this.save(task);
      return this.startPlanning(task, who, true);
    }
    if (task.state === "reviewing") {
      // A person's request for changes: the builder takes it, and review starts over on what it pushes.
      await this.backToBuilding(task);
      this.save(task);
      await this.pump();
      return;
    }
    if (task.worker && (await this.type(task, `Change request ${change.id} from ${who}: ${text}\nApply it, then report it with \`progress\` (applied: ["${change.id}"]).`))) {
      change.status = "applying";
    }
    this.save(task);
  }

  /** A person's comment, with the members it @mentions. */
  private async comment(author: string, text: string, opts: { at?: number; anchor?: string | null; via?: string | null } = {}): Promise<Comment> {
    const mentions = mentionsIn(text, await this.hooks.members(), author);
    return { id: crypto.randomUUID(), author, text, at: opts.at ?? now(), anchor: opts.anchor ?? null, via: opts.via ?? null, mentions: mentions.length ? mentions : null };
  }

  /** A person's pick on a "didn't merge" hand. Its task is reviewing with no session, so the
   *  generic resolve (type into the session, or pump) wouldn't move it. */
  private async resolveMergeFailed(task: Task, who: string, option: string | null, note: string) {
    const hand = task.hand!;
    // A note with no pick is guidance for the builder.
    const pick = option ?? (note ? MERGE_FIX : fail("Pick a way forward."));
    if (pick !== "Cancel it" && task.state !== "reviewing") fail("It's not waiting to merge any more.");
    const decision = await this.comment(who, [`Go with: ${pick}`, note || null].filter(Boolean).join("\n"), { anchor: `Hand: ${hand.summary}` });
    const picked = () => {
      this.lowerHand(task, who, pick);
      task.comments.push({ ...decision, at: now() });
    };
    if (pick === MERGE_RETRY) {
      // The hand stays up until the merge has started: if it can't (its machine is offline, say),
      // nothing changed and auto-merge mustn't take over.
      await this.startMerge(task, who, `picked "${pick}"`);
      picked();
      this.save(task);
      return;
    }
    picked();
    this.event(task, who, `picked "${pick}"`);
    if (pick === "Cancel it") {
      await this.cancel(task, who);
      return this.pump();
    }
    const why = hand.summary.replace(/^It didn't merge into [^:]+: /, "").replace(/ \(after \d+ tries\)$/, "");
    this.event(task, who, "sent it back to fix the merge");
    await this.sendBackToFixMerge(task, who, why, note);
  }

  /** A task that didn't merge goes back to a builder with a change request to bring the branch up to
   *  date and resolve the conflicts; review and approvals run again on what it pushes. */
  private async sendBackToFixMerge(task: Task, who: string, why: string, note = "") {
    const base = task.pr?.base ?? this.store.private(task.id).base ?? "main";
    why = why.replace(/\s+/g, " ").trim();
    const change: ChangeRequest = {
      id: `C${task.changes.length + 1}`,
      author: who,
      text: `The branch doesn't merge into ${base} (${why}). Fetch origin/${base}, merge it into the branch, resolve every conflict, keep the tests passing and push.${note ? ` ${note}` : ""}`,
      at: now(),
      anchor: `${MERGE_ANCHOR} ${base}`,
      status: "queued",
      timing: null,
    };
    task.changes.push(change);
    await this.backToBuilding(task);
    this.store.savePrivate(task.id, { ...this.store.private(task.id), restarts: 0 });
    this.save(task);
    await this.pump();
  }

  /** Where a task merges, for its forecast's overlaps. */
  private lane(task: Task): Lane | null {
    const goal = this.store.goal(task.goal);
    const repo = taskRepo(task, goal) ?? goal?.folder ?? null;
    if (!repo) return null;
    return { repo, base: task.pr?.base ?? this.store.private(task.id).base ?? goal?.base ?? "main" };
  }

  /** The other tasks building or in review where this one merges, for its planner's and builder's prompts:
   *  the ones it overlaps first. */
  private moving(task: Task): Moving[] {
    const mine = this.lane(task);
    if (!mine) return [];
    const overlapping = new Set(task.mergeForecast?.overlaps.map((o) => o.task) ?? []);
    return this.store
      .tasks()
      .filter((t) => t.id !== task.id && inFlight(t))
      .filter((t) => { const l = this.lane(t); return l != null && l.repo.toLowerCase() === mine.repo.toLowerCase() && l.base === mine.base; })
      .sort((a, b) => Number(overlapping.has(b.id)) - Number(overlapping.has(a.id)) || b.updatedAt - a.updatedAt)
      .map((t) => ({ id: t.id, title: t.title, state: t.state, files: t.diff?.files ?? [] }));
  }

  /** Brings every task's overlaps up to date after `current` changed (passed as they are now, since
   *  the store's copies may be older), saving the ones that changed. */
  private refreshForecasts(...current: Task[]) {
    const mine = new Map(current.map((t) => [t.id, t]));
    const tasks = this.store.tasks().map((t) => mine.get(t.id) ?? t);
    for (const t of refreshOverlaps(tasks, (t) => this.lane(t))) this.save(t, false);
  }

  /** Asks its machine for a dry-run merge into its base (`task.merge_check`); false when it can't be asked.
   *  `since`: the task whose merge prompted it; none for the check before its own auto-merge. */
  private async checkMerge(task: Task, since: string | null): Promise<boolean> {
    const priv = this.store.private(task.id);
    if (!task.machine || !priv.worktree) return false;
    const base = task.pr?.base ?? priv.base ?? "main";
    const head = task.pr?.head ?? task.pr?.branch ?? null;
    this.store.savePrivate(task.id, { ...priv, mergeCheck: { head, since, at: now() } });
    const sent = await this.toRunner(task.machine, { type: "task.merge_check", taskId: task.id, cwd: priv.worktree, base });
    if (!sent) this.store.savePrivate(task.id, { ...this.store.private(task.id), mergeCheck: null });
    return sent;
  }

  /** A dry-run merge's answer: the forecast records it, and a conflict sends the task back to its
   *  builder now. One prompted by another task's merge doesn't count as a merge-fix try; the check
   *  before its own auto-merge does, as the failed merge it stands in for would. */
  private async mergeChecked(task: Task, msg: Extract<RunnerMessage, { type: "task.merge_check" }>) {
    const priv = this.store.private(task.id);
    const asked = priv.mergeCheck ?? { head: null, since: null, at: now() };
    const head = task.pr?.head ?? task.pr?.branch ?? null;
    const base = task.pr?.base ?? priv.base ?? "main";
    // Before its own merge, the answer lets it go ahead whatever it says (a conflict goes back first).
    this.store.savePrivate(task.id, { ...priv, mergeCheck: null, mergeChecked: asked.since ? priv.mergeChecked : asked.head });
    if (!msg.ok) {
      this.event(task, "factory", `couldn't check whether it still merges into ${base}: ${msg.message ?? "no reason given"}`);
      this.save(task, false);
      if (!asked.since) await this.autoMerge(task);
      return;
    }
    // Pushed again since it was asked: the answer is about a head that's gone.
    if (asked.head !== head || task.state !== "reviewing") return;
    task.mergeForecast = { ...(task.mergeForecast ?? emptyForecast()), conflicts: msg.conflicts, since: msg.clean ? null : asked.since, checkedAt: now(), base };
    if (msg.clean) {
      this.save(task, false);
      if (!asked.since) await this.autoMerge(task);
      return;
    }
    const files = msg.conflicts.length === 1 ? msg.conflicts[0] : `${msg.conflicts.length} files (${msg.conflicts.slice(0, 3).join(", ")}${msg.conflicts.length > 3 ? ", …" : ""})`;
    const why = asked.since ? `${asked.since} merged into ${base} and now it conflicts in ${files}` : `a dry-run merge into ${base} conflicts in ${files}`;
    const autoFix = this.store.policy().autoFixMerges !== false;
    const tries = priv.mergeFixes ?? 0;
    if (!autoFix || this.store.private(task.id).merging || task.hand || (!asked.since && tries >= MERGE_FIX_TRIES)) {
      // A person decides (or its merge, already under way, says): the forecast shows the conflict meanwhile.
      this.event(task, "factory", `${why}`);
      this.save(task);
      if (!asked.since) await this.autoMerge(task);
      return;
    }
    let text = `${why}; sent it back to fix the merge`;
    if (!asked.since) {
      this.store.savePrivate(task.id, { ...this.store.private(task.id), mergeFixes: tries + 1 });
      text = `won't merge: ${text} (try ${tries + 1} of ${MERGE_FIX_TRIES})`;
    }
    this.event(task, "factory", text);
    this.hooks.broadcast({ type: "toast", text: `${task.id} ${asked.since ? `conflicts with ${asked.since}` : "won't merge"}; a builder is fixing it.`, taskId: task.id });
    await this.sendBackToFixMerge(task, "factory", why);
  }

  /** A reviewing task goes back to its builder: review and approvals start over on what it pushes. */
  private async backToBuilding(task: Task) {
    // A "didn't merge" hand is moot once the builder has it; left up, it would keep the pump away.
    if (task.hand?.reason === "mergeFailed") {
      this.lowerHand(task, "factory");
      this.event(task, "factory", "cleared the didn't-merge hand: the builder takes it from here");
    }
    await this.closeWorker(task, "cancelled");
    if (task.autoReview?.rounds.at(-1)?.verdict === "inProgress") task.autoReview.rounds.pop();
    task.reviews = [];
    task.state = "building";
  }

  // ---------------------------------------------------------------------------
  // Helpers

  private raise(task: Task, role: Role | string, reason: Hand["reason"], summary: string, options?: Hand["options"]) {
    this.lowerHand(task, "factory"); // replaced by this one
    task.hand = {
      reason,
      summary,
      at: now(),
      assignee: task.owner,
      options: options ?? [
        { title: "Retry", detail: "Start it again where it left off.", recommended: true },
        { title: "Cancel it", detail: "Stop the task; its branch stays.", recommended: false },
      ],
    };
    this.event(task, String(role), `stopped and needs a hand: ${summary}`);
    this.stat(task, "hand.raised", { reason }, null, String(role));
    this.hooks.broadcast({ type: "toast", text: `${task.id} needs a hand: ${summary}`, taskId: task.id });
  }

  /** Ends the task's current session on purpose: after its last word, or when it's cancelled. */
  /** Asks the task's machine to commit its work so far and push the branch, then move it
   *  (`task.handed_off`). False when there's no worktree to push from. */
  private async handOff(task: Task, who: string): Promise<boolean> {
    const priv = this.store.private(task.id);
    if (!task.machine || !priv.worktree || !priv.repoDir || task.state === "planning") return false;
    const sent = await this.toRunner(task.machine, {
      type: "task.handoff",
      taskId: task.id,
      cwd: priv.worktree,
      repoDir: priv.repoDir,
      branch: `agent/${branchName(task)}`,
      base: priv.base,
      title: task.title,
      fallback: true,
    });
    if (!sent) return false;
    this.store.savePrivate(task.id, { ...priv, handingOff: who });
    task.liveLog = "Pushing its work so far, to hand it off…";
    this.save(task);
    return true;
  }

  private handedOff(machine: string, msg: Extract<RunnerMessage, { type: "task.handed_off" }>) {
    const task = this.store.task(msg.taskId);
    const priv = task && this.store.private(task.id);
    if (!task || !priv?.handingOff) return;
    const who = priv.handingOff;
    this.store.savePrivate(task.id, { ...priv, handingOff: null });
    if (task.state === "cancelled" || task.state === "merged") return;
    const nothing = !msg.ok && /nothing to carry/.test(msg.message ?? "");
    if (!msg.ok && !nothing) {
      task.liveLog = null;
      this.event(task, "factory", `couldn't hand it off (${msg.message ?? "no reason given"}); it stays on ${machine}`);
      this.save(task);
      return;
    }
    this.relocate(task, who, machine, msg.ok ? msg.commit ?? null : null);
    this.hooks.waitUntil(this.pump());
  }

  /** Frees a task from its machine: its next session starts on any free one, from what's pushed. */
  private relocate(task: Task, who: string, from: string, commit: string | null) {
    this.closeWorker(task, "moved");
    const priv = this.store.private(task.id);
    const carried = commit ?? task.pr?.head ?? null;
    this.store.savePrivate(task.id, { ...priv, worktree: null, repoDir: null, restarts: 0, finishing: false, movedFrom: { machine: from, commit: carried } });
    task.machine = null;
    this.lowerHand(task, who);
    task.question = null;
    task.waiting = null;
    task.liveLog = null;
    this.event(task, who, commit
      ? `pushed its work so far (${commit.slice(0, 7)}) and moved it off ${from}`
      : carried
        ? `moved it off ${from}; it carries on from its last push (${carried.slice(0, 7)})`
        : `moved it off ${from}; it starts again from ${task.state === "planning" ? "the brief" : "its plan"}, since nothing was pushed`);
    this.save(task);
  }

  private closeWorker(task: Task, cause: string) {
    const w = task.worker;
    if (!w) return;
    this.store.endSession(w.session, cause);
    task.worker = null;
    if (cause !== "cancelled") task.liveLog = null;
    const kill = async () => {
      if (cause !== "cancelled") await new Promise((r) => setTimeout(r, CLOSE_AFTER_MS));
      await this.toRunner(w.machine, { type: "session.kill", id: w.session }, "factory");
    };
    this.hooks.waitUntil(kill());
  }

  /** A machine that's back can still be running sessions the factory ended while it was away
   *  (its task moved elsewhere); those stop now. */
  reap(machine: Machine) {
    for (const { session } of machine.sessions) {
      if (!session.taskId || this.reaped.has(session.id)) continue;
      const s = this.store.session(session.id);
      const task = s ? this.store.task(s.task) : null;
      // Ended here, or no task's worker: a leftover. Young ones may still be being registered.
      const orphan = s?.ended != null || (Date.now() - Number(session.startedAt) > REAP_AFTER_MS && task?.worker?.session !== session.id);
      if (!orphan) continue;
      this.reaped.add(session.id);
      this.hooks.waitUntil(this.toRunner(machine.id, { type: "session.kill", id: session.id }, "factory"));
    }
  }

  /** Sessions already sent a kill by `reap`, so a slow one isn't killed on every report. */
  private reaped = new Set<string>();
  /** Merged branches being deleted on GitHub, by task, so cleanup waits for (and doesn't repeat) one. */
  private branchDeletes = new Map<string, Promise<void>>();

  /** Types into the task's live session, as if at its keyboard. False when nothing's running. */
  private async type(task: Task, text: string): Promise<boolean> {
    const w = task.worker;
    if (!w) return false;
    const res = await machineHub(this.env, w.machine).fetch("https://hub/input", { method: "POST", body: JSON.stringify({ session: w.session, text }) });
    return res.ok;
  }

  /** Presses keys in the task's live session, nothing added: a permission menu's choice. */
  private async press(task: Task, keys: string): Promise<boolean> {
    const w = task.worker;
    if (!w) return false;
    const res = await machineHub(this.env, w.machine).fetch("https://hub/input", { method: "POST", body: JSON.stringify({ session: w.session, text: keys, keys: true }) });
    return res.ok;
  }

  private async toRunner(machine: string, command: ServerToRunner, by?: string): Promise<boolean> {
    const res = await machineHub(this.env, machine).fetch("https://hub/command", {
      method: "POST",
      body: JSON.stringify(command),
      headers: by ? { "x-by": by } : {},
    });
    return res.ok;
  }

  private reposUpdated() {
    this.hooks.broadcast({ type: "repos.updated", repos: this.store.repos(), scripts: this.store.repoScripts(), repoOwners: this.store.repoOwners() });
  }

  private event(task: Task, who: string, text: string) {
    task.events.push({ who, text, at: now() });
    if (task.events.length > MAX_EVENTS) task.events.splice(0, task.events.length - MAX_EVENTS);
  }

  private stat(task: Task, kind: StatKind, detail: Record<string, unknown> = {}, actor: string | null = null, role: string | null = null) {
    this.store.recordStat({ at: now(), kind, task: task.id, goal: task.goal, role, actor, detail });
  }

  /** Takes a task's hand down (answered, retried, cancelled, or replaced by another), recording how long it was up,
   *  who took it down and the option they picked. */
  private lowerHand(task: Task, who: string, option: string | null = null) {
    const hand = task.hand;
    if (!hand) return;
    task.hand = null;
    this.stat(task, "hand.resolved", { reason: hand.reason, openMs: now() - hand.at, option }, who);
  }

  private save(task: Task, touch = true) {
    if (touch) task.updatedAt = now();
    // An auto-merge counts down only while every gate still holds, on the head it started for.
    if (task.mergeAt != null) {
      const priv = this.store.private(task.id);
      const head = task.pr?.head ?? task.pr?.branch;
      if (!this.mergeReady(task) || !this.assessment(task).autoMerge || priv.mergeHead !== head || priv.mergeHeld === head) task.mergeAt = null;
    }
    this.store.saveTask(task);
    this.hooks.broadcast({ type: "task.updated", task });
  }
}

const SCRIPT_FIELDS = ["create", "setup", "teardown", "archive", "timeoutSecs"] as const;
/** A repo's worktree scripts as stored: commands trimmed, blank ones dropped, none when nothing's left. */
function cleanScripts(s: WorktreeScripts): WorktreeScripts | null {
  const problem = scriptsProblem(s);
  if (problem) fail(problem);
  return tidyScripts(s);
}

/** An effort's name as stored: trimmed and spaces collapsed; blank is none. */
function effortName(name: string | null | undefined): string | null {
  return name?.trim().replace(/\s+/g, " ") || null;
}

/** Whether a model name is one the agent takes: Claude's aliases and claude-* ids, or OpenAI's gpt-*, o-series and codex ones. */
function modelFits(agent: string, model: string): boolean {
  const m = model.toLowerCase();
  if (agent === "claude") return /^(opus|sonnet|haiku|default|opusplan)\b|^claude-/.test(m);
  if (agent === "codex") return /^(gpt-|o\d|codex)/.test(m);
  return true;
}

function sourceTitle(r: { source: string; channel?: string | null }) {
  const name = { slack: "Slack", linear: "Linear", jira: "Jira", api: "the API" }[r.source] ?? r.source;
  return r.channel ? `${name} ${r.channel}` : name;
}

function describeCause(end: SessionEnd) {
  switch (end.cause) {
    case "machineSlept": return "the machine slept";
    case "tmuxLost": return "tmux went away";
    case "runnerUpdated": return "the runner updated";
    case "signaled": return `signal ${end.signal ?? ""}`.trim();
    case "outOfMemory": return "out of memory";
    default: return end.cause;
  }
}

const arr = (v: unknown): unknown[] => (Array.isArray(v) ? v : []);
const obj = (v: unknown): Record<string, unknown> => (v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : {});
const num = (v: unknown): number => {
  const n = Number(v);
  return Number.isFinite(n) && n >= 0 ? Math.floor(n) : 0;
};
const str = (v: unknown, name: string): string => (typeof v === "string" && v.trim() ? v.trim() : fail(`${name} is required.`));
const proofKind = (v: unknown): Evidence["kind"] => (["screenshot", "video", "terminal", "tests"].includes(v as string) ? (v as Evidence["kind"]) : "terminal");

/** The pull request's description: the brief, the plan, and what proves it's done. */
function pullBody(task: Task): string {
  const steps = task.plan.map((s, i) => `${i + 1}. ${s.text}${s.file ? ` (\`${s.file}\`)` : ""}`).join("\n");
  const proofs = task.doneWhen.map((d) => `- [${d.status === "proven" ? "x" : " "}] ${d.text}${d.evidence?.attested ? ` (attested by @${d.evidence.by}${d.evidence.reason ? `: ${d.evidence.reason}` : ""})` : d.evidence ? ` — ${d.evidence.summary}` : ""}`).join("\n");
  return [`Built by Maple Factory for **${task.id}**, owned by @${task.owner}.`, task.brief.trim(), steps && `## Plan\n\n${steps}`, proofs && `## Done when\n\n${proofs}`]
    .filter(Boolean)
    .join("\n\n")
    .slice(0, 60_000);
}

/** A runner's `task.merged` branch note (deleted, gone, moved or `failed: <why>`) as a timeline line,
 *  worded like the GitHub App's, and what it settles. */
export function branchNote(branch: string, note: string): { text: string; outcome: "deleted" | "kept" | "failed" } {
  if (note === "deleted") return { text: `deleted branch ${branch} on origin`, outcome: "deleted" };
  if (note === "gone") return { text: `branch ${branch} was already gone on origin`, outcome: "deleted" };
  if (note === "moved") return { text: `kept branch ${branch} on origin (it moved after the merge)`, outcome: "kept" };
  const why = note.replace(/^failed:\s*/, "") || "no reason given";
  return { text: `couldn't delete branch ${branch} on origin: ${why}`.slice(0, 2000), outcome: "failed" };
}

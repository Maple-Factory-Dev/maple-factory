// One per machine: holds its runner's WebSocket, keeps what the runner last said (sessions,
// health), records how sessions ended, and relays terminals between the runner and viewers.
//
// Runner frames: text = RunnerMessage / ServerToRunner JSON; binary = [16-byte session uuid][bytes].
// Viewer sockets carry one session each: binary = terminal bytes, text = {type:"session.resize"}.
// Shares (`shares:<session>`) let teammates other than the owner and admins in, to watch or to type.

import { DurableObject } from "cloudflare:workers";
import type { Env } from "./env.ts";
import type { Activity, LiveSession, Machine, RunnerMessage, ServerToRunner, SessionEnd, SessionShare } from "./wire.ts";
import { revoked, type MemberRow } from "./auth.ts";
import { offlineMachine, machineRow } from "./machines.ts";
import { orgHub } from "./util.ts";

interface Viewer {
  login: string;
  /** Their role when they opened it; the worker let them in as the machine's owner, an admin, or by a share. */
  role: string;
  /** Let in by a share rather than as the owner or an admin: it closes when the share's taken back. */
  shared: boolean;
  /** False for a share that can only watch: their keystrokes and resizes are dropped. */
  canType: boolean;
  session: string;
  nonce: string;
  /** False until the replay arrives; live output before it is already in the replay. */
  ready: boolean;
}

const RUNNER = "runner";
const VIEWER = "viewer";
/** How long a share holder's revocation check is trusted before publish() asks D1 again. */
const SHARE_CHECK_MS = 45_000;

function uuidBytes(id: string): Uint8Array {
  const hex = id.replace(/-/g, "");
  return Uint8Array.from({ length: 16 }, (_, i) => parseInt(hex.slice(i * 2, i * 2 + 2), 16));
}

function uuidString(bytes: Uint8Array): string {
  const hex = [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

export class MachineHub extends DurableObject<Env> {
  /** Share holders' last revocation check: whether they were gone, and when it was asked. */
  private revokedCache = new Map<string, { gone: boolean; at: number }>();
  /** The clock for the revocation cache; tests move it. */
  now = () => Date.now();

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    // Runners ping every 20s and drop a connection that's quiet for 60s; answer without waking up.
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    switch (url.pathname) {
      case "/runner": return this.acceptRunner(request);
      case "/view": return this.acceptViewer(url);
      case "/command": {
        const command = (await request.json()) as ServerToRunner;
        // Remember who asked for a kill, so the end can say so.
        const by = request.headers.get("x-by");
        if (command.type === "session.kill" && by) await this.ctx.storage.put(`kill:${command.id}`, by);
        const sent = this.toRunner(command);
        return sent ? new Response(null, { status: 204 }) : new Response("That machine is offline.", { status: 409 });
      }
      case "/disconnect": {
        for (const ws of this.ctx.getWebSockets(RUNNER)) ws.close(4001, "token replaced or machine removed");
        if ((await request.text()) === "forget") await this.ctx.storage.deleteAll();
        return new Response(null, { status: 204 });
      }
      case "/drop-viewers": {
        // Someone's access was revoked: their open terminals close now. With role=admin their admin grant was
        // taken back, so only the terminals they opened as an admin close, and none on a machine they own.
        const login = url.searchParams.get("login") ?? "";
        const role = url.searchParams.get("role");
        // The next publish asks D1 about them again rather than trusting a cached "still here".
        this.revokedCache.delete(login);
        if (role && (await this.machine()).owner === login) return new Response(null, { status: 204 });
        for (const ws of this.ctx.getWebSockets(VIEWER)) {
          const viewer = ws.deserializeAttachment() as Viewer;
          if (viewer.login === login && (!role || viewer.role === role)) ws.close(4003, role ? "admin access taken back" : "access revoked");
        }
        return new Response(null, { status: 204 });
      }
      case "/state": return Response.json(await this.machine());
      case "/share": {
        // The org hub checked who may share and with whom; this keeps the list and applies it to open terminals.
        const { session, shares } = (await request.json()) as { session: string; shares: SessionShare[] };
        const machine = await this.machine();
        if (!machine.sessions.some((s) => s.session.id === session)) return new Response("That session has ended.", { status: 404 });
        if (shares.length) await this.ctx.storage.put(`shares:${session}`, shares);
        else await this.ctx.storage.delete(`shares:${session}`);
        for (const ws of this.ctx.getWebSockets(`s:${session}`)) {
          const viewer = ws.deserializeAttachment() as Viewer;
          if (!viewer.shared) continue;
          const share = shares.find((s) => s.login === viewer.login);
          if (!share) ws.close(4003, "no longer shared");
          else if (share.canType !== viewer.canType) ws.serializeAttachment({ ...viewer, canType: share.canType });
        }
        await this.publish(machine);
        return new Response(null, { status: 204 });
      }
      case "/rename": {
        await this.publish({ ...(await this.machine()), name: await request.text() });
        return new Response(null, { status: 204 });
      }
      case "/activity": {
        // The factory's word on a session's activity until the runner's next: Claude sends no hook when
        // its permission prompt is denied, so the denied prompt would otherwise stay up.
        const { session, activity } = (await request.json()) as { session: string; activity: Activity };
        const machine = await this.machine();
        if (!machine.sessions.some((s) => s.session.id === session)) return new Response("No such session.", { status: 404 });
        await this.publish({ ...machine, sessions: machine.sessions.map((s) => (s.session.id === session ? { ...s, activity } : s)) });
        return new Response(null, { status: 204 });
      }
      case "/input": {
        // The factory typing into a session: steering, answers. Text, then Enter on its own, so a
        // TUI that treats a fast paste-plus-return as a newline still submits. With `keys`, the text
        // is sent as typed keys, nothing added: a permission menu's "1" or Esc.
        const { session, text, keys } = (await request.json()) as { session: string; text: string; keys?: boolean };
        const runner = this.runner();
        if (!runner) return new Response("That machine is offline.", { status: 409 });
        const frame = (bytes: Uint8Array) => {
          const out = new Uint8Array(16 + bytes.length);
          out.set(uuidBytes(session));
          out.set(bytes, 16);
          return out;
        };
        if (keys) {
          runner.send(frame(new TextEncoder().encode(text)));
          return new Response(null, { status: 204 });
        }
        runner.send(frame(new TextEncoder().encode(`\x1b[200~${text}\x1b[201~`)));
        await new Promise((r) => setTimeout(r, 400));
        runner.send(frame(new Uint8Array([13])));
        return new Response(null, { status: 204 });
      }
    }
    return new Response("Not found.", { status: 404 });
  }

  private acceptRunner(request: Request): Response {
    const id = request.headers.get("x-machine-id") ?? "";
    // A newer connection wins: the old one is a laptop that woke, or a restarted runner.
    for (const ws of this.ctx.getWebSockets(RUNNER)) ws.close(4000, "replaced by a newer connection");
    const pair = new WebSocketPair();
    this.ctx.acceptWebSocket(pair[1], [RUNNER]);
    pair[1].serializeAttachment({ id });
    this.ctx.waitUntil(this.ctx.storage.put("id", id));
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  private acceptViewer(url: URL): Response {
    const session = url.searchParams.get("session") ?? "";
    const shared = url.searchParams.get("shared") === "1";
    const viewer: Viewer = {
      login: url.searchParams.get("login") ?? "",
      role: url.searchParams.get("role") ?? "member",
      shared,
      canType: !shared || url.searchParams.get("canType") === "1",
      session,
      nonce: crypto.randomUUID(),
      ready: false,
    };
    const pair = new WebSocketPair();
    this.ctx.acceptWebSocket(pair[1], [VIEWER, `s:${session}`]);
    pair[1].serializeAttachment(viewer);
    const cols = Number(url.searchParams.get("cols")) || 0;
    const rows = Number(url.searchParams.get("rows")) || 0;
    if (cols && rows && viewer.canType) this.toRunner({ type: "session.resize", id: session, cols, rows });
    if (!this.toRunner({ type: "session.replay", id: session, nonce: viewer.nonce })) {
      pair[1].send(JSON.stringify({ type: "error", message: "That machine is offline." }));
    }
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  /** The runner's connection: the newest open one, since a replaced one lingers while it closes. */
  private runner(): WebSocket | undefined {
    return this.ctx.getWebSockets(RUNNER).filter((ws) => ws.readyState === WebSocket.OPEN).at(-1);
  }

  private toRunner(message: ServerToRunner): boolean {
    const runner = this.runner();
    if (!runner) return false;
    runner.send(JSON.stringify(message));
    return true;
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer) {
    const isRunner = this.ctx.getTags(ws).includes(RUNNER);
    if (isRunner) {
      if (typeof message === "string") await this.fromRunner(JSON.parse(message) as RunnerMessage);
      else this.output(new Uint8Array(message));
      return;
    }
    const viewer = ws.deserializeAttachment() as Viewer;
    const runner = this.runner();
    // Watching only: nothing they send reaches the session, keystrokes or resizes.
    if (!runner || !viewer.canType) return;
    if (typeof message === "string") {
      const msg = JSON.parse(message) as { type?: string; cols?: number; rows?: number };
      if (msg.type === "session.resize" && msg.cols && msg.rows) this.toRunner({ type: "session.resize", id: viewer.session, cols: msg.cols, rows: msg.rows });
      return;
    }
    const input = new Uint8Array(message);
    const frame = new Uint8Array(16 + input.length);
    frame.set(uuidBytes(viewer.session));
    frame.set(input, 16);
    runner.send(frame);
  }

  /** Terminal output from the runner, to the ready viewers of its session. */
  private output(frame: Uint8Array) {
    if (frame.length < 16) return;
    const session = uuidString(frame.subarray(0, 16));
    const payload = frame.subarray(16);
    for (const ws of this.ctx.getWebSockets(`s:${session}`)) {
      if ((ws.deserializeAttachment() as Viewer).ready) ws.send(payload);
    }
  }

  async webSocketClose(ws: WebSocket) {
    if (!this.ctx.getTags(ws).includes(RUNNER)) return;
    // A replaced connection closes after its successor connected; only the last one going is offline.
    if (this.ctx.getWebSockets(RUNNER).some((other) => other !== ws)) return;
    const machine = await this.machine();
    await this.publish({ ...machine, online: false, lastSeen: Date.now() });
  }

  async webSocketError(ws: WebSocket) {
    await this.webSocketClose(ws);
  }

  private async machine(): Promise<Machine> {
    const stored = await this.ctx.storage.get<Machine>("machine");
    if (stored) return { ...stored, usage: stored.usage ?? [] };
    const id = (await this.ctx.storage.get<string>("id")) ?? "";
    const row = await machineRow(this.env, id);
    return row ? offlineMachine(row) : { id, name: id, owner: "", online: false, sessions: [], usage: [] };
  }

  /** Saves and reports the machine, with each session's shares: those of sessions gone, and those to people
   *  since revoked, are dropped here. Revocations are checked at most every SHARE_CHECK_MS per login
   *  (/drop-viewers already cuts someone off at once), and if D1 fails the shares are kept, so the save and
   *  the report to the org hub still happen. */
  private async publish(machine: Machine) {
    machine = { ...machine, sessions: await this.withShares(machine.sessions) };
    await this.ctx.storage.put("machine", machine);
    await orgHub(this.env).fetch("https://org/machine", { method: "POST", body: JSON.stringify(machine) });
  }

  private async withShares(sessions: LiveSession[]): Promise<LiveSession[]> {
    const stored = await this.ctx.storage.list<SessionShare[]>({ prefix: "shares:" });
    if (!stored.size) return sessions.map(({ shares: _, ...s }) => s);
    const live = new Set(sessions.map((s) => s.session.id));
    const held = [...stored].filter(([key]) => live.has(key.slice("shares:".length))).flatMap(([, shares]) => shares);
    const gone = await this.revokedLogins([...new Set(held.map((s) => s.login))]);
    const kept = new Map<string, SessionShare[]>();
    for (const [key, shares] of stored) {
      const session = key.slice("shares:".length);
      const still = shares.filter((s) => !gone.has(s.login));
      if (!live.has(session) || !still.length) await this.ctx.storage.delete(key);
      else {
        if (still.length !== shares.length) await this.ctx.storage.put(key, still);
        kept.set(session, still);
      }
      if (!live.has(session)) this.closeShared(session, 1000, "session ended");
    }
    return sessions.map(({ shares: _, ...s }) => (kept.has(s.session.id) ? { ...s, shares: kept.get(s.session.id) } : s));
  }

  /** Which of `logins` have been revoked (or have no members row). Asks D1 only about logins not checked in
   *  the last SHARE_CHECK_MS; if D1 fails, those count as still here. */
  private async revokedLogins(logins: string[]): Promise<Set<string>> {
    const now = this.now();
    const stale = logins.filter((login) => { const hit = this.revokedCache.get(login); return !hit || now - hit.at >= SHARE_CHECK_MS; });
    if (stale.length) {
      try {
        const { results } = await this.env.DB.prepare(`SELECT login, revoked_at, last_seen FROM members WHERE login IN (${stale.map(() => "?").join(",")})`)
          .bind(...stale).all<Pick<MemberRow, "login" | "revoked_at" | "last_seen">>();
        for (const login of stale) {
          const row = results.find((r) => r.login === login);
          this.revokedCache.set(login, { gone: !row || revoked(row), at: now });
        }
      } catch (err) {
        console.warn(`machine hub: couldn't check share holders' access, keeping their shares: ${err}`);
      }
    }
    return new Set(logins.filter((login) => this.revokedCache.get(login)?.gone));
  }

  /** Closes the terminals teammates opened on a session by a share. */
  private closeShared(session: string, code: number, reason: string) {
    for (const ws of this.ctx.getWebSockets(`s:${session}`)) {
      if ((ws.deserializeAttachment() as Viewer).shared) ws.close(code, reason);
    }
  }

  private async fromRunner(msg: RunnerMessage) {
    const machine = await this.machine();
    switch (msg.type) {
      case "hello": {
        const row = await machineRow(this.env, msg.runnerId);
        await this.env.DB.prepare("UPDATE machines SET hostname = ?, os = ?, arch = ?, version = ?, last_seen = ? WHERE id = ?")
          .bind(msg.hostname, msg.os, msg.arch, msg.version, Date.now(), msg.runnerId).run();
        for (const end of msg.ended) await this.recordEnd(msg.runnerId, end, machine.sessions);
        await this.publish({
          ...machine,
          id: msg.runnerId,
          name: row?.name ?? msg.runnerId,
          owner: row?.owner ?? machine.owner,
          online: true,
          lastSeen: Date.now(),
          version: msg.version,
          os: msg.os,
          sessions: msg.sessions,
        });
        return;
      }
      case "health":
        await this.publish({ ...machine, online: true, lastSeen: Date.now(), health: msg.health });
        return;
      case "session.opened": {
        const live: LiveSession = { session: msg.session, activity: null };
        await this.publish({ ...machine, sessions: [...machine.sessions.filter((s) => s.session.id !== msg.session.id), live] });
        if (msg.session.taskId) await this.toFactory(machine.id, msg);
        return;
      }
      case "session.activity": {
        await this.publish({
          ...machine,
          sessions: machine.sessions.map((s) => (s.session.id === msg.id ? { ...s, activity: msg.activity } : s)),
        });
        if (machine.sessions.find((s) => s.session.id === msg.id)?.session.taskId) await this.toFactory(machine.id, msg);
        return;
      }
      case "usage": {
        // Readings replace the agent's last one. Only what the apps show: no account emails, even inside
        // a name (a personal Claude org is called "<email>'s Organization").
        const scrub = (name: string | null | undefined) => (name && /\S+@\S+\.\S+/.test(name) ? "Personal" : name ?? null);
        const fresh = msg.agents.map((u) => ({ ...u, account: u.account ? { id: u.account.id ?? null, name: scrub(u.account.name) } : null }));
        const kept = machine.usage
          .filter((u) => !fresh.some((f) => f.agent === u.agent))
          .map((u) => ({ ...u, account: u.account ? { ...u.account, name: scrub(u.account.name) } : null }));
        await this.publish({ ...machine, usage: [...kept, ...fresh] });
        return;
      }
      case "session.cost":
        // Only factory sessions' spend is kept; personal sessions stay on the machine.
        if (machine.sessions.find((s) => s.session.id === msg.cost.session)?.session.taskId) await this.toFactory(machine.id, msg);
        return;
      case "mcp.request": {
        const reply = (await this.toFactory(machine.id, msg)) as { result?: unknown; error?: string } | null;
        this.toRunner({ type: "mcp.response", reqId: msg.reqId, result: reply?.result ?? null, error: reply?.error ?? (reply?.result ? null : "The factory didn't answer.") });
        return;
      }
      case "draft.progress":
      case "draft.done":
      case "task.started":
      case "task.diff":
      case "task.finished":
      case "task.merged":
      case "task.merge_check":
      case "task.cleaned":
      case "task.progress":
      case "task.handed_off":
      case "task.token_request":
      // Answered from the factory (engine.ts releaseSecrets): only this enrolled machine's socket gets here.
      case "secrets.request":
        await this.toFactory(machine.id, msg);
        return;
      case "session.ended":
        // The machine first, so the factory sees the session gone when it hears how it ended.
        await this.publish({ ...machine, sessions: machine.sessions.filter((s) => s.session.id !== msg.end.id) });
        await this.recordEnd(machine.id, msg.end, machine.sessions);
        return;
      case "session.replay": {
        const bytes = Uint8Array.from(atob(msg.data), (c) => c.charCodeAt(0));
        for (const ws of this.ctx.getWebSockets(`s:${msg.id}`)) {
          const viewer = ws.deserializeAttachment() as Viewer;
          if (viewer.nonce !== msg.nonce) continue;
          ws.send(bytes);
          ws.serializeAttachment({ ...viewer, ready: true });
        }
        return;
      }
      case "session.error":
        await this.toFactory(machine.id, msg);
        await orgHub(this.env).fetch("https://org/notice", { method: "POST", body: JSON.stringify({ machine: machine.id, msg }) });
        return;
      case "update.status":
      case "agent.login_status":
        await orgHub(this.env).fetch("https://org/notice", { method: "POST", body: JSON.stringify({ machine: machine.id, msg }) });
        return;
    }
  }

  private async toFactory(machine: string, msg: RunnerMessage): Promise<unknown> {
    const res = await orgHub(this.env).fetch("https://org/runner", { method: "POST", body: JSON.stringify({ machine, msg }) });
    return res.ok ? res.json() : null;
  }

  /** Keeps the end, with its cause, and tells the apps. A `hello` repeats recent ends; the id dedupes. */
  private async recordEnd(machineId: string, raw: SessionEnd, sessions: LiveSession[]) {
    const by = (await this.ctx.storage.get<string>(`kill:${raw.id}`)) ?? null;
    if (by) await this.ctx.storage.delete(`kill:${raw.id}`);
    const end: SessionEnd = { ...raw, by: raw.by ?? by };
    const taskId = sessions.find((s) => s.session.id === end.id)?.session.taskId ?? null;
    const inserted = await this.env.DB.prepare(
      `INSERT INTO session_ends (id, machine, task_id, cause, code, signal, detail, at, last_output, ended_by)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT (id) DO NOTHING RETURNING id`,
    ).bind(end.id, machineId, taskId, end.cause, end.code ?? null, end.signal ?? null, end.detail ?? null, end.at, JSON.stringify(end.lastOutput), end.by ?? null).first();
    if (inserted) await orgHub(this.env).fetch("https://org/ended", { method: "POST", body: JSON.stringify({ machine: machineId, end }) });
  }
}

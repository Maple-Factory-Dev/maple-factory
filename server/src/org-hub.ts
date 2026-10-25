// The org's live feed: every app connection, the latest of every machine, and fan-out of changes.
// Machines report here from their hubs; apps subscribe and send session commands through here.
// The factory (goals, tasks and their agent sessions) lives here too, in this object's SQLite.

import { DurableObject } from "cloudflare:workers";
import type { Env } from "./env.ts";
import { PROTOCOL_VERSION, type ClientMessage, type Presence, type Machine, type Member, type RunnerMessage, type ServerToClient, type ServerToRunner, type SessionEnd, type EndedSession } from "./wire.ts";
import { machineRows, offlineMachine } from "./machines.ts";
import { audit, machineHub } from "./util.ts";
import { toMember, type MemberRow } from "./auth.ts";
import { Store } from "./factory/store.ts";
import { Engine, FactoryError } from "./factory/engine.ts";
import { Intake, type NewRequest } from "./factory/intake.ts";

interface Client {
  member: Member;
  subscribed: boolean;
  /** The task this connection's app is showing. */
  viewing?: string | null;
  since?: number;
}

export class OrgHub extends DurableObject<Env> {
  private store: Store;
  private engine: Engine;
  private intake: Intake;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.store = new Store(ctx.storage.sql);
    this.intake = new Intake(this.store, {
      broadcast: (request) => this.broadcast({ type: "intake.updated", request }),
      waitUntil: (p) => ctx.waitUntil(p),
    });
    this.engine = new Engine(env, this.store, {
      broadcast: (message) => this.broadcast(message),
      machines: () => this.machines(),
      machineChanged: async (id) => {
        const machine = (await this.machines()).find((m) => m.id === id);
        if (machine) this.broadcast({ type: "machine.updated", machine });
      },
      waitUntil: (p) => ctx.waitUntil(p.catch((e) => console.error("factory:", e))),
    }, this.intake);
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    switch (url.pathname) {
      case "/connect": {
        const member = JSON.parse(request.headers.get("x-member") ?? "null") as Member;
        const pair = new WebSocketPair();
        this.ctx.acceptWebSocket(pair[1], ["client"]);
        pair[1].serializeAttachment({ member, subscribed: false } satisfies Client);
        return new Response(null, { status: 101, webSocket: pair[0] });
      }
      case "/machine": {
        const machine = (await request.json()) as Machine;
        const before = await this.ctx.storage.get<Machine>(`m:${machine.id}`);
        await this.ctx.storage.put(`m:${machine.id}`, machine);
        this.broadcast({ type: "machine.updated", machine: this.withSettings(machine) });
        // Coming online, or a session ending, can free a slot for waiting tasks.
        // So can a pause running out, so health reports retry whatever's waiting.
        if (machine.online && !before?.online) this.engine.reap(machine);
        if (machine.online && (!before?.online || before.sessions.length > machine.sessions.length || this.engine.waiting())) await this.engine.pump();
        return new Response(null, { status: 204 });
      }
      case "/ended": {
        const { machine, end } = (await request.json()) as { machine: string; end: SessionEnd };
        this.broadcast({ type: "session.ended", machine, end });
        await this.engine.fromRunner(machine, { type: "session.ended", end });
        return new Response(null, { status: 204 });
      }
      case "/runner": {
        // A runner message about the factory, from its machine's hub; `mcp.request`s get their answer back.
        const { machine, msg } = (await request.json()) as { machine: string; msg: RunnerMessage };
        return Response.json(await this.engine.fromRunner(machine, msg));
      }
      case "/notice": {
        const { machine, msg } = (await request.json()) as { machine: string; msg: { type: string; message?: string | null } };
        if (msg.type === "session.error" && msg.message) this.broadcast({ type: "error", message: `${machine}: ${msg.message}`, requestId: null });
        return new Response(null, { status: 204 });
      }
      case "/removed": {
        const id = await request.text();
        await this.ctx.storage.delete(`m:${id}`);
        this.broadcast({ type: "machine.removed", id });
        return new Response(null, { status: 204 });
      }
      case "/machines": return Response.json(await this.machines());
      case "/intake": {
        // A new request from an integration or the API (the Worker checked who's asking).
        const input = (await request.json()) as NewRequest;
        return Response.json(this.intake.create(input));
      }
      case "/intake/reply": {
        const { id, author, text } = (await request.json()) as { id: string; author: string; text: string };
        const updated = this.intake.reply(id, author, text);
        return updated ? Response.json(updated) : new Response("No such request.", { status: 404 });
      }
      case "/diff": {
        const patch = this.store.get(`patch:${url.searchParams.get("task")}`);
        return patch == null ? new Response("No diff yet.", { status: 404 }) : new Response(patch, { headers: { "content-type": "text/x-diff; charset=utf-8" } });
      }
    }
    return new Response("Not found.", { status: 404 });
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
    return { ...machine, settings, capacity: this.engine.capacity({ ...machine, settings }) };
  }

  private async members(): Promise<Member[]> {
    const { results } = await this.env.DB.prepare("SELECT * FROM members ORDER BY login").all<MemberRow>();
    return results.map(toMember);
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

  /** One entry per person with the app open: the most recent of their connections' views. */
  private online(except?: WebSocket): Presence[] {
    const people = new Map<string, Presence>();
    for (const ws of this.ctx.getWebSockets("client")) {
      if (ws === except) continue;
      const c = ws.deserializeAttachment() as Client;
      if (!c.subscribed) continue;
      const seen = people.get(c.member.login);
      const since = c.since ?? 0;
      if (!seen || (c.viewing && (!seen.viewing || since > seen.since))) people.set(c.member.login, { login: c.member.login, viewing: c.viewing ?? null, since });
    }
    return [...people.values()];
  }

  async webSocketClose(ws: WebSocket) {
    this.broadcast({ type: "presence", online: this.online(ws) });
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
    const client = ws.deserializeAttachment() as Client;
    const msg = JSON.parse(raw) as ClientMessage;
    switch (msg.type) {
      case "presence":
        ws.serializeAttachment({ ...client, viewing: msg.viewing ?? null, since: Date.now() });
        this.broadcast({ type: "presence", online: this.online() });
        return;
      case "subscribe":
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
          tasks: this.store.tasks(),
          policy: this.store.policy(),
          acceptances: this.store.acceptances(),
          online: this.online(),
          notes: this.store.notes(client.member.login),
          intake: this.intake.list(),
          protocolVersion: PROTOCOL_VERSION,
        });
        return;
      case "session.open":
      case "session.kill":
      case "session.resize": {
        const machine = (await this.machines()).find((m) => m.id === msg.machine);
        if (!machine) return this.send(ws, { type: "error", message: `No machine ${msg.machine}.`, requestId: null });
        // Starting and ending sessions is for the machine's owner (and admins) until team slots land.
        if (msg.type !== "session.resize" && machine.owner !== client.member.login && client.member.role !== "admin") {
          return this.send(ws, { type: "error", message: `Only ${machine.owner} can start or end sessions on ${machine.name}.`, requestId: null });
        }
        let command: ServerToRunner;
        if (msg.type === "session.open") {
          command = { type: "session.open", id: crypto.randomUUID(), agent: msg.agent, cwd: msg.cwd, cols: msg.cols, rows: msg.rows, prompt: msg.prompt ?? null, resume: false, taskId: null };
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
      case "note.save": {
        const existing = this.store.note(msg.note.id);
        if (existing && existing.owner !== client.member.login) return this.send(ws, { type: "error", message: "That note isn't yours.", requestId: null });
        if (msg.note.body.length > 200_000) return this.send(ws, { type: "error", message: "That note is too long (200,000 characters at most).", requestId: null });
        const note = { ...msg.note, owner: client.member.login, updatedAt: Date.now() };
        this.store.saveNote(note);
        this.sendTo(client.member.login, { type: "note.updated", note });
        return;
      }
      case "note.delete": {
        const existing = this.store.note(msg.id);
        if (!existing || existing.owner !== client.member.login) return;
        this.store.deleteNote(msg.id);
        this.sendTo(client.member.login, { type: "note.removed", id: msg.id });
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

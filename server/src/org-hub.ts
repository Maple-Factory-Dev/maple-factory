// The org's live feed: every app connection, the latest of every machine, and fan-out of changes.
// Machines report here from their hubs; apps subscribe and send session commands through here.

import { DurableObject } from "cloudflare:workers";
import type { Env } from "./env.ts";
import { PROTOCOL_VERSION, type ClientMessage, type Machine, type Member, type ServerToClient, type ServerToRunner, type SessionEnd, type EndedSession } from "./wire.ts";
import { machineRows, offlineMachine } from "./machines.ts";
import { audit, machineHub } from "./util.ts";

interface Client {
  member: Member;
  subscribed: boolean;
}

export class OrgHub extends DurableObject<Env> {
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
        await this.ctx.storage.put(`m:${machine.id}`, machine);
        this.broadcast({ type: "machine.updated", machine });
        return new Response(null, { status: 204 });
      }
      case "/ended": {
        const { machine, end } = (await request.json()) as { machine: string; end: SessionEnd };
        this.broadcast({ type: "session.ended", machine, end });
        return new Response(null, { status: 204 });
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
      return reported ? { ...reported, name: row.name ?? row.id, owner: row.owner } : offlineMachine(row);
    });
  }

  private async recentEnds(): Promise<EndedSession[]> {
    const since = Date.now() - 7 * 24 * 3600 * 1000;
    const { results } = await this.env.DB.prepare("SELECT * FROM session_ends WHERE at > ? ORDER BY at DESC LIMIT 20").bind(since).all<{
      id: string; machine: string; cause: SessionEnd["cause"]; code: number | null; signal: string | null; detail: string | null; at: number; last_output: string; ended_by: string | null;
    }>();
    return results.map((r) => ({
      machine: r.machine,
      end: { id: r.id, cause: r.cause, code: r.code, signal: r.signal, detail: r.detail, at: r.at, lastOutput: JSON.parse(r.last_output), by: r.ended_by },
    }));
  }

  private send(ws: WebSocket, message: ServerToClient) {
    try {
      ws.send(JSON.stringify(message));
    } catch {
      // The socket closed under us; its close handler tidies up.
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
      case "subscribe":
        ws.serializeAttachment({ ...client, subscribed: true });
        this.send(ws, { type: "snapshot", org: this.env.GITHUB_ORG || "local", me: client.member, machines: await this.machines(), ended: await this.recentEnds(), protocolVersion: PROTOCOL_VERSION });
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
    }
  }
}

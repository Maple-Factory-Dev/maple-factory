// DocHub: one shared planning doc's Yjs document (docs/planning-docs.md). One Durable Object per doc,
// keyed by its id. Every update is appended to SQLite and folded into a snapshot now and then; sockets
// speak the y-websocket framing (y-protocols sync + awareness) and hibernate between messages.

import { DurableObject } from "cloudflare:workers";
import * as Y from "yjs";
import * as encoding from "lib0/encoding";
import * as decoding from "lib0/decoding";
import * as syncProtocol from "y-protocols/sync";
import type { Env } from "./env.ts";
import { readDoc, anchorFor, applySuggestion, DocToolError } from "../docs-editor/src/headless.js";

const MESSAGE_SYNC = 0;
const MESSAGE_AWARENESS = 1;
/** Fold the update rows into the snapshot past this many of them, or this many bytes. */
export const COMPACT_ROWS = 200;
export const COMPACT_BYTES = 1_000_000;
/** And this long after the last edit, from the alarm. */
export const COMPACT_AFTER_MS = 3 * 60_000;
/** Tell OrgHub about edits (its `updatedAt`) at most this often. */
export const TOUCH_EVERY_MS = 30_000;
/** A message bigger than this closes the socket. */
export const MAX_MESSAGE_BYTES = 2_000_000;
/** The doc (snapshot plus pending updates) can't grow past this; an edit that would closes its socket. */
export const MAX_DOC_BYTES = 20_000_000;
/** A socket speaks for at most this many awareness clients (y-websocket uses one), */
export const MAX_AWARE_CLIENTS = 4;
/** and its attachment (as JSON) stays this short, well inside Workers' 2 KB limit even for two-byte strings. */
export const MAX_ATTACHMENT_CHARS = 900;

/** What each socket carries across hibernation: who it is, and the awareness clients it speaks for. */
interface Peer {
  login: string;
  /** Awareness client id → its last clock and JSON state: latecomers hear it, closing says they left. */
  aware: Record<string, [number, string]>;
}

export class DocHub extends DurableObject<Env> {
  private sql: SqlStorage;
  private doc = new Y.Doc();
  /** Bytes the doc takes in SQLite (snapshot plus update rows), against MAX_DOC_BYTES. */
  private bytes = 0;
  /** Whether the compaction alarm is already set (false after a wake, which only costs one extra setAlarm). */
  private alarmSet = false;
  private lastTouch = 0;
  private editedSinceTouch = false;
  now = () => Date.now();

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS updates (seq INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER NOT NULL, by TEXT, data BLOB NOT NULL);
      CREATE TABLE IF NOT EXISTS snapshot (id INTEGER PRIMARY KEY CHECK (id = 1), data BLOB NOT NULL, upto_seq INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    `);
    const snap = this.sql.exec<{ data: ArrayBuffer }>("SELECT data FROM snapshot WHERE id = 1").toArray()[0];
    if (snap) {
      Y.applyUpdate(this.doc, new Uint8Array(snap.data));
      this.bytes = snap.data.byteLength;
    }
    for (const row of this.sql.exec<{ data: ArrayBuffer }>("SELECT data FROM updates ORDER BY seq").toArray()) {
      Y.applyUpdate(this.doc, new Uint8Array(row.data));
      this.bytes += row.data.byteLength;
    }
    // Anything that changes the doc is kept and passed on to the other sockets (`origin` is the sender).
    this.doc.on("update", (update: Uint8Array, origin: unknown) => this.onUpdate(update, origin as WebSocket | null));
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    // From OrgHub: the doc was archived (read-only now), or someone lost access; their sockets close.
    if (url.pathname === "/close" && request.method === "POST") {
      const login = url.searchParams.get("login");
      for (const ws of this.ctx.getWebSockets()) {
        if (login && (ws.deserializeAttachment() as Peer).login !== login) continue;
        this.leave(ws);
        ws.close(4003, login ? "access revoked" : "doc archived");
      }
      return new Response(null, { status: 204 });
    }
    // From OrgHub's agent doc tools (MF-365): read as Markdown, anchor a quote or block, apply an accepted suggestion.
    if (request.method === "POST" && ["/read", "/anchor", "/apply"].includes(url.pathname)) return this.tools(url.pathname, request);
    if (url.pathname !== "/sync") return new Response("Not found.", { status: 404 });
    const login = request.headers.get("x-member-login");
    const docId = request.headers.get("x-doc-id");
    if (!login || !docId) return new Response("Expected a member and a doc.", { status: 400 });
    this.sql.exec("INSERT INTO meta (key, value) VALUES ('id', ?) ON CONFLICT (key) DO NOTHING", docId);
    const pair = new WebSocketPair();
    const ws = pair[1];
    this.ctx.acceptWebSocket(ws, [login]);
    ws.serializeAttachment({ login, aware: {} } satisfies Peer);
    // Step 1 (our state vector) asks the client for what we're missing; its own step 1 gets our step 2.
    const encoder = encoding.createEncoder();
    encoding.writeVarUint(encoder, MESSAGE_SYNC);
    syncProtocol.writeSyncStep1(encoder, this.doc);
    ws.send(encoding.toUint8Array(encoder));
    const here = this.ctx.getWebSockets().filter((o) => o !== ws).flatMap((o) =>
      Object.entries((o.deserializeAttachment() as Peer).aware).map(([id, [clock, state]]) => [Number(id), clock, state] as [number, number, string]));
    if (here.length) ws.send(this.awarenessMessage(here));
    // The socket authed by a `maple-token` subprotocol (auth.ts) has to hear it chosen, or the browser drops it.
    const tokenProtocol = request.headers.get("sec-websocket-protocol")?.split(",")[0].trim() === "maple-token";
    return new Response(null, { status: 101, webSocket: pair[0], headers: tokenProtocol ? { "sec-websocket-protocol": "maple-token" } : {} });
  }

  /** /read {threads} → ReadDoc; /anchor {block?, quote?} → DocAnchor; /apply {anchor, markdown} → {before}. 422: the agent's mistake. */
  private async tools(path: string, request: Request): Promise<Response> {
    const docId = request.headers.get("x-doc-id");
    if (docId) this.sql.exec("INSERT INTO meta (key, value) VALUES ('id', ?) ON CONFLICT (key) DO NOTHING", docId);
    const body = (await request.json()) as Record<string, any>;
    try {
      if (path === "/read") return Response.json(readDoc(this.doc, Array.isArray(body.threads) ? body.threads : []));
      if (path === "/anchor") return Response.json(anchorFor(this.doc, { block: body.block ?? null, quote: body.quote ?? null }));
      if (this.bytes >= MAX_DOC_BYTES) return new Response("This doc is full.", { status: 422 });
      // origin null: onUpdate keeps it, sends it to every open socket as a sync update, and touches OrgHub.
      const { before } = applySuggestion(this.doc, body.anchor, String(body.markdown ?? ""), null);
      return Response.json({ before });
    } catch (e) {
      if (e instanceof DocToolError) return new Response(e.message, { status: 422 });
      throw e;
    }
  }

  async webSocketMessage(ws: WebSocket, raw: string | ArrayBuffer) {
    if (typeof raw === "string") return ws.close(1003, "Binary y-protocols messages only.");
    if (raw.byteLength > MAX_MESSAGE_BYTES) return ws.close(1009, "That update is too big.");
    const data = new Uint8Array(raw);
    try {
      const decoder = decoding.createDecoder(data);
      const type = decoding.readVarUint(decoder);
      if (type === MESSAGE_SYNC) {
        // Updates only ever add bytes, so a message that would push the doc past the cap is refused before it lands.
        if (this.bytes + data.byteLength > MAX_DOC_BYTES) return ws.close(1009, "This doc is full.");
        const encoder = encoding.createEncoder();
        encoding.writeVarUint(encoder, MESSAGE_SYNC);
        // Step 1 writes our step 2 into `encoder`; step 2 and updates apply to the doc with this socket as origin.
        syncProtocol.readSyncMessage(decoder, encoder, this.doc, ws);
        if (encoding.length(encoder) > 1) ws.send(encoding.toUint8Array(encoder));
      } else if (type === MESSAGE_AWARENESS) {
        this.onAwareness(ws, decoding.readVarUint8Array(decoder));
      }
    } catch {
      ws.close(1007, "That isn't a y-protocols message.");
    }
  }

  async webSocketClose(ws: WebSocket) {
    this.leave(ws);
  }

  async webSocketError(ws: WebSocket) {
    this.leave(ws);
  }

  async alarm() {
    this.alarmSet = false;
    this.compact();
    if (this.editedSinceTouch) await this.touch();
  }

  /** Folds every update row into the snapshot. */
  compact() {
    const last = this.sql.exec<{ seq: number | null }>("SELECT MAX(seq) AS seq FROM updates").toArray()[0]?.seq;
    if (last == null) return;
    this.sql.exec(
      "INSERT INTO snapshot (id, data, upto_seq) VALUES (1, ?, ?) ON CONFLICT (id) DO UPDATE SET data = excluded.data, upto_seq = excluded.upto_seq",
      Y.encodeStateAsUpdate(this.doc), last,
    );
    this.sql.exec("DELETE FROM updates WHERE seq <= ?", last);
    this.bytes = this.sql.exec<{ n: number }>("SELECT LENGTH(data) AS n FROM snapshot WHERE id = 1").toArray()[0].n;
  }

  /** For tests and the editor's first paint: the whole doc as one update. */
  state(): Uint8Array {
    return Y.encodeStateAsUpdate(this.doc);
  }

  private onUpdate(update: Uint8Array, origin: WebSocket | null) {
    const by = origin ? (origin.deserializeAttachment() as Peer).login : null;
    this.sql.exec("INSERT INTO updates (at, by, data) VALUES (?, ?, ?)", this.now(), by, update);
    this.bytes += update.byteLength;
    const encoder = encoding.createEncoder();
    encoding.writeVarUint(encoder, MESSAGE_SYNC);
    syncProtocol.writeUpdate(encoder, update);
    const message = encoding.toUint8Array(encoder);
    for (const ws of this.ctx.getWebSockets()) if (ws !== origin) this.send(ws, message);

    const pending = this.sql.exec<{ n: number; bytes: number | null }>("SELECT COUNT(*) AS n, SUM(LENGTH(data)) AS bytes FROM updates").toArray()[0];
    if (pending.n > COMPACT_ROWS || (pending.bytes ?? 0) > COMPACT_BYTES) this.compact();
    if (!this.alarmSet) {
      this.alarmSet = true;
      this.ctx.waitUntil(this.ctx.storage.setAlarm(this.now() + COMPACT_AFTER_MS));
    }
    this.editedSinceTouch = true;
    if (this.now() - this.lastTouch >= TOUCH_EVERY_MS) this.ctx.waitUntil(this.touch());
  }

  /** Bumps the doc's last edit in OrgHub's index, which tells every member's apps. */
  private async touch() {
    const id = this.sql.exec<{ value: string }>("SELECT value FROM meta WHERE key = 'id'").toArray()[0]?.value;
    if (!id) return;
    this.lastTouch = this.now();
    this.editedSinceTouch = false;
    try {
      await this.env.ORG.get(this.env.ORG.idFromName("org")).fetch(`https://org/docs/${id}/touched`, { method: "POST" });
    } catch {
      this.editedSinceTouch = true; // The alarm tries again.
    }
  }

  /**
   * Relays an awareness update to the other sockets. A socket speaks only for the client ids it claimed (the first
   * time it sent them, if no other socket had); states for anyone else's ids, or past the caps, are dropped.
   */
  private onAwareness(ws: WebSocket, update: Uint8Array) {
    const decoder = decoding.createDecoder(update);
    const peer = ws.deserializeAttachment() as Peer;
    const others = this.ctx.getWebSockets().filter((o) => o !== ws);
    const theirs = new Set(others.flatMap((o) => Object.keys((o.deserializeAttachment() as Peer).aware)));
    const passed: [number, number, string][] = [];
    const count = decoding.readVarUint(decoder);
    for (let i = 0; i < count; i++) {
      const id = decoding.readVarUint(decoder);
      const clock = decoding.readVarUint(decoder);
      const state = decoding.readVarString(decoder);
      if (theirs.has(String(id))) continue;
      if (state === "null") {
        if (!(id in peer.aware)) continue;
        delete peer.aware[id];
      } else {
        if (!(id in peer.aware) && Object.keys(peer.aware).length >= MAX_AWARE_CLIENTS) continue;
        const before = peer.aware[id];
        peer.aware[id] = [clock, state];
        if (JSON.stringify(peer).length > MAX_ATTACHMENT_CHARS) {
          if (before) peer.aware[id] = before;
          else delete peer.aware[id];
          continue;
        }
      }
      passed.push([id, clock, state]);
    }
    if (!passed.length) return;
    ws.serializeAttachment(peer);
    const message = this.awarenessMessage(passed);
    for (const other of others) this.send(other, message);
  }

  /** A socket went: its awareness clients are gone, which the others hear as a null state. */
  private leave(ws: WebSocket) {
    const peer = ws.deserializeAttachment() as Peer | null;
    const gone = Object.entries(peer?.aware ?? {}).map(([id, [clock]]) => [Number(id), clock + 1, "null"] as [number, number, string]);
    if (!gone.length) return;
    ws.serializeAttachment({ ...peer!, aware: {} });
    const message = this.awarenessMessage(gone);
    for (const other of this.ctx.getWebSockets()) if (other !== ws) this.send(other, message);
  }

  private awarenessMessage(states: [number, number, string][]): Uint8Array {
    const inner = encoding.createEncoder();
    encoding.writeVarUint(inner, states.length);
    for (const [id, clock, state] of states) {
      encoding.writeVarUint(inner, id);
      encoding.writeVarUint(inner, clock);
      encoding.writeVarString(inner, state);
    }
    const encoder = encoding.createEncoder();
    encoding.writeVarUint(encoder, MESSAGE_AWARENESS);
    encoding.writeVarUint8Array(encoder, encoding.toUint8Array(inner));
    return encoding.toUint8Array(encoder);
  }

  private send(ws: WebSocket, message: Uint8Array) {
    try {
      ws.send(message);
    } catch {
      // Closed under us; its close handler tidies up.
    }
  }
}

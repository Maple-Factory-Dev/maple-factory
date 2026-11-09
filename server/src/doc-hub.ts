// DocHub: one shared planning doc's Yjs document (docs/planning-docs.md). One Durable Object per doc,
// keyed by its id. Every update is appended to SQLite and folded into a snapshot now and then; sockets
// speak the y-websocket framing (y-protocols sync + awareness) and hibernate between messages.

import { DurableObject } from "cloudflare:workers";
import * as Y from "yjs";
import * as encoding from "lib0/encoding";
import * as decoding from "lib0/decoding";
import * as syncProtocol from "y-protocols/sync";
import type { Env } from "./env.ts";

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

/** What each socket carries across hibernation: who it is, and the awareness clients it spoke for. */
interface Peer {
  login: string;
  /** Awareness client id → its last clock, so closing can say they left. */
  aware: Record<string, number>;
}

export class DocHub extends DurableObject<Env> {
  private sql: SqlStorage;
  private doc = new Y.Doc();
  /** Awareness states as last relayed (client id → clock and JSON state), for sockets that join later. */
  private awareness = new Map<number, { clock: number; state: string }>();
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
    if (snap) Y.applyUpdate(this.doc, new Uint8Array(snap.data));
    for (const row of this.sql.exec<{ data: ArrayBuffer }>("SELECT data FROM updates ORDER BY seq").toArray()) Y.applyUpdate(this.doc, new Uint8Array(row.data));
    // Anything that changes the doc is kept and passed on to the other sockets (`origin` is the sender).
    this.doc.on("update", (update: Uint8Array, origin: unknown) => this.onUpdate(update, origin as WebSocket | null));
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
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
    if (this.awareness.size) ws.send(this.awarenessMessage([...this.awareness].map(([id, a]) => [id, a.clock, a.state])));
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  async webSocketMessage(ws: WebSocket, raw: string | ArrayBuffer) {
    if (typeof raw === "string") return ws.close(1003, "Binary y-protocols messages only.");
    if (raw.byteLength > MAX_MESSAGE_BYTES) return ws.close(1009, "That update is too big.");
    const data = new Uint8Array(raw);
    try {
      const decoder = decoding.createDecoder(data);
      const type = decoding.readVarUint(decoder);
      if (type === MESSAGE_SYNC) {
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
  }

  /** For tests and the editor's first paint: the whole doc as one update. */
  state(): Uint8Array {
    return Y.encodeStateAsUpdate(this.doc);
  }

  private onUpdate(update: Uint8Array, origin: WebSocket | null) {
    const by = origin ? (origin.deserializeAttachment() as Peer).login : null;
    this.sql.exec("INSERT INTO updates (at, by, data) VALUES (?, ?, ?)", this.now(), by, update);
    const encoder = encoding.createEncoder();
    encoding.writeVarUint(encoder, MESSAGE_SYNC);
    syncProtocol.writeUpdate(encoder, update);
    const message = encoding.toUint8Array(encoder);
    for (const ws of this.ctx.getWebSockets()) if (ws !== origin) this.send(ws, message);

    const pending = this.sql.exec<{ n: number; bytes: number | null }>("SELECT COUNT(*) AS n, SUM(LENGTH(data)) AS bytes FROM updates").toArray()[0];
    if (pending.n > COMPACT_ROWS || (pending.bytes ?? 0) > COMPACT_BYTES) this.compact();
    this.ctx.waitUntil(this.ctx.storage.setAlarm(this.now() + COMPACT_AFTER_MS));
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

  /** Relays an awareness update to the other sockets, noting which clients this socket speaks for. */
  private onAwareness(ws: WebSocket, update: Uint8Array) {
    const decoder = decoding.createDecoder(update);
    const peer = ws.deserializeAttachment() as Peer;
    const count = decoding.readVarUint(decoder);
    for (let i = 0; i < count; i++) {
      const id = decoding.readVarUint(decoder);
      const clock = decoding.readVarUint(decoder);
      const state = decoding.readVarString(decoder);
      if (state === "null") {
        this.awareness.delete(id);
        delete peer.aware[id];
      } else {
        this.awareness.set(id, { clock, state });
        peer.aware[id] = clock;
      }
    }
    ws.serializeAttachment(peer);
    const encoder = encoding.createEncoder();
    encoding.writeVarUint(encoder, MESSAGE_AWARENESS);
    encoding.writeVarUint8Array(encoder, update);
    const message = encoding.toUint8Array(encoder);
    for (const other of this.ctx.getWebSockets()) if (other !== ws) this.send(other, message);
  }

  /** A socket went: its awareness clients are gone, which the others hear as a null state. */
  private leave(ws: WebSocket) {
    const peer = ws.deserializeAttachment() as Peer | null;
    const gone = Object.entries(peer?.aware ?? {}).map(([id, clock]) => [Number(id), clock + 1, "null"] as [number, number, string]);
    if (!gone.length) return;
    for (const [id] of gone) this.awareness.delete(id);
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

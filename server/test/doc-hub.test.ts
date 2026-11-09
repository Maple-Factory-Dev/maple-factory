// Shared planning docs (docs/planning-docs.md): a real DocHub (`cloudflare:workers` stubbed, node:sqlite storage,
// fake WebSocket pairs) with Y.Doc clients speaking y-protocols; the /docs/<id>/sync route's auth on real
// currentMember over a node:sqlite D1; and OrgHub's doc index (doc.create → snapshot, doc.updated to everyone).
import { test } from "node:test";
import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { DatabaseSync } from "node:sqlite";
import * as Y from "yjs";
import * as encoding from "lib0/encoding";
import * as decoding from "lib0/decoding";
import * as syncProtocol from "y-protocols/sync";
import { d1 } from "./d1.ts";

registerHooks({
  resolve(specifier, context, next) {
    if (specifier === "cloudflare:workers") return { url: "stub:cloudflare-workers", shortCircuit: true };
    return next(specifier, context);
  },
  load(url, context, next) {
    if (url === "stub:cloudflare-workers") {
      return { format: "module", shortCircuit: true, source: "export class DurableObject { constructor(ctx, env) { this.ctx = ctx; this.env = env } }" };
    }
    if (url.endsWith(".json")) return next(url, { ...context, importAttributes: { type: "json" } });
    return next(url, context);
  },
});

// Workers' Response takes 101 with a webSocket; Node's doesn't.
const NodeResponse = globalThis.Response;
class WorkerResponse extends NodeResponse {
  webSocket: unknown;
  constructor(body?: BodyInit | null, init: ResponseInit & { webSocket?: unknown } = {}) {
    const status = init.status ?? 200;
    super(body, { ...init, status: status === 101 ? 200 : status });
    Object.defineProperty(this, "_status", { value: status });
    this.webSocket = init.webSocket;
  }
  get status() { return (this as unknown as { _status?: number })._status ?? super.status; }
  get ok() { return this.status >= 200 && this.status < 300; }
  static json(data: unknown, init?: ResponseInit) { return new WorkerResponse(JSON.stringify(data), { ...init, headers: { "content-type": "application/json" } }); }
}
(globalThis as Record<string, unknown>).Response = WorkerResponse;

/** A socket end: what's sent on it lands in its peer's inbox. */
class FakeSocket {
  peer!: FakeSocket;
  inbox: (string | ArrayBuffer)[] = [];
  closed: number | null = null;
  attachment: unknown = null;
  send(data: string | Uint8Array) {
    if (this.closed !== null) throw new Error("closed");
    this.peer.inbox.push(typeof data === "string" ? data : data.slice().buffer);
  }
  close(code = 1000) { this.closed = code; this.peer.closed = code; }
  serializeAttachment(value: unknown) { this.attachment = structuredClone(value); }
  deserializeAttachment() { return structuredClone(this.attachment); }
}
(globalThis as Record<string, unknown>).WebSocketPair = class {
  0: FakeSocket;
  1: FakeSocket;
  constructor() {
    this[0] = new FakeSocket();
    this[1] = new FakeSocket();
    this[0].peer = this[1];
    this[1].peer = this[0];
  }
};

const { DocHub, COMPACT_ROWS, MAX_DOC_BYTES } = await import("../src/doc-hub.ts");
const { OrgHub } = await import("../src/org-hub.ts");
const { docSync } = await import("../src/doc-routes.ts");
const { currentMember } = await import("../src/auth.ts");
const { sign, sha256 } = await import("../src/util.ts");

function sqlStorage(db = new DatabaseSync(":memory:")) {
  return {
    db,
    exec(query: string, ...bindings: unknown[]) {
      const statements = query.split(";").map((s) => s.trim()).filter(Boolean);
      if (statements.length > 1) {
        db.exec(query);
        return { toArray: () => [], one: () => undefined, [Symbol.iterator]: () => [][Symbol.iterator]() };
      }
      const rows = db.prepare(query).all(...(bindings as never[]));
      return { toArray: () => rows, one: () => rows[0], [Symbol.iterator]: () => rows[Symbol.iterator]() };
    },
  };
}

const DOC_ID = "11111111-2222-4333-8444-555555555555";

/** A DocHub on `db` (shared across instances, as a restart would find it), plus the sockets it accepted. */
function docHub(db = new DatabaseSync(":memory:")) {
  const sockets: FakeSocket[] = [];
  const touched: string[] = [];
  let alarm: number | null = null;
  let alarms = 0;
  const ctx = {
    storage: { sql: sqlStorage(db), setAlarm: async (at: number) => { alarm = at; alarms++; } },
    acceptWebSocket: (ws: FakeSocket) => { sockets.push(ws); },
    getWebSockets: () => sockets.filter((s) => s.closed === null),
    waitUntil: (p: Promise<unknown>) => { p.catch(() => {}); },
  };
  const env = { ORG: { idFromName: (n: string) => n, get: () => ({ fetch: async (url: string) => { touched.push(url); return new Response(null, { status: 204 }); } }) } };
  const hub = new DocHub(ctx as never, env as never);
  return { hub, db, sockets, touched, alarm: () => alarm, alarms: () => alarms, ctx, env };
}

type Hub = ReturnType<typeof docHub>;

/** A Y.Doc editor connected to a DocHub, as y-websocket would: sends step 1, answers the server's step 1. */
class Client {
  doc = new Y.Doc();
  ws!: FakeSocket;
  server!: FakeSocket;
  online = false;
  constructor(public name: string) {
    this.doc.on("update", (update: Uint8Array, origin: unknown) => {
      if (origin === this || !this.online) return;
      const e = encoding.createEncoder();
      encoding.writeVarUint(e, 0);
      syncProtocol.writeUpdate(e, update);
      this.ws.send(encoding.toUint8Array(e));
    });
  }
  get text() { return this.doc.getText("body"); }
  async connect(h: Hub) {
    const res = await h.hub.fetch(new Request("https://doc/sync", { headers: { "x-member-login": this.name, "x-doc-id": DOC_ID } }));
    assert.equal(res.status, 101);
    this.ws = (res as WorkerResponse).webSocket as FakeSocket;
    this.server = this.ws.peer;
    this.online = true;
    const e = encoding.createEncoder();
    encoding.writeVarUint(e, 0);
    syncProtocol.writeSyncStep1(e, this.doc);
    this.ws.send(encoding.toUint8Array(e));
  }
  disconnect(h: Hub) {
    this.online = false;
    this.ws.close();
    return h.hub.webSocketClose(this.server as never);
  }
  /** Takes in what the server sent; returns whether there was anything. */
  receive(): boolean {
    const got = this.ws.inbox.splice(0);
    for (const raw of got) {
      const d = decoding.createDecoder(new Uint8Array(raw as ArrayBuffer));
      if (decoding.readVarUint(d) !== 0) continue;
      const e = encoding.createEncoder();
      encoding.writeVarUint(e, 0);
      syncProtocol.readSyncMessage(d, e, this.doc, this);
      if (encoding.length(e) > 1) this.ws.send(encoding.toUint8Array(e));
    }
    return got.length > 0;
  }
}

/** Delivers every message both ways until everything's quiet. */
async function settle(h: Hub, ...clients: Client[]) {
  for (let busy = true; busy;) {
    busy = false;
    for (const c of clients) {
      if (!c.online) continue;
      for (const raw of c.server.inbox.splice(0)) { busy = true; await h.hub.webSocketMessage(c.server as never, raw); }
      if (c.receive()) busy = true;
    }
  }
}

const sv = (doc: Y.Doc) => Buffer.from(Y.encodeStateVector(doc)).toString("hex");
/** An awareness message for `states` ([client id, clock, JSON state]), as y-protocols/awareness writes it. */
function awarenessMsg(states: [number, number, string][]): ArrayBuffer {
  const inner = encoding.createEncoder();
  encoding.writeVarUint(inner, states.length);
  for (const [id, clock, state] of states) {
    encoding.writeVarUint(inner, id);
    encoding.writeVarUint(inner, clock);
    encoding.writeVarString(inner, state);
  }
  const msg = encoding.createEncoder();
  encoding.writeVarUint(msg, 1);
  encoding.writeVarUint8Array(msg, encoding.toUint8Array(inner));
  return encoding.toUint8Array(msg).buffer as ArrayBuffer;
}
/** The awareness states in a message from the server, or null for a sync message. */
function readAwareness(raw: ArrayBuffer): [number, number, string][] | null {
  const d = decoding.createDecoder(new Uint8Array(raw));
  if (decoding.readVarUint(d) !== 1) return null;
  const u = decoding.createDecoder(decoding.readVarUint8Array(d));
  const n = decoding.readVarUint(u);
  return Array.from({ length: n }, () => [decoding.readVarUint(u), decoding.readVarUint(u), decoding.readVarString(u)]);
}
const awarenessIn = (inbox: (string | ArrayBuffer)[]) => inbox.map((m) => readAwareness(m as ArrayBuffer)).filter(Boolean);

const rows = (db: DatabaseSync, table: string) => (db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get() as { n: number }).n;

test("two clients editing through DocHub converge to the same text and state vector", async () => {
  const h = docHub();
  const ann = new Client("ann");
  const bob = new Client("bob");
  await ann.connect(h);
  await bob.connect(h);
  await settle(h, ann, bob);
  ann.text.insert(0, "Hello");
  await settle(h, ann, bob);
  assert.equal(bob.text.toString(), "Hello");
  // Concurrent edits from both, before either hears the other's.
  ann.text.insert(5, " world");
  bob.text.insert(0, ">> ");
  await settle(h, ann, bob);
  assert.equal(ann.text.toString(), ">> Hello world");
  assert.equal(bob.text.toString(), ann.text.toString());
  assert.equal(sv(ann.doc), sv(bob.doc));
  // The server's own copy agrees, and each update was kept with who made it.
  const server = new Y.Doc();
  Y.applyUpdate(server, h.hub.state());
  assert.equal(server.getText("body").toString(), ">> Hello world");
  const by = h.db.prepare("SELECT DISTINCT by FROM updates ORDER BY by").all().map((r) => (r as { by: string }).by);
  assert.deepEqual(by, ["ann", "bob"]);
  assert.ok(h.alarm(), "an alarm to compact later");
  assert.deepEqual(h.touched, [`https://org/docs/${DOC_ID}/touched`], "OrgHub told once (throttled)");
});

test("after a restart a fresh client gets the whole doc, and an offline client's edits merge both ways", async () => {
  const first = docHub();
  const ann = new Client("ann");
  const bob = new Client("bob");
  await ann.connect(first);
  await bob.connect(first);
  ann.text.insert(0, "Plan: ship docs.");
  await settle(first, ann, bob);
  // Bob goes offline and keeps typing; Ann keeps typing too.
  await bob.disconnect(first);
  bob.text.insert(bob.text.length, " (bob offline)");
  ann.text.insert(0, "# ");
  await settle(first, ann);

  // The Durable Object restarts: a new instance on the same SQLite.
  const second = docHub(first.db);
  const cara = new Client("cara");
  await cara.connect(second);
  await settle(second, cara);
  assert.equal(cara.text.toString(), "# Plan: ship docs.", "replayed via step 1 / step 2");

  await bob.connect(second);
  await settle(second, cara, bob);
  assert.equal(bob.text.toString(), "# Plan: ship docs. (bob offline)");
  assert.equal(cara.text.toString(), bob.text.toString());
  assert.equal(sv(cara.doc), sv(bob.doc));
});

test("awareness is relayed to the others and dropped when its socket closes", async () => {
  const h = docHub();
  const ann = new Client("ann");
  const bob = new Client("bob");
  await ann.connect(h);
  await bob.connect(h);
  await settle(h, ann, bob);
  bob.ws.inbox.length = 0;
  const inner = encoding.createEncoder();
  encoding.writeVarUint(inner, 1);
  encoding.writeVarUint(inner, 42);
  encoding.writeVarUint(inner, 3);
  encoding.writeVarString(inner, JSON.stringify({ user: "ann" }));
  const msg = encoding.createEncoder();
  encoding.writeVarUint(msg, 1);
  encoding.writeVarUint8Array(msg, encoding.toUint8Array(inner));
  await h.hub.webSocketMessage(ann.server as never, encoding.toUint8Array(msg).buffer as ArrayBuffer);
  const awareness = (raw: ArrayBuffer) => {
    const d = decoding.createDecoder(new Uint8Array(raw));
    assert.equal(decoding.readVarUint(d), 1);
    const u = decoding.createDecoder(decoding.readVarUint8Array(d));
    const n = decoding.readVarUint(u);
    return Array.from({ length: n }, () => [decoding.readVarUint(u), decoding.readVarUint(u), decoding.readVarString(u)]);
  };
  assert.deepEqual(awareness(bob.ws.inbox.shift() as ArrayBuffer), [[42, 3, '{"user":"ann"}']]);
  // A latecomer hears who's here.
  const cara = new Client("cara");
  await cara.connect(h);
  assert.deepEqual(awareness(cara.ws.inbox[1] as ArrayBuffer), [[42, 3, '{"user":"ann"}']]);
  await ann.disconnect(h);
  assert.deepEqual(awareness(bob.ws.inbox.shift() as ArrayBuffer), [[42, 4, "null"]]);
});

test("a socket speaks only for the awareness ids it claimed, and cursors survive hibernation", async () => {
  const h = docHub();
  const ann = new Client("ann");
  const bob = new Client("bob");
  await ann.connect(h);
  await bob.connect(h);
  await settle(h, ann, bob);
  ann.ws.inbox.length = 0;
  bob.ws.inbox.length = 0;
  await h.hub.webSocketMessage(ann.server as never, awarenessMsg([[42, 1, '{"user":"ann"}']]));
  assert.deepEqual(awarenessIn(bob.ws.inbox.splice(0)), [[[42, 1, '{"user":"ann"}']]]);
  // Bob can't overwrite or clear ann's cursor; his own id goes through.
  await h.hub.webSocketMessage(bob.server as never, awarenessMsg([[42, 2, '{"user":"mallory"}']]));
  await h.hub.webSocketMessage(bob.server as never, awarenessMsg([[42, 3, "null"]]));
  assert.deepEqual(awarenessIn(ann.ws.inbox.splice(0)), []);
  await h.hub.webSocketMessage(bob.server as never, awarenessMsg([[42, 4, "null"], [7, 1, '{"user":"bob"}']]));
  assert.deepEqual(awarenessIn(ann.ws.inbox.splice(0)), [[[7, 1, '{"user":"bob"}']]]);
  // A state too big for the socket's attachment is dropped.
  await h.hub.webSocketMessage(bob.server as never, awarenessMsg([[8, 1, JSON.stringify({ blob: "x".repeat(2000) })]]));
  assert.deepEqual(awarenessIn(ann.ws.inbox.splice(0)), []);

  // The DO hibernates (a fresh instance on the same sockets and storage); a latecomer still hears both cursors.
  const woke = new DocHub(h.ctx as never, h.env as never);
  const cara = new Client("cara");
  await cara.connect({ ...h, hub: woke });
  assert.deepEqual(awarenessIn(cara.ws.inbox), [[[42, 1, '{"user":"ann"}'], [7, 1, '{"user":"bob"}']]]);
});

test("archiving closes every sync socket; revoking closes only that member's, and the others hear their cursor go", async () => {
  const h = docHub();
  const ann = new Client("ann");
  const bob = new Client("bob");
  await ann.connect(h);
  await bob.connect(h);
  await settle(h, ann, bob);
  await h.hub.webSocketMessage(bob.server as never, awarenessMsg([[7, 1, '{"user":"bob"}']]));
  ann.ws.inbox.length = 0;
  assert.equal((await h.hub.fetch(new Request("https://doc/close?login=bob", { method: "POST" }))).status, 204);
  assert.equal(bob.server.closed, 4003);
  assert.equal(ann.server.closed, null);
  assert.deepEqual(awarenessIn(ann.ws.inbox.splice(0)), [[[7, 2, "null"]]]);
  await h.hub.fetch(new Request("https://doc/close", { method: "POST" }));
  assert.equal(ann.server.closed, 4003);
});

test("the compaction alarm is set once per burst of edits, and an edit past the doc cap is refused", async () => {
  const h = docHub();
  const ann = new Client("ann");
  await ann.connect(h);
  await settle(h, ann);
  for (let i = 0; i < 20; i++) ann.text.insert(0, "x");
  await settle(h, ann);
  assert.equal(h.alarms(), 1);
  await h.hub.alarm();
  ann.text.insert(0, "y");
  await settle(h, ann);
  assert.equal(h.alarms(), 2);

  (h.hub as unknown as { bytes: number }).bytes = MAX_DOC_BYTES - 5;
  const before = rows(h.db, "updates");
  ann.text.insert(0, "this edit doesn't fit");
  await settle(h, ann);
  assert.equal(ann.server.closed, 1009);
  assert.equal(rows(h.db, "updates"), before);
});

test("compaction folds the updates into one snapshot; a reload reproduces the doc and takes later updates", async () => {
  const h = docHub();
  const ann = new Client("ann");
  await ann.connect(h);
  for (let i = 0; i < 20; i++) ann.text.insert(ann.text.length, `line ${i}\n`);
  await settle(h, ann);
  assert.equal(rows(h.db, "updates"), 20);
  h.hub.compact();
  assert.equal(rows(h.db, "snapshot"), 1);
  assert.equal(rows(h.db, "updates"), 0);

  const reloaded = docHub(h.db);
  const fresh = new Client("bob");
  await fresh.connect(reloaded);
  await settle(reloaded, fresh);
  assert.equal(fresh.text.toString(), ann.text.toString());
  assert.equal(sv(fresh.doc), sv(ann.doc));
  fresh.text.insert(0, "after\n");
  await settle(reloaded, fresh);
  assert.equal(rows(h.db, "updates"), 1);
  const third = docHub(h.db);
  const check = new Y.Doc();
  Y.applyUpdate(check, third.hub.state());
  assert.equal(check.getText("body").toString(), fresh.text.toString());

  // Past COMPACT_ROWS it compacts by itself.
  for (let i = 0; i <= COMPACT_ROWS; i++) fresh.text.insert(0, "x");
  await settle(reloaded, fresh);
  assert.ok(rows(h.db, "updates") < COMPACT_ROWS);
  assert.equal(rows(h.db, "snapshot"), 1);
});

test("a message that isn't y-protocols, or text, closes the socket", async () => {
  const h = docHub();
  const ann = new Client("ann");
  await ann.connect(h);
  await h.hub.webSocketMessage(ann.server as never, "hello");
  assert.equal(ann.server.closed, 1003);
});

// ---- the route --------------------------------------------------------------

async function routeEnv() {
  const db = d1();
  const now = Date.now();
  for (const [login, revokedAt] of [["ann", null], ["rex", now + 1000]] as const) {
    db.sql.prepare("INSERT INTO members (login, github_id, role, created_at, checked_at, revoked_at) VALUES (?, 1, 'member', ?, ?, ?)").run(login, now, now, revokedAt);
  }
  const forwarded: Request[] = [];
  const docs: Record<string, { archived?: boolean }> = { [DOC_ID]: {} };
  const env = {
    DB: db,
    SESSION_SECRET: "test-secret",
    GITHUB_ORG: "acme",
    ORG: { idFromName: (n: string) => n, get: () => ({ fetch: async (url: string) => {
      const id = /\/docs\/([^/]+)$/.exec(url)?.[1] ?? "";
      return docs[id] ? Response.json({ id, title: "T", createdBy: "ann", createdAt: 1, updatedAt: 1, ...docs[id] }) : new Response("No such doc.", { status: 404 });
    } }) },
    DOC: { idFromName: (n: string) => n, get: () => ({ fetch: async (req: Request) => { forwarded.push(req); return new Response(null, { status: 101, webSocket: {} } as never); } }) },
  };
  const cookie = async (login: string) => `__Host-maple_session=${await sign({ login, iat: now, exp: Math.floor(now / 1000) + 3600 }, env.SESSION_SECRET)}`;
  const call = async (id: string, headers: Record<string, string>) => {
    const req = new Request(`https://factory.example/docs/${id}/sync`, { headers: { upgrade: "websocket", ...headers } });
    return docSync(req, env as never, id, await currentMember(req, env as never));
  };
  return { env, docs, forwarded, cookie, call, db };
}

test("/docs/<id>/sync: members get a 101; no member, a revoked one, a bad origin or an unknown doc are refused", async () => {
  const r = await routeEnv();
  const ok = await r.call(DOC_ID, { cookie: await r.cookie("ann") });
  assert.equal(ok.status, 101);
  assert.equal(r.forwarded[0].headers.get("x-member-login"), "ann");
  assert.equal(r.forwarded[0].headers.get("x-doc-id"), DOC_ID);

  assert.equal((await r.call(DOC_ID, {})).status, 401, "not signed in");
  assert.equal((await r.call(DOC_ID, { cookie: await r.cookie("rex") })).status, 401, "revoked after the session was issued");
  assert.equal((await r.call(DOC_ID, { cookie: await r.cookie("nobody") })).status, 401, "not a member");
  assert.equal((await r.call(DOC_ID, { cookie: await r.cookie("ann"), origin: "https://evil.example" })).status, 403, "cross-origin");
  assert.equal((await r.call("99999999-2222-4333-8444-555555555555", { cookie: await r.cookie("ann") })).status, 404, "unknown doc");
  r.docs[DOC_ID].archived = true;
  assert.equal((await r.call(DOC_ID, { cookie: await r.cookie("ann") })).status, 403, "archived is read-only");
  // An app token works the same way.
  r.docs[DOC_ID].archived = false;
  r.db.sql.prepare("INSERT INTO app_tokens (token_hash, login, created_at, expires_at) VALUES (?, 'ann', ?, ?)").run(await sha256("mft_abc"), Date.now(), Date.now() + 60_000);
  assert.equal((await r.call(DOC_ID, { authorization: "Bearer mft_abc" })).status, 101);
  assert.equal(r.forwarded.length, 2, "only members reach the DocHub");
});

test("/docs/<id>/sync: an app token as the maple-token subprotocol authes the socket; revoked, expired or bad tokens get 401", async () => {
  const r = await routeEnv();
  const now = Date.now();
  const token = async (t: string, login: string, expires: number) =>
    r.db.sql.prepare("INSERT INTO app_tokens (token_hash, login, created_at, expires_at) VALUES (?, ?, ?, ?)").run(await sha256(t), login, now, expires);
  await token("mft_good", "ann", now + 60_000);
  await token("mft_old", "ann", now - 1);
  await token("mft_rex", "rex", now + 60_000);
  const proto = (t: string) => ({ "sec-websocket-protocol": `maple-token, ${t}` });

  const ok = await r.call(DOC_ID, proto("mft_good"));
  assert.equal(ok.status, 101);
  assert.equal(r.forwarded[0].headers.get("x-member-login"), "ann");
  assert.equal(r.forwarded[0].headers.get("sec-websocket-protocol"), "maple-token, mft_good", "DocHub sees it and echoes maple-token");

  assert.equal((await r.call(DOC_ID, proto("mft_old"))).status, 401, "expired token");
  const { revokeMember } = await import("../src/auth.ts");
  await revokeMember(r.env as never, "rex", "test", false);
  assert.equal((await r.call(DOC_ID, proto("mft_rex"))).status, 401, "revoked member's token");
  assert.equal((await r.call(DOC_ID, proto("mft_nope"))).status, 401, "unknown token");
  assert.equal((await r.call(DOC_ID, { "sec-websocket-protocol": "mft_good" })).status, 401, "needs the maple-token marker");
  assert.equal((await r.call(DOC_ID, { ...proto("mft_good"), origin: "https://evil.example" })).status, 403, "same-origin still applies");
  // Only on a sync socket upgrade: the same header on a plain request, or elsewhere, isn't a sign-in.
  const { currentMember } = await import("../src/auth.ts");
  const plain = new Request(`https://factory.example/docs/${DOC_ID}/sync`, { headers: proto("mft_good") });
  assert.equal(await currentMember(plain, r.env as never), null);
  const elsewhere = new Request("https://factory.example/client/connect", { headers: { upgrade: "websocket", ...proto("mft_good") } });
  assert.equal(await currentMember(elsewhere, r.env as never), null);
  assert.equal(r.forwarded.length, 1);
});

// ---- OrgHub's doc index ------------------------------------------------------

function orgHub() {
  const sockets: FakeSocket[] = [];
  const ctx = {
    storage: { sql: sqlStorage(), list: async () => new Map(), get: async () => undefined, put: async () => {}, getAlarm: async () => null, setAlarm: async () => {} },
    blockConcurrencyWhile: (fn: () => Promise<void>) => fn(),
    waitUntil: () => {},
    getWebSockets: () => sockets,
  };
  const docCalls: string[] = [];
  const env = {
    DB: { prepare: () => ({ all: async () => ({ results: [] }), bind: () => ({ all: async () => ({ results: [] }), first: async () => null }) }) },
    DOC: { idFromName: (n: string) => n, get: (id: string) => ({ fetch: async (url: string) => { docCalls.push(`${id} ${url}`); return new Response(null, { status: 204 }); } }) },
  };
  const org = new OrgHub(ctx as never, env as never);
  const client = (login: string) => {
    const ws = new FakeSocket();
    ws.peer = new FakeSocket();
    ws.serializeAttachment({ member: { login, name: login, role: "member", teams: [] }, subscribed: true });
    sockets.push(ws);
    const said = () => ws.peer.inbox.splice(0).map((m) => JSON.parse(m as string));
    const say = (msg: object) => org.webSocketMessage(ws as never, JSON.stringify(msg));
    return { ws, said, say };
  };
  const store = (org as unknown as { store: { docs(): { id: string; title: string; archived?: boolean | null }[]; saveGoal?: unknown } }).store;
  return { org, client, store, docCalls };
}

test("OrgHub: doc.create is in the index the snapshot sends and doc.updated reaches every member; rename, archive and touched follow", async () => {
  const { org, client, store, docCalls } = orgHub();
  const ann = client("ann");
  const bob = client("bob");
  await ann.say({ type: "doc.create", title: "  Research: CRDTs  " });
  const [created] = bob.said();
  assert.equal(created.type, "doc.updated");
  assert.equal(created.doc.title, "Research: CRDTs");
  assert.equal(created.doc.createdBy, "ann");
  assert.equal(ann.said()[0].doc.id, created.doc.id);
  assert.deepEqual(store.docs().map((d) => d.id), [created.doc.id]);
  const id = created.doc.id as string;
  // A member who connects now finds it in the feed snapshot.
  const cara = client("cara");
  await cara.say({ type: "subscribe" });
  const snapshot = cara.said().find((m) => m.type === "snapshot");
  assert.deepEqual(snapshot.docs.map((d: { id: string; title: string }) => [d.id, d.title]), [[id, "Research: CRDTs"]]);
  ann.said();
  bob.said();

  await bob.say({ type: "doc.rename", id, title: "CRDT research" });
  assert.equal(ann.said()[0].doc.title, "CRDT research");
  await bob.say({ type: "doc.create", title: "x", goal: "no-such-goal" });
  assert.equal(bob.said().at(-1).type, "error");
  await bob.say({ type: "doc.create", title: "" });
  assert.equal(bob.said().at(-1).type, "error");

  // The Worker's lookup, and DocHub's touch.
  const found = await org.fetch(new Request(`https://org/docs/${id}`));
  assert.equal(found.status, 200);
  assert.equal(((await found.json()) as { title: string }).title, "CRDT research");
  assert.equal((await org.fetch(new Request("https://org/docs/99999999-2222-4333-8444-555555555555"))).status, 404);
  ann.said();
  assert.equal((await org.fetch(new Request(`https://org/docs/${id}/touched`, { method: "POST" }))).status, 204);
  assert.equal(ann.said()[0].type, "doc.updated");

  // Revoking someone closes their sockets on every live doc.
  await (org as unknown as { cutOff(login: string): Promise<void> }).cutOff("bob");
  assert.deepEqual(docCalls.splice(0), [`${id} https://doc/close?login=bob`]);

  await ann.say({ type: "doc.archive", id, archived: true });
  assert.equal(ann.said().filter((m) => m.type === "doc.updated").at(-1).doc.archived, true);
  assert.equal(store.docs()[0].archived, true);
  // Archiving closes everyone's sockets on it.
  await new Promise((r) => setTimeout(r, 0));
  assert.deepEqual(docCalls, [`${id} https://doc/close`]);
});

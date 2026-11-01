// MachineHub's publish when checking share holders against D1 is slow to change or fails: a real hub with
// `cloudflare:workers` stubbed, Map-backed storage, a fake org hub and a D1 that counts calls or throws.
import { test } from "node:test";
import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import type { Machine, SessionShare } from "../src/wire.ts";

registerHooks({
  resolve(specifier, context, next) {
    if (specifier === "cloudflare:workers") return { url: "stub:cloudflare-workers", shortCircuit: true };
    return next(specifier, context);
  },
  load(url, context, next) {
    if (url === "stub:cloudflare-workers") {
      return { format: "module", shortCircuit: true, source: "export class DurableObject { constructor(ctx, env) { this.ctx = ctx; this.env = env } }" };
    }
    return next(url, context);
  },
});
(globalThis as Record<string, unknown>).WebSocketRequestResponsePair = class { constructor(public request: string, public response: string) {} };
const { MachineHub } = await import("../src/machine-hub.ts");

function storage() {
  const data = new Map<string, unknown>();
  return {
    data,
    async get(key: string) { return structuredClone(data.get(key)); },
    async put(key: string, value: unknown) { data.set(key, structuredClone(value)); },
    async delete(key: string) { return data.delete(key); },
    async list({ prefix }: { prefix: string }) {
      return new Map([...data].filter(([key]) => key.startsWith(prefix)).sort(([a], [b]) => a.localeCompare(b)).map(([k, v]) => [k, structuredClone(v)]));
    },
  };
}

function hub(opts: { fail?: boolean; revoked?: string[] } = {}) {
  const store = storage();
  const posted: Machine[] = [];
  const sent: { url: string; body: unknown }[] = [];
  const db = { queries: 0, fail: opts.fail ?? false };
  const env = {
    DB: {
      prepare: () => ({
        bind: (...logins: string[]) => ({
          async all() {
            db.queries++;
            if (db.fail) throw new Error("D1_ERROR: network connection lost");
            return { results: logins.map((login) => ({ login, revoked_at: opts.revoked?.includes(login) ? 1 : null, last_seen: 0 })) };
          },
        }),
      }),
    },
    ORG: {
      idFromName: (name: string) => name,
      get: () => ({ async fetch(url: string, init: RequestInit) { sent.push({ url, body: JSON.parse(init.body as string) }); if (url.endsWith("/machine")) posted.push(JSON.parse(init.body as string)); return new Response(null, { status: 204 }); } }),
    },
  };
  const ctx = { storage: store, getWebSockets: () => [], setWebSocketAutoResponse() {} };
  const instance = new MachineHub(ctx as never, env as never);
  let clock = 1_000_000;
  instance.now = () => clock;
  return { instance, store, posted, sent, db, tick: (ms: number) => { clock += ms; } };
}

function machine(...sessions: string[]): Machine {
  return {
    id: "m1", name: "Mac", owner: "owner", online: true, usage: [],
    sessions: sessions.map((id) => ({ session: { id }, activity: { state: "idle" } })),
  } as unknown as Machine;
}

const ann: SessionShare[] = [{ login: "ann", canType: false }] as SessionShare[];
const bob: SessionShare[] = [{ login: "bob", canType: true }] as SessionShare[];

async function rename(instance: InstanceType<typeof MachineHub>, name: string) {
  const res = await instance.fetch(new Request("https://hub/rename", { method: "POST", body: name }));
  assert.equal(res.status, 204);
}

test("publish still saves and reports the machine, shares kept, when D1 throws", async () => {
  const { instance, store, posted, db } = hub({ fail: true });
  await store.put("machine", machine("live"));
  await store.put("shares:live", ann);
  await rename(instance, "Renamed");
  assert.equal(db.queries, 1);
  const saved = store.data.get("machine") as Machine;
  assert.equal(saved.name, "Renamed");
  assert.deepEqual(saved.sessions[0].shares, ann);
  assert.equal(posted.length, 1);
  assert.equal(posted[0].name, "Renamed");
  assert.deepEqual(posted[0].sessions[0].shares, ann);
  assert.deepEqual(store.data.get("shares:live"), ann);
});

test("publishes within the window ask D1 once; after it, again", async () => {
  const { instance, posted, db, store, tick } = hub();
  await store.put("machine", machine("live"));
  await store.put("shares:live", [...ann, ...bob]);
  await rename(instance, "a");
  tick(10_000);
  await rename(instance, "b");
  tick(30_000);
  await rename(instance, "c");
  assert.equal(db.queries, 1);
  assert.equal(posted.length, 3);
  tick(10_000);
  await rename(instance, "d");
  assert.equal(db.queries, 2);
});

test("a revoked holder's share is dropped, and /drop-viewers makes the next publish ask again", async () => {
  const revoked: string[] = [];
  const { instance, store, posted, db } = hub({ revoked });
  await store.put("machine", machine("live"));
  await store.put("shares:live", [...ann, ...bob]);
  await rename(instance, "a");
  assert.equal(posted[0].sessions[0].shares?.length, 2);
  revoked.push("bob");
  await instance.fetch(new Request("https://hub/drop-viewers?login=bob", { method: "POST" }));
  await rename(instance, "b");
  assert.equal(db.queries, 2);
  assert.deepEqual(posted[1].sessions[0].shares, ann);
  assert.deepEqual(store.data.get("shares:live"), ann);
});

test("while D1 throws, an ended session's shares are still dropped and a live one's kept", async () => {
  const { instance, store, posted } = hub({ fail: true });
  await store.put("machine", machine("live"));
  await store.put("shares:live", ann);
  await store.put("shares:ended", bob);
  await rename(instance, "x");
  assert.equal(store.data.has("shares:ended"), false);
  assert.deepEqual(store.data.get("shares:live"), ann);
  assert.deepEqual(posted[0].sessions.map((s) => s.session.id), ["live"]);
  assert.deepEqual(posted[0].sessions[0].shares, ann);
  assert.equal(JSON.stringify(posted[0]).includes("bob"), false);
});

test("only ended sessions' shares: no D1 query at all", async () => {
  const { instance, store, db } = hub({ fail: true });
  await store.put("machine", machine("live"));
  await store.put("shares:ended", bob);
  await rename(instance, "x");
  assert.equal(db.queries, 0);
  assert.equal(store.data.has("shares:ended"), false);
});

/** A hub whose D1 takes the hello's statements and dedupes session_ends by id, and whose org hub keeps every post. */
function helloHub() {
  const store = storage();
  const posts: { url: string; body: any }[] = [];
  const ends = new Set<string>();
  const env = {
    DB: {
      prepare: (sql: string) => ({
        bind: (...args: unknown[]) => ({
          async run() { return {}; },
          async all() { return { results: [] }; },
          async first() {
            if (!sql.includes("INSERT INTO session_ends")) return null;
            const id = args[0] as string;
            if (ends.has(id)) return null;
            ends.add(id);
            return { id };
          },
        }),
      }),
    },
    ORG: {
      idFromName: (name: string) => name,
      get: () => ({ async fetch(url: string, init: RequestInit) { posts.push({ url, body: JSON.parse(init.body as string) }); return new Response(null, { status: 204 }); } }),
    },
  };
  const ctx = { storage: store, getWebSockets: () => [], setWebSocketAutoResponse() {}, getTags: () => ["runner"] };
  const instance = new MachineHub(ctx as never, env as never);
  instance.now = () => 5_000_000;
  const send = (msg: unknown) => instance.webSocketMessage({} as never, JSON.stringify(msg));
  return { instance, store, posts, send };
}

function hello(sessions: string[], ended: { id: string; cause: string }[] = []) {
  return {
    type: "hello", runnerId: "m1", hostname: "studio", os: "darwin", arch: "arm64", version: "1.0.0",
    sessions: sessions.map((id) => ({ session: { id, taskId: `t-${id}` }, activity: null })),
    ended: ended.map((e) => ({ ...e, at: 1, lastOutput: [] })),
  };
}

test("a session missing from a reconnect hello gets one tmuxLost end sent to the factory", async () => {
  const { store, posts, send } = helloHub();
  const m = machine("s1", "s2");
  m.sessions.forEach((s) => ((s.session as { taskId?: string }).taskId = `t-${s.session.id}`));
  await store.put("machine", m);
  await send(hello(["s2"]));
  const ended = posts.filter((p) => p.url === "https://org/ended");
  assert.equal(ended.length, 1);
  assert.equal(ended[0].body.machine, "m1");
  assert.equal(ended[0].body.end.id, "s1");
  assert.equal(ended[0].body.end.cause, "tmuxLost");
  assert.match(ended[0].body.end.detail, /gone when studio reconnected/);
  assert.equal(ended[0].body.end.at, 5_000_000);
  // The end goes before the machine's report, and the report lists only what the runner has.
  const report = posts.findIndex((p) => p.url === "https://org/machine");
  assert.ok(report > posts.indexOf(ended[0]));
  assert.deepEqual(posts[report].body.sessions.map((s: any) => s.session.id), ["s2"]);

  // Reconnecting again (s1 is no longer stored) or the runner repeating s1's end: no second one.
  await store.put("machine", m);
  await send(hello(["s2"], [{ id: "s1", cause: "tmuxLost" }]));
  await send(hello(["s2"]));
  assert.equal(posts.filter((p) => p.url === "https://org/ended").length, 1);
});

test("a hello that reports a session's end itself doesn't get a made-up one", async () => {
  const { store, posts, send } = helloHub();
  await store.put("machine", machine("s1", "s2"));
  await send(hello(["s2"], [{ id: "s1", cause: "exited" }]));
  const ended = posts.filter((p) => p.url === "https://org/ended");
  assert.equal(ended.length, 1);
  assert.equal(ended[0].body.end.cause, "exited");
});

test("a runner's session.events goes to the org hub's /session-events with the machine, and doesn't publish it", async () => {
  const { instance, store, posted, sent } = hub();
  await store.put("machine", machine("s1"));
  const msg = { type: "session.events", id: "s1", events: [], backfill: true, nextSeq: 1, epoch: "e1", nonce: "n1" };
  await (instance as unknown as { fromRunner(m: unknown): Promise<void> }).fromRunner(msg);
  assert.deepEqual(sent, [{ url: "https://org/session-events", body: { machine: "m1", msg } }]);
  assert.equal(posted.length, 0);
});

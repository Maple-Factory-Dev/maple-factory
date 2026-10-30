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
      get: () => ({ async fetch(_url: string, init: RequestInit) { posted.push(JSON.parse(init.body as string)); return new Response(null, { status: 204 }); } }),
    },
  };
  const ctx = { storage: store, getWebSockets: () => [], setWebSocketAutoResponse() {} };
  const instance = new MachineHub(ctx as never, env as never);
  let clock = 1_000_000;
  instance.now = () => clock;
  return { instance, store, posted, db, tick: (ms: number) => { clock += ms; } };
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

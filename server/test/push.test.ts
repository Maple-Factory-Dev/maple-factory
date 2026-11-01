// Mobile push (src/push.ts): signing, the payload's shape, who a task newly needs, and that nothing goes
// to the relay while it's off, in someone's quiet hours, or for a member whose devices were removed.
import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { createHmac, createHash } from "node:crypto";
import { DatabaseSync } from "node:sqlite";
import { Push, payload, pushReasons, seal, sign, unseal } from "../src/push.ts";
import { Store } from "../src/factory/store.ts";
import type { Env } from "../src/env.ts";
import type { Task } from "../src/wire.ts";

function sqlStorage() {
  const db = new DatabaseSync(":memory:");
  return {
    exec(query: string, ...bindings: unknown[]) {
      const statements = query.split(";").map((s) => s.trim()).filter(Boolean);
      if (statements.length > 1) {
        db.exec(query);
        return { toArray: () => [], one: () => undefined };
      }
      const rows = db.prepare(query).all(...(bindings as never[]));
      return { toArray: () => rows, one: () => rows[0] };
    },
  } as unknown as SqlStorage;
}

const KEY = "mfk_test-secrets-key";
const CRED = { id: "pf_factory123", secret: "pfs_secret" };

/** A D1 stand-in holding just the settings row push.ts reads. */
async function envWith(cred: typeof CRED | null, vars: Partial<Env> = {}): Promise<Env> {
  const value = cred ? await seal(KEY, cred) : null;
  const DB = { prepare: () => ({ bind: () => ({ first: async () => (value ? { value } : null) }) }) };
  return { DB, SECRETS_KEY: KEY, PUSH_RELAY_URL: "http://relay.test", ...vars } as unknown as Env;
}

let sent: Array<{ url: string; headers: Record<string, string>; body: string }>;
let answer = 200;
beforeEach(() => {
  sent = [];
  answer = 200;
  globalThis.fetch = (async (url: string, init: RequestInit) => {
    sent.push({ url: String(url), headers: init.headers as Record<string, string>, body: String(init.body) });
    return new Response("{}", { status: answer });
  }) as typeof fetch;
});

const task = (over: Partial<Task> = {}): Task => ({
  id: "MF-12", owner: "ada", state: "building", approvals: [], reviews: [], reviewsNeeded: 1, comments: [], hand: null, question: null, autoReview: null, ...over,
} as unknown as Task);
const hand = (assignee: string) => ({ reason: "needsInput", summary: "Which file?", at: 1, assignee, options: [] }) as Task["hand"];

function storeWithDevices() {
  const store = new Store(sqlStorage());
  store.registerPushDevice("ada", { platform: "apns", token: "apns-token-1", environment: "sandbox" });
  store.registerPushDevice("ada", { platform: "fcm", token: "fcm-token-1", environment: "production" });
  return store;
}

test("sign is hex HMAC-SHA256 over timestamp.body, keyed with SHA-256(secret)", async () => {
  const key = createHash("sha256").update(CRED.secret).digest("hex");
  const want = createHmac("sha256", key).update('1800000000.{"a":1}').digest("hex");
  assert.equal(await sign(CRED.secret, 1800000000, '{"a":1}'), want);
});

test("the credential is sealed under SECRETS_KEY and opens again", async () => {
  const sealed = await seal(KEY, CRED);
  assert.ok(!sealed.includes(CRED.secret));
  assert.deepEqual(await unseal(KEY, sealed), CRED);
  await assert.rejects(unseal("another-key", sealed));
});

test("the payload holds only the token, platform, environment, task key, reason and factory id", () => {
  const p = payload("pf_x", { token: "t", platform: "apns", environment: "sandbox" }, "MF-12", "hand");
  assert.deepEqual(Object.keys(p).sort(), ["environment", "factory", "platform", "reason", "ref", "token"]);
});

test("who a task newly needs, for the Mac Notifier's reasons", () => {
  const all = ["ada", "bob"];
  assert.deepEqual(pushReasons(task(), task({ hand: hand("ada") }), all), [{ login: "ada", reason: "hand" }]);
  // Still up on the next save: no second push.
  assert.deepEqual(pushReasons(task({ hand: hand("ada") }), task({ hand: hand("ada") }), all), []);
  assert.deepEqual(pushReasons(task(), task({ question: { text: "?" } as never }), all), [{ login: "ada", reason: "question" }]);
  assert.deepEqual(pushReasons(task(), task({ state: "awaitingApproval", approvals: ["bob"] }), all), [{ login: "ada", reason: "approval" }]);
  const passed = { maxRounds: 3, rounds: [{ number: 1, verdict: "passed", found: 0, at: 1 }] } as never;
  assert.deepEqual(pushReasons(task({ state: "reviewing" }), task({ state: "reviewing", autoReview: passed }), all).map((r) => r.reason), ["review", "review"]);
  const c = { id: "c1", author: "bob", text: "@ada look", at: 1, anchor: null, via: null, mentions: ["ada"], replyTo: null };
  assert.deepEqual(pushReasons(task(), task({ comments: [c] }), all), [{ login: "ada", reason: "mention" }]);
  assert.deepEqual(pushReasons(task({ comments: [c] }), task({ comments: [c] }), all), []);
});

test("a raised hand sends one signed push per device", async () => {
  const push = new Push(await envWith(CRED), storeWithDevices());
  await push.taskSaved(task(), task({ hand: hand("ada") }), async () => [{ login: "ada" }, { login: "bob" }] as never);
  assert.equal(sent.length, 2);
  for (const s of sent) {
    assert.equal(s.url, "http://relay.test/push/send");
    assert.equal(s.headers["x-maple-factory"], CRED.id);
    assert.equal(s.headers["x-maple-signature"], await sign(CRED.secret, Number(s.headers["x-maple-timestamp"]), s.body));
    const body = JSON.parse(s.body);
    assert.equal(body.ref, "MF-12");
    assert.equal(body.reason, "hand");
    assert.equal(body.factory, CRED.id);
    assert.ok(!s.body.includes("Which file?"), "no hand summary leaves the factory");
  }
  assert.deepEqual(sent.map((s) => JSON.parse(s.body).platform).sort(), ["apns", "fcm"]);
});

test("nothing goes out while the relay is off (no credential)", async () => {
  const push = new Push(await envWith(null), storeWithDevices());
  let asked = false;
  await push.taskSaved(task(), task({ hand: hand("ada") }), async () => { asked = true; return [{ login: "ada" }] as never; });
  assert.equal(await push.send("ada", { ref: "MF-12", reason: "hand" }), 0);
  assert.equal(sent.length, 0);
  assert.equal(asked, false, "doesn't even read the members");
});

test("nothing goes out when PUSH_RELAY=off locks it, even with a credential", async () => {
  const push = new Push(await envWith(CRED, { PUSH_RELAY: "off" }), storeWithDevices());
  assert.equal(await push.send("ada", { ref: "MF-12", reason: "hand" }), 0);
  assert.equal(sent.length, 0);
});

test("nothing goes out in someone's quiet hours", async () => {
  const store = storeWithDevices();
  store.setQuietHours("ada", { timeZone: "UTC", windows: [{ days: [0, 1, 2, 3, 4, 5, 6], start: 0, end: 1439 }] });
  const push = new Push(await envWith(CRED), store);
  // 23:59 UTC is outside a 00:00–23:59 window; anything else is inside.
  if (new Date().getUTCHours() === 23 && new Date().getUTCMinutes() === 59) return;
  assert.equal(await push.send("ada", { ref: "MF-12", reason: "hand" }), 0);
  assert.equal(sent.length, 0);
});

test("nothing goes out for a revoked member: their devices go with their access", async () => {
  const store = storeWithDevices();
  store.removePushDevices("ada"); // what OrgHub.cutOff does
  const push = new Push(await envWith(CRED), store);
  await push.taskSaved(task(), task({ hand: hand("ada") }), async () => [{ login: "ada" }] as never);
  assert.equal(sent.length, 0);
});

test("a token the relay says is gone (410) is deleted", async () => {
  const store = storeWithDevices();
  answer = 410;
  const push = new Push(await envWith(CRED), store);
  await push.send("ada", { ref: "MF-12", reason: "hand" });
  assert.equal(store.pushDevices("ada").length, 0);
});

test("devices: each person's own, capped at 10, a token moves to whoever registers it", () => {
  const store = new Store(sqlStorage());
  for (let i = 0; i < 10; i++) store.registerPushDevice("ada", { platform: "fcm", token: `t${i}`, environment: "production" });
  assert.throws(() => store.registerPushDevice("ada", { platform: "fcm", token: "t10", environment: "production" }), /at most 10/);
  store.registerPushDevice("ada", { platform: "fcm", token: "t0", environment: "production" }); // refreshing one is fine
  assert.equal(store.removePushDevice("t1", "bob"), false, "bob can't remove ada's");
  store.registerPushDevice("bob", { platform: "fcm", token: "t1", environment: "production" });
  assert.equal(store.pushDevices("ada").length, 9);
  assert.equal(store.pushDevices("bob").length, 1);
  assert.equal(store.pushDeviceCount(), 10);
});

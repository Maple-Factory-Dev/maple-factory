// The native session view's relay rules: who may watch or type, and which subscribers a runner's events reach.
import { test } from "node:test";
import assert from "node:assert/strict";
import { recipients, sessionAccess, toClient, type Subscriber } from "../src/session-events.ts";
import type { Machine, RunnerMessage_SessionEvents, SessionShare } from "../src/wire.ts";

const S = "11111111-1111-1111-1111-111111111111";

function machine(shares: Pick<SessionShare, "login" | "canType">[] = []): Machine {
  return {
    id: "bobs-mac", name: "Bob's Mac", owner: "bob", online: true, usage: [],
    sessions: [{ session: { id: S }, activity: null, shares: shares.length ? shares : undefined }],
  } as unknown as Machine;
}

const bob = { login: "bob", role: "member" };
const alice = { login: "alice", role: "admin" };
const carol = { login: "carol", role: "member" };
const dave = { login: "dave", role: "member" };

test("owner and admin type; a share watches, or types with canType; anyone else gets nothing", () => {
  const m = machine([{ login: "carol", canType: false }]);
  assert.equal(sessionAccess(m, S, bob), "type");
  assert.equal(sessionAccess(m, S, alice), "type");
  assert.equal(sessionAccess(m, S, carol), "watch");
  assert.equal(sessionAccess(machine([{ login: "carol", canType: true }]), S, carol), "type");
  assert.equal(sessionAccess(m, S, dave), null);
  // The share is on that session only.
  assert.equal(sessionAccess(m, "22222222-2222-2222-2222-222222222222", carol), null);
  // Taken back.
  assert.equal(sessionAccess(machine(), S, carol), null);
  assert.equal(sessionAccess(undefined, S, bob), null);
});

const subs = (): Subscriber<string>[] => [
  { conn: "bob-1", member: bob, events: [{ machine: "bobs-mac", id: S, nonce: "n-bob" }] },
  { conn: "carol-1", member: carol, events: [{ machine: "bobs-mac", id: S, nonce: "n-carol" }] },
  { conn: "dave-1", member: dave, events: [{ machine: "bobs-mac", id: S, nonce: "n-dave" }] },
  { conn: "alice-1", member: alice, events: [{ machine: "other", id: S, nonce: "n-alice" }] },
];

test("a backfill reaches only the subscriber whose nonce it echoes", () => {
  const m = machine([{ login: "carol", canType: false }]);
  assert.deepEqual(recipients(m, { id: S, backfill: true, nonce: "n-carol" }, subs()), ["carol-1"]);
  assert.deepEqual(recipients(m, { id: S, backfill: true, nonce: "n-bob" }, subs()), ["bob-1"]);
  // A nonce nobody holds (a replaced subscription), or a backfill without one, goes nowhere.
  assert.deepEqual(recipients(m, { id: S, backfill: true, nonce: "stale" }, subs()), []);
  assert.deepEqual(recipients(m, { id: S, backfill: true, nonce: null }, subs()), []);
  // Even with the right nonce, someone without access gets nothing.
  assert.deepEqual(recipients(m, { id: S, backfill: true, nonce: "n-dave" }, subs()), []);
});

test("live events reach every subscriber still allowed, and skip one whose share was removed", () => {
  const shared = machine([{ login: "carol", canType: false }]);
  assert.deepEqual(recipients(shared, { id: S, backfill: false, nonce: null }, subs()), ["bob-1", "carol-1"]);
  assert.deepEqual(recipients(machine(), { id: S, backfill: false }, subs()), ["bob-1"]);
  assert.deepEqual(recipients(undefined, { id: S, backfill: false }, subs()), []);
});

test("the apps' copy carries the machine, not the runner's nonce or cursor", () => {
  const msg: RunnerMessage_SessionEvents = {
    type: "session.events", id: S, backfill: true, nextSeq: 3, epoch: "e1", nonce: "n-carol", cursor: { seq: 2, token: "t" },
    events: [{ type: "user", id: "u1", session: S, seq: 1, at: 1, agent: "claude", text: "hi" }],
  };
  const out = toClient(msg, "bobs-mac");
  assert.equal(out.machine, "bobs-mac");
  assert.equal(out.type, "session.events");
  assert.deepEqual(out.events, msg.events);
  assert.equal(out.nextSeq, 3);
  assert.equal(out.epoch, "e1");
  assert.ok(!("nonce" in out));
  assert.ok(!("cursor" in out));
});

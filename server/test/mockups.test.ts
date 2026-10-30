// Asking for a change to a mockup, through the engine on a node:sqlite store (as factory.test.ts does):
// taken only while the plan is open. Awaiting approval, the planner revises the plan; planning, a running
// planner has it typed in and one yet to start reads it in its prompt. Any other state is refused, with
// nothing marked, so no change is left queued that never gets delivered.
import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { Engine } from "../src/factory/engine.ts";
import { Store } from "../src/factory/store.ts";

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

/** The engine with MF-1 in `state`, one proposed mockup and an approval; what goes to the machine is in `sent`. */
function factory(state: string, worker: Record<string, unknown> | null = null) {
  const store = new Store(sqlStorage());
  const sent: Record<string, unknown>[] = [];
  const hooks = {
    broadcast: () => {},
    sendTo: () => {},
    // No machine has room, so sending it back to planning doesn't start a session here.
    machines: async () => [],
    members: async () => [],
    machineChanged: async () => {},
    waitUntil: () => {},
    wakeIn: () => {},
  };
  const MACHINE = {
    idFromName: (id: string) => id,
    get: () => ({ fetch: async (_: string, init: RequestInit) => (sent.push(JSON.parse(String(init.body))), new Response(null)) }),
  };
  const engine = new Engine({ MACHINE } as never, store, hooks as never, { forTask: () => {} } as never, {} as never);
  store.saveTask({
    id: "MF-1", goal: "g", title: "Fix it", state, owner: "me", brief: "", createdAt: 1, updatedAt: 1, plan: [], planVersion: 1, doneWhen: [],
    approvals: ["boss"], approvalsNeeded: 1, reviews: [], reviewsNeeded: 1, comments: [], changes: [], events: [], tickets: [],
    mockups: [{ id: "m1", title: "Merge banner", kind: "screen", url: null, html: "<p>hi</p>", lines: [], notes: [], status: "proposed", version: 1, differences: [] }],
    shareable: false, agent: "claude", machine: null, worker,
  } as never);
  const ask = (text = "Put the countdown in the banner") =>
    engine.command({ type: "task.mockupChange", id: "MF-1", mockup: "m1", text } as never, { member: { login: "me", role: "member" } } as never);
  const task = () => store.task("MF-1")!;
  return { ask, task, sent };
}

test("a mockup change once it's past the plan is refused, and leaves the mockup and the changes alone", async () => {
  for (const state of ["building", "backlog", "reviewing", "queued"]) {
    const { ask, task } = factory(state);
    await assert.rejects(ask(), /while it's being planned or waiting for approval/, state);
    assert.equal(task().state, state);
    assert.equal(task().mockups[0].status, "proposed", state);
    assert.deepEqual(task().changes, [], state);
    assert.deepEqual(task().events, [], state);
  }
});

test("awaiting approval, a mockup change sends the plan back to the planner with the change recorded", async () => {
  const { ask, task } = factory("awaitingApproval");
  await ask("  Put the countdown in the banner  ");
  assert.equal(task().state, "planning");
  assert.deepEqual(task().approvals, []);
  assert.equal(task().mockups[0].status, "changesRequested");
  assert.equal(task().changes.length, 1);
  assert.equal(task().changes[0].text, "Put the countdown in the banner");
  assert.equal(task().changes[0].anchor, "Mockup: Merge banner");
  assert.equal(task().changes[0].status, "queued");
  assert.ok(task().events.some((e) => e.text === "sent it back to the planner"));
});

test("planning with no session yet, a mockup change is queued for the planner's prompt", async () => {
  const { ask, task, sent } = factory("planning");
  await ask();
  assert.equal(task().state, "planning");
  assert.equal(task().mockups[0].status, "changesRequested");
  assert.equal(task().changes[0].anchor, "Mockup: Merge banner");
  assert.equal(task().changes[0].status, "queued");
  assert.deepEqual(sent, []);
});

test("planning with a session, a mockup change is typed into the planner", async () => {
  const { ask, task, sent } = factory("planning", { role: "planner", agent: "claude", machine: "mac", session: "s1", startedAt: 1 });
  await ask();
  assert.equal(task().state, "planning");
  assert.equal(task().changes[0].status, "applying");
  assert.equal(sent.length, 1);
  assert.equal(sent[0].session, "s1");
  assert.match(String(sent[0].text), /^Change request C1 from me: Put the countdown in the banner/);
});

test("an empty mockup change is refused", async () => {
  const { ask, task } = factory("awaitingApproval");
  await assert.rejects(ask("   "), /Say what to change/);
  assert.equal(task().mockups[0].status, "proposed");
  assert.deepEqual(task().changes, []);
});

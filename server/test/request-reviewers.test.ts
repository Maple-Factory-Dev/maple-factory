// task.requestReviewers (MF-299): GitHub-style review requests. Through the engine on a node:sqlite store.
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

const members = [
  { login: "owner", role: "member" },
  { login: "ada", role: "member" },
  { login: "bob", role: "member" },
];
const as = (login: string) => ({ member: members.find((m) => m.login === login)! }) as never;

function factory(state = "awaitingApproval") {
  const store = new Store(sqlStorage());
  const audits: unknown[][] = [];
  const hooks = {
    broadcast: () => {},
    sendTo: () => {},
    machines: async () => [],
    members: async () => members,
    machineChanged: async () => {},
    waitUntil: () => {},
    wakeIn: () => {},
  };
  const DB = { prepare: () => ({ bind: (...args: unknown[]) => ({ run: async () => { audits.push(args); } }) }) };
  const engine = new Engine({ DB } as never, store, hooks as never, { forTask: () => {} } as never, {} as never);
  store.saveGoal({ id: "g", name: "Mac", prefix: "MF", summary: "", lead: "owner", repos: ["acme/mac"], repo: "acme/mac", archived: false } as never);
  // Saved the way an older server stored it: no `requested`.
  store.saveTask({
    id: "MF-1", goal: "g", title: "Reviewers", state, owner: "owner", brief: "", createdAt: 1, updatedAt: 1, plan: [{ text: "do it", status: "pending" }], planVersion: 1, doneWhen: [],
    approvals: [], approvalsNeeded: 2, reviews: [], reviewsNeeded: 1, comments: [], changes: [], events: [], mockups: [], tickets: [],
    shareable: true, agent: "claude", repo: "acme/mac", after: [],
  } as never);
  const request = (who: string, add: string[], remove: string[] = []) => engine.command({ type: "task.requestReviewers", id: "MF-1", add, remove } as never, as(who));
  return { store, engine, audits, request, t: () => store.task("MF-1")! };
}

test("a stored task without the field loads with no one requested", () => {
  assert.deepEqual(factory().t().requested, []);
});

test("requests add and remove people, with a task event and an audit entry each time", async () => {
  const f = factory();
  await f.request("owner", ["@ada", "bob", "ADA"]);
  assert.deepEqual(f.t().requested, ["ada", "bob"]);
  assert.ok(f.t().events.some((e) => e.text === "requested a review from @ada"));
  await f.request("owner", [], ["bob"]);
  assert.deepEqual(f.t().requested, ["ada"]);
  assert.ok(f.t().events.some((e) => e.text === "removed @bob's review request"));
  assert.ok(f.audits.some((a) => a.includes("task.reviewersRequested")));
});

test("the owner and anyone who already approved the stage are skipped", async () => {
  const f = factory();
  await f.engine.command({ type: "task.approvePlan", id: "MF-1" } as never, as("bob"));
  await f.request("ada", ["owner", "bob"]);
  assert.deepEqual(f.t().requested, []);
});

test("non-members and finished tasks are refused", async () => {
  const f = factory();
  await assert.rejects(f.request("owner", ["mallory"]), /mallory isn't in the org/);
  assert.deepEqual(f.t().requested, []);
  const done = factory("merged");
  await assert.rejects(done.request("owner", ["ada"]), /merged/);
});

test("approving the plan clears that person's request and no one else's", async () => {
  const f = factory();
  await f.request("owner", ["ada", "bob"]);
  await f.engine.command({ type: "task.approvePlan", id: "MF-1" } as never, as("ada"));
  assert.deepEqual(f.t().requested, ["bob"]);
});

test("approving the changes clears the request too", async () => {
  const f = factory("reviewing");
  f.store.saveTask({ ...f.t(), autoReview: { maxRounds: 3, rounds: [{ number: 1, verdict: "passed", found: 0, at: 1 }] } } as never);
  await f.request("owner", ["ada"]);
  assert.deepEqual(f.t().requested, ["ada"]);
  await f.engine.command({ type: "task.approveChanges", id: "MF-1" } as never, as("ada"));
  assert.deepEqual(f.t().requested, []);
});

// Reordering drafts with task.rankDraft, through the engine on a node:sqlite store (as queue.test.ts does):
// drafts keep their own order, separate from the queue's, and stay drafts.
import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { Engine, FactoryError } from "../src/factory/engine.ts";
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

/** A task as an older server saved it: no queueRank or draftRank. */
function legacy(store: Store, id: string, createdAt: number, f: Record<string, unknown> = {}) {
  store.saveTask({
    id, goal: "g", title: id, state: "drafting", owner: "me", brief: "", createdAt, updatedAt: createdAt, plan: [], planVersion: 0, doneWhen: [],
    approvals: [], approvalsNeeded: 1, reviews: [], reviewsNeeded: 1, comments: [], changes: [], events: [], mockups: [], tickets: [],
    shareable: false, agent: "claude", ...f,
  } as never);
}

function factory() {
  const store = new Store(sqlStorage());
  const noop = () => {};
  const hooks = { broadcast: noop, sendTo: noop, machines: async () => [], members: async () => [], machineChanged: async () => {}, waitUntil: noop, wakeIn: noop };
  const engine = new Engine({} as never, store, hooks as never, {} as never, {} as never);
  legacy(store, "T-1", 1000);
  legacy(store, "T-2", 2000);
  legacy(store, "T-3", 3000);
  const rank = (id: string, before?: string) =>
    engine.command({ type: "task.rankDraft", id, before }, { member: { login: "me" } } as never);
  const order = () => store.drafts("g").map((t) => t.id);
  return { store, rank, order };
}

test("drafts saved before draftRank keep their createdAt order", () => {
  const { store, order } = factory();
  assert.deepEqual(order(), ["T-1", "T-2", "T-3"]);
  assert.deepEqual(store.drafts("g").map((t) => t.draftRank), [1000, 2000, 3000]);
});

test("top, ahead of a draft and the bottom reorder the drafts", async () => {
  const { store, rank, order } = factory();
  await rank("T-3", "top");
  assert.deepEqual(order(), ["T-3", "T-1", "T-2"]);
  await rank("T-2", "T-1");
  assert.deepEqual(order(), ["T-3", "T-2", "T-1"]);
  await rank("T-3");
  assert.deepEqual(order(), ["T-2", "T-1", "T-3"]);
  assert.match(store.task("T-3")!.events.map((e) => e.text).join("\n"), /moved it to the top of the drafts\n.*bottom of the drafts/);
  assert.equal(store.task("T-2")!.events.at(-1)!.text, "moved it ahead of T-1 in the drafts");
});

test("reordering keeps them drafting and leaves their queueRank alone", async () => {
  const { store, rank } = factory();
  const queueRanks = () => ["T-1", "T-2", "T-3"].map((id) => store.task(id)!.queueRank);
  const was = queueRanks();
  await rank("T-3", "top");
  await rank("T-1");
  assert.deepEqual(["T-1", "T-2", "T-3"].map((id) => store.task(id)!.state), ["drafting", "drafting", "drafting"]);
  assert.deepEqual(queueRanks(), was);
});

test("only drafts are reordered, ahead of another draft in the goal", async () => {
  const { store, rank, order } = factory();
  legacy(store, "T-4", 4000, { state: "planning" });
  legacy(store, "T-5", 5000, { goal: "other" });
  await assert.rejects(rank("T-4", "top"), FactoryError);
  assert.equal(store.task("T-4")!.state, "planning");
  await assert.rejects(rank("T-1", "T-4"), /isn't a draft in this goal/);
  await assert.rejects(rank("T-1", "T-5"), /isn't a draft in this goal/);
  await assert.rejects(rank("T-1", "T-1"), /ahead of itself/);
  assert.deepEqual(order(), ["T-1", "T-2", "T-3"]);
});

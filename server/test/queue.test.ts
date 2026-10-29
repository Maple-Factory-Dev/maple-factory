// The store's queue against node:sqlite standing in for a Durable Object's SqlStorage: tasks saved
// before the queue (no queueRank) keep their FIFO order, and moves land between their neighbours.
import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { Store } from "../src/factory/store.ts";

/** Just what Store uses of SqlStorage: exec(query, ...bindings) → { toArray(), one() }. */
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

/** A planning task as an older server saved it: no queueRank. */
function legacy(store: Store, id: string, createdAt: number, updatedAt: number) {
  const doc = {
    id, goal: "g", title: id, state: "planning", owner: "me", brief: "", createdAt, updatedAt, plan: [], planVersion: 0, doneWhen: [],
    approvals: [], approvalsNeeded: 1, reviews: [], reviewsNeeded: 1, comments: [], changes: [], events: [], mockups: [], tickets: [],
    shareable: false, agent: "claude",
  };
  store.saveTask(doc as never);
}

test("tasks saved before the queue keep their FIFO order, whatever was edited last", () => {
  const store = new Store(sqlStorage());
  // Oldest first by createdAt; updated the other way round, as the old pump's order went.
  legacy(store, "T-1", 1000, 9000);
  legacy(store, "T-2", 2000, 8000);
  legacy(store, "T-3", 3000, 7000);
  assert.deepEqual(store.tasks().map((t) => t.id), ["T-1", "T-2", "T-3"]); // by updated, newest first
  assert.deepEqual(store.queued().map((t) => [t.id, t.queueRank]), [["T-1", 1000], ["T-2", 2000], ["T-3", 3000]]);
});

test("moving ahead of a task takes the midpoint, the top goes before the first, the back after the last", () => {
  const store = new Store(sqlStorage());
  legacy(store, "T-1", 1000, 1000);
  legacy(store, "T-2", 2000, 2000);
  legacy(store, "T-3", 3000, 3000);
  const move = (id: string, before: string | null) => {
    const task = store.task(id)!;
    task.queueRank = store.rankBefore(id, before ? store.task(before) : null);
    store.saveTask(task);
    return store.queued().map((t) => t.id);
  };
  assert.deepEqual(move("T-3", "T-2"), ["T-1", "T-3", "T-2"]);
  assert.equal(store.task("T-3")!.queueRank, 1500);
  assert.deepEqual(move("T-2", "T-1"), ["T-2", "T-1", "T-3"]);
  assert.deepEqual(move("T-2", null), ["T-1", "T-3", "T-2"]);
  assert.equal(store.task("T-2")!.queueRank, 1501);
});

test("only tasks waiting for a session are queued", () => {
  const store = new Store(sqlStorage());
  legacy(store, "T-1", 1000, 1000);
  legacy(store, "T-2", 2000, 2000);
  const running = store.task("T-2")!;
  running.worker = { role: "planner", agent: "claude", machine: "m", session: crypto.randomUUID(), startedAt: 1 };
  store.saveTask(running);
  const waiting = { ...store.task("T-1")!, id: "T-3", state: "awaitingApproval" as const };
  store.saveTask(waiting);
  assert.deepEqual(store.queued().map((t) => t.id), ["T-1"]);
});

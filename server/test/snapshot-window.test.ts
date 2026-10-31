// The snapshot window (MF-212): the apps' snapshot holds unfinished tasks and recently finished ones;
// older finished tasks come a page at a time, and tallies count every task.
import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { Store, SNAPSHOT_WINDOW_MS } from "../src/factory/store.ts";

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

const NOW = 1_800_000_000_000;
const DAY = 86_400_000;

function save(store: Store, id: string, goal: string, state: string, updatedAt: number) {
  store.saveTask({
    id, goal, title: id, state, owner: "me", brief: "", createdAt: updatedAt, updatedAt, plan: [], planVersion: 0, doneWhen: [],
    approvals: [], approvalsNeeded: 1, reviews: [], reviewsNeeded: 1, comments: [], changes: [], events: [], mockups: [], tickets: [],
    shareable: false, agent: "claude",
  } as never);
}

function seeded() {
  const store = new Store(sqlStorage());
  save(store, "A-1", "a", "building", NOW - 400 * DAY); // open, however old
  save(store, "A-2", "a", "drafting", NOW - 1 * DAY);
  save(store, "A-3", "a", "merged", NOW - 2 * DAY); // recent
  save(store, "A-4", "a", "closed", NOW - 13 * DAY); // recent
  for (let i = 0; i < 120; i++) save(store, `A-${100 + i}`, "a", i % 3 ? "merged" : "cancelled", NOW - 20 * DAY - i * DAY);
  // Three finished in the same millisecond, to page across a tie.
  for (const id of ["B-1", "B-2", "B-3"]) save(store, id, "b", "merged", NOW - 30 * DAY);
  save(store, "B-4", "b", "reviewing", NOW - 30 * DAY);
  return store;
}

test("the snapshot holds unfinished tasks and those finished in the window", () => {
  const { tasks, left } = seeded().snapshotTasks(NOW);
  assert.deepEqual(tasks.map((t) => t.id).sort(), ["A-1", "A-2", "A-3", "A-4", "B-4"]);
  assert.equal(left, 123);
});

test("a task finished just inside the window is sent, just outside isn't", () => {
  const store = new Store(sqlStorage());
  save(store, "X-1", "x", "merged", NOW - SNAPSHOT_WINDOW_MS);
  save(store, "X-2", "x", "merged", NOW - SNAPSHOT_WINDOW_MS - 1);
  assert.deepEqual(store.snapshotTasks(NOW).tasks.map((t) => t.id), ["X-1"]);
});

test("tallies count every task, also the ones left out", () => {
  assert.deepEqual(seeded().tallies(), [
    { goal: "a", merged: 81, cancelled: 40, closed: 1, total: 124 },
    { goal: "b", merged: 3, cancelled: 0, closed: 0, total: 4 },
  ]);
});

test("olderTasks pages back through a goal's finished tasks until there are no more", () => {
  const store = seeded();
  const seen: string[] = [];
  let before: number | null = null;
  let beforeId: string | null = null;
  let pages = 0;
  for (;;) {
    const page = store.olderTasks("a", before, beforeId, 50, NOW);
    pages++;
    seen.push(...page.tasks.map((t) => t.id));
    for (const t of page.tasks) assert.ok(["merged", "cancelled", "closed"].includes(t.state));
    if (!page.more) break;
    const last = page.tasks.at(-1)!;
    before = last.updatedAt;
    beforeId = last.id;
  }
  assert.equal(pages, 3);
  assert.equal(seen.length, 120);
  assert.equal(new Set(seen).size, 120);
  assert.equal(seen[0], "A-100"); // newest first
});

test("paging past tasks finished in the same millisecond skips none", () => {
  const store = seeded();
  const first = store.olderTasks("b", null, null, 2, NOW);
  assert.deepEqual(first.tasks.map((t) => t.id), ["B-3", "B-2"]);
  assert.equal(first.more, true);
  const last = first.tasks.at(-1)!;
  const second = store.olderTasks("b", last.updatedAt, last.id, 2, NOW);
  assert.deepEqual(second.tasks.map((t) => t.id), ["B-1"]);
  assert.equal(second.more, false);
});

test("olderTasks without a goal spans goals; the limit is capped at 200", () => {
  const page = seeded().olderTasks(null, null, null, 10_000, NOW);
  assert.equal(page.tasks.length, 123);
  assert.equal(page.more, false);
  assert.equal(seeded().olderTasks(null, null, null, null, NOW).tasks.length, 50);
});

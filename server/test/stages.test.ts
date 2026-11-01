// Stage spans (MF-302): live tracking on save, waits, terminal markers, and the inferred backfill
// for tasks from before `stages`.
import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { inferStages, phaseOf, trackStage } from "../src/factory/stages.ts";
import { Store } from "../src/factory/store.ts";
import type { Task } from "../src/wire.ts";

const T0 = Date.UTC(2026, 9, 1, 9);
const M = 60_000;

function task(f: Record<string, unknown> = {}): Task {
  return {
    id: "MF-1", goal: "g1", title: "t", state: "drafting", owner: "me", brief: "", createdAt: T0, updatedAt: T0, plan: [], planVersion: 0, doneWhen: [],
    approvals: [], approvalsNeeded: 1, reviews: [], reviewsNeeded: 1, requested: [], comments: [], changes: [], events: [], stages: [], mockups: [], artifacts: [], tickets: [],
    shareable: false, agent: "claude", repo: null, after: [], followUps: [], ...f,
  } as unknown as Task;
}

const brief = (t: Task) => t.stages.map((s) => [s.stage, s.wait ?? null, s.from - T0, s.to == null ? null : s.to - T0]);

test("a full run records one span per phase, with queued, hand and question waits", () => {
  const t = task();
  trackStage(t, T0); // created
  t.state = "planning"; trackStage(t, T0 + 1 * M);
  t.state = "awaitingApproval"; trackStage(t, T0 + 10 * M);
  t.state = "building"; t.waiting = "Waiting for a free slot on your machines"; trackStage(t, T0 + 30 * M);
  t.waiting = null; trackStage(t, T0 + 35 * M);
  t.hand = { reason: "needsInput" } as never; trackStage(t, T0 + 50 * M);
  t.hand = null; trackStage(t, T0 + 60 * M);
  t.question = { text: "?" } as never; trackStage(t, T0 + 70 * M);
  t.question = null; trackStage(t, T0 + 72 * M);
  t.state = "reviewing"; trackStage(t, T0 + 90 * M);
  t.state = "merged"; trackStage(t, T0 + 100 * M);
  assert.deepEqual(brief(t), [
    ["drafting", null, 0, 1 * M],
    ["planning", null, 1 * M, 10 * M],
    ["awaitingApproval", null, 10 * M, 30 * M],
    ["building", "queued", 30 * M, 35 * M],
    ["building", null, 35 * M, 50 * M],
    ["building", "hand", 50 * M, 60 * M],
    ["building", null, 60 * M, 70 * M],
    ["building", "question", 70 * M, 72 * M],
    ["building", null, 72 * M, 90 * M],
    ["reviewing", null, 90 * M, 100 * M],
    ["merged", null, 100 * M, 100 * M],
  ]);
  assert.ok(t.stages.every((s) => !s.inferred));
});

test("saving with no phase change adds no span", () => {
  const t = task({ state: "building" });
  assert.equal(trackStage(t, T0), true);
  assert.equal(trackStage(t, T0 + M), false);
  t.title = "renamed";
  assert.equal(trackStage(t, T0 + 2 * M), false);
  assert.equal(t.stages.length, 1);
  assert.equal(t.stages[0].to, null);
});

test("a terminal state closes the open span, adds one marker, and ignores its own waits", () => {
  const t = task({ state: "building" });
  trackStage(t, T0);
  t.state = "cancelled"; t.waiting = "stale";
  assert.deepEqual(phaseOf(t), { stage: "cancelled", wait: null });
  trackStage(t, T0 + 5 * M);
  trackStage(t, T0 + 9 * M); // saved again while cancelled
  assert.deepEqual(brief(t), [["building", null, 0, 5 * M], ["cancelled", null, 5 * M, 5 * M]]);
  // Picked back up: a new open span after the marker.
  t.state = "building"; t.waiting = null; trackStage(t, T0 + 20 * M);
  assert.deepEqual(brief(t).at(-1), ["building", null, 20 * M, null]);
});

test("the first span starts at createdAt", () => {
  const t = task({ state: "planning" });
  trackStage(t, T0 + 3 * M);
  assert.equal(t.stages[0].from, T0);
});

const history = [
  { who: "me", text: "sent it to planning", at: T0 + 2 * M },
  { who: "planner", text: "wrote the plan", at: T0 + 20 * M },
  { who: "me", text: "approved the plan", at: T0 + 40 * M },
  { who: "builder", text: "raised a hand", at: T0 + 60 * M },
  { who: "factory", text: "opened pull request #12 on o/r", at: T0 + 120 * M },
  { who: "factory", text: "merged into main", at: T0 + 150 * M },
];

test("inferStages builds ordered, inferred spans from events", () => {
  const t = task({ state: "merged", events: history, updatedAt: T0 + 200 * M });
  const spans = inferStages(t);
  assert.deepEqual(spans.map((s) => [s.stage, s.from - T0, s.to! - T0]), [
    ["drafting", 0, 2 * M],
    ["planning", 2 * M, 20 * M],
    ["awaitingApproval", 20 * M, 40 * M],
    ["building", 40 * M, 120 * M],
    ["reviewing", 120 * M, 150 * M],
    ["merged", 150 * M, 150 * M],
  ]);
  assert.ok(spans.every((s) => s.inferred === true));
  for (let i = 1; i < spans.length; i++) assert.ok(spans[i].from >= spans[i - 1].from);
});

test("inferStages leaves an unfinished task's current stage open, and adds a terminal state its events lost", () => {
  const open = inferStages(task({ state: "building", events: history.slice(0, 3) }));
  assert.deepEqual(open.at(-1), { stage: "building", from: T0 + 40 * M, to: null, inferred: true });
  const cancelled = inferStages(task({ state: "cancelled", events: history.slice(0, 2), updatedAt: T0 + 90 * M }));
  assert.deepEqual(cancelled.slice(-2).map((s) => [s.stage, s.from - T0, s.to! - T0]), [["awaitingApproval", 20 * M, 90 * M], ["cancelled", 90 * M, 90 * M]]);
});

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

test("the store backfills stages once, on tasks that have none", () => {
  const sql = sqlStorage();
  const first = new Store(sql);
  const { stages: _, ...old } = task({ state: "merged", events: history, updatedAt: T0 + 200 * M });
  first.saveTask(old as Task);
  const tracked = task({ id: "MF-2", state: "building", stages: [{ stage: "building", from: T0, to: null }] });
  first.saveTask(tracked);
  first.set("stages:backfilled", "");
  const fresh = new Store(sql);
  assert.equal(fresh.task("MF-1")!.stages.length, 6);
  assert.ok(fresh.task("MF-1")!.stages.every((s) => s.inferred));
  assert.deepEqual(fresh.task("MF-2")!.stages, [{ stage: "building", from: T0, to: null }]);
});

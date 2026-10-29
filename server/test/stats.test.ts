// summarize on fixture events: counts, medians, rates, the window's cut-off, and the backfill that
// works out older tasks' history from their documents (in a node:sqlite store, as queue.test.ts does).
import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { inferEvents, median, summarize, type StatEvent } from "../src/factory/stats.ts";
import { Store } from "../src/factory/store.ts";

const DAY = 86_400_000;
const NOW = Date.UTC(2026, 9, 29, 12);
const H = 3_600_000;

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

function task(id: string, f: Record<string, unknown> = {}) {
  return {
    id, goal: "g1", title: id, state: "building", owner: "me", brief: "", createdAt: NOW - 10 * DAY, updatedAt: NOW, plan: [], planVersion: 1, doneWhen: [],
    approvals: [], approvalsNeeded: 1, reviews: [], reviewsNeeded: 1, comments: [], changes: [], events: [], mockups: [], tickets: [],
    shareable: false, agent: "claude", repo: null, after: [], followUps: [], ...f,
  } as never;
}

let n = 0;
const ev = (kind: StatEvent["kind"], taskId: string, ago: number, detail: Record<string, unknown> = {}, goal = "g1"): StatEvent =>
  ({ id: String(n++), at: NOW - ago, kind, task: taskId, goal, role: null, actor: null, detail });

const events: StatEvent[] = [
  ev("plan.submitted", "A-1", 9 * DAY, { version: 1 }),
  ev("plan.approved", "A-1", 9 * DAY, { version: 1 }),
  ev("plan.submitted", "A-2", 8 * DAY, { version: 1 }),
  ev("plan.submitted", "A-2", 7 * DAY, { version: 2 }),
  ev("plan.approved", "A-2", 7 * DAY, { version: 2 }),
  ev("plan.approved", "A-3", 6 * DAY, { version: 1 }),
  ev("hand.raised", "A-1", 5 * DAY, { reason: "needsInput" }),
  ev("hand.resolved", "A-1", 5 * DAY - H, { reason: "needsInput", openMs: H }),
  ev("hand.raised", "A-2", 4 * DAY, { reason: "needsInput" }),
  ev("hand.resolved", "A-2", 4 * DAY - 3 * H, { reason: "needsInput", openMs: 3 * H }),
  ev("hand.raised", "A-2", 3 * DAY, { reason: "proofBurden" }),
  ev("steer", "A-2", 3 * DAY),
  ev("steer", "A-2", 2 * DAY),
  ev("question.asked", "A-1", 2 * DAY),
  ev("question.answered", "A-1", 2 * DAY, { waitMs: 20 * 60_000 }),
  ev("review.round", "A-1", 2 * DAY, { number: 1, verdict: "changesRequested", findings: [{ kind: "code", severity: "major" }, { kind: "proof", severity: "blocker" }] }),
  ev("review.round", "A-1", 1 * DAY, { number: 2, verdict: "passed", findings: [{ kind: "code", severity: "minor" }] }),
  ev("review.round", "A-2", 1 * DAY, { number: 1, verdict: "passed", findings: [] }),
  ev("merged", "A-1", 1 * DAY, { auto: false, cycleMs: 9 * DAY }),
  ev("merged", "A-2", 12 * H, { auto: true, cycleMs: 5 * DAY }),
  ev("prompt.answered", "A-3", 6 * H, { choice: "yes" }),
  ev("session.restarted", "A-3", 5 * H, { cause: "machineSlept" }),
  // Outside a 30-day window, and another goal's.
  ev("merged", "A-9", 40 * DAY, { auto: false, cycleMs: DAY }),
  ev("hand.raised", "B-1", 2 * DAY, { reason: "needsInput" }, "g2"),
];
const tasks = [task("A-1", { state: "merged" }), task("A-2", { state: "merged", agent: "codex" }), task("A-3"), task("A-9", { state: "merged" }), task("B-1", { goal: "g2", hand: { reason: "needsInput", summary: "", at: NOW, assignee: "me", options: [] } })];

test("median of odd and even lists, and none for nothing", () => {
  assert.equal(median([3, 1, 2]), 2);
  assert.equal(median([4, 1, 3, 2]), 3); // (2 + 3) / 2, rounded
  assert.equal(median([]), null);
});

test("counts, medians and rates over 30 days", () => {
  const s = summarize(events, tasks, { days: 30, now: NOW, goals: [{ id: "g1", name: "Goal one" } as never] });
  const t = s.totals;
  assert.equal(t.merged, 2); // A-9's merge is 40 days old
  assert.equal(t.autoMerged, 1);
  assert.equal(t.cycleMedianMs, 7 * DAY); // (9 + 5) / 2 days
  assert.equal(t.approvals, 3);
  assert.equal(t.firstTryApproval, 0.67); // A-1 and A-3 at v1, A-2 at v2
  assert.equal(t.avgPlanVersions, 1.33);
  assert.equal(t.planVersions, 3);
  assert.equal(t.handsRaised, 4);
  assert.equal(t.handsOpen, 1); // B-1's, up now
  assert.equal(t.handOpenMedianMs, 2 * H);
  assert.equal(t.questions, 1);
  assert.equal(t.answerMedianMs, 20 * 60_000);
  assert.equal(t.steers, 2);
  assert.equal(t.reviewRounds, 3);
  assert.equal(t.reviewRoundsPerMerge, 1.5); // A-1 had 2, A-2 had 1
  assert.equal(t.findings, 3);
  assert.equal(t.prompts, 1);
  assert.equal(t.restarts, 1);
  assert.equal(t.tasksTouched, 4); // A-1, A-2, A-3, B-1
  assert.equal(t.steersPerTask, 0.5);
  assert.deepEqual(s.handsByReason, [
    { key: "needsInput", count: 3, medianMs: 2 * H },
    { key: "proofBurden", count: 1, medianMs: null },
  ]);
  assert.deepEqual(s.findingsByKind.map((c) => [c.key, c.count]), [["code", 2], ["proof", 1]]);
  assert.deepEqual(s.findingsBySeverity.map((c) => c.key), ["blocker", "major", "minor"]);
  assert.deepEqual(s.restartsByCause, [{ key: "machineSlept", count: 1, medianMs: null }]);
  assert.equal(s.daily.length, 30);
  assert.equal(s.daily.at(-1)!.day, "2026-10-29");
  assert.equal(s.daily.reduce((a, d) => a + d.merges, 0), 2);
  assert.equal(s.daily.reduce((a, d) => a + d.hands, 0), 4);
  assert.equal(s.goals.find((g) => g.goal === "g1")!.name, "Goal one");
  assert.deepEqual(s.agents.map((a) => [a.agent, a.merged]), [["claude", 1], ["codex", 1]]);
  // A-2: 2 hands, 2 steers; A-1: a hand, a question, a changes-requested round.
  assert.deepEqual(s.topTasks.slice(0, 2).map((r) => [r.task, r.touchpoints]), [["A-2", 4], ["A-1", 3]]);
});

test("the window cuts off: 7 days, 90 days, and one goal", () => {
  const week = summarize(events, tasks, { days: 7, now: NOW });
  assert.equal(week.totals.approvals, 2); // A-3's 6 days ago, and A-2's at exactly 7 (the start is inclusive)
  assert.equal(week.totals.planVersions, 1); // A-2's v2; its v1 and A-1's are 8 and 9 days old
  assert.equal(week.totals.merged, 2);
  assert.equal(week.daily.length, 7);
  const quarter = summarize(events, tasks, { days: 90, now: NOW });
  assert.equal(quarter.totals.merged, 3);
  assert.equal(quarter.totals.cycleMedianMs, 5 * DAY);
  const g2 = summarize(events, tasks, { days: 30, now: NOW, goal: "g2" });
  assert.equal(g2.totals.handsRaised, 1);
  assert.equal(g2.totals.merged, 0);
  assert.equal(g2.totals.firstTryApproval, null);
  assert.equal(g2.goal, "g2");
});

test("backfill infers plan versions, approvals, hands, steers, review rounds and merges, flagged inferred", () => {
  const old = task("OLD-1", {
    state: "merged", planVersion: 2, approvals: ["ann"], agent: "claude", createdAt: NOW - 3 * DAY,
    changes: [{ id: "C1", author: "ann", text: "smaller", at: NOW - 3 * DAY + H, anchor: null, status: "applied", timing: null }],
    events: [
      { who: "ann", text: "created it", at: NOW - 3 * DAY },
      { who: "planner", text: "wrote the plan", at: NOW - 3 * DAY + 10 },
      { who: "planner", text: "revised the plan (v2)", at: NOW - 3 * DAY + 2 * H },
      { who: "ann", text: "approved the plan", at: NOW - 3 * DAY + 3 * H },
      { who: "builder", text: "raised a hand", at: NOW - 2 * DAY },
      { who: "reviewer", text: "stopped and needs a hand: 5 review rounds and it still has open findings.", at: NOW - 2 * DAY + 10 },
      { who: "factory", text: "stopped and needs a hand: It didn't merge into main: conflicts", at: NOW - 2 * DAY + 20 },
      { who: "builder", text: "stopped and needs a hand: Its builder exited before it reported back (code 1).", at: NOW - 2 * DAY + 30 },
      { who: "factory", text: "auto-merged it (low risk)", at: NOW - DAY },
      { who: "factory", text: "merged into main (abc1234)", at: NOW - DAY + 5 },
    ],
    autoReview: {
      maxRounds: 5, summary: "", ask: [], proofs: [],
      rounds: [{ number: 1, verdict: "changesRequested", found: 1, at: NOW - 2 * DAY + H, fix: null }, { number: 2, verdict: "passed", found: 0, at: NOW - DAY - H, fix: null }],
      findings: [{ id: "R1.1", kind: "code", severity: "major", text: "x", file: null, raisedIn: 1, status: "fixed", fixedIn: 2 }],
    },
  });
  const inferred = inferEvents(old);
  assert.ok(inferred.every((e) => e.detail.inferred === true));
  assert.deepEqual(inferred.filter((e) => e.kind === "plan.submitted").map((e) => e.detail.version), [1, 2]);
  assert.equal(inferred.find((e) => e.kind === "plan.approved")!.detail.version, 2);
  assert.equal(inferred.find((e) => e.kind === "merged")!.detail.auto, true);
  // Each hand's reason comes from its wording; an agent's raise_hand doesn't say, so it's unknown.
  assert.deepEqual(inferred.filter((e) => e.kind === "hand.raised").map((e) => e.detail.reason), ["unknown", "reviewLoop", "mergeFailed", "sessionEnded"]);
  assert.equal(inferred.find((e) => e.kind === "merged")!.detail.cycleMs, 2 * DAY + 5);

  // The store backfills once, guarded by its kv flag.
  const sql = sqlStorage();
  new Store(sql).saveTask(old); // the first store has nothing to backfill yet: the flag is set
  const fresh = new Store(sql);
  assert.equal(fresh.statEvents().length, 0);
  fresh.set("stats:backfilled", "");
  const store = new Store(sql);
  const rows = store.statEvents();
  assert.equal(rows.length, inferred.length);
  new Store(sql);
  assert.equal(new Store(sql).statEvents().length, inferred.length); // not again

  const s = summarize(rows, [old], { days: 30, now: NOW });
  assert.equal(s.inferred, rows.length);
  assert.equal(s.totals.merged, 1);
  assert.equal(s.totals.firstTryApproval, 0);
  assert.equal(s.totals.reviewRounds, 2);
  assert.equal(s.totals.reviewRoundsPerMerge, 2);
  assert.equal(s.totals.steers, 1);
  assert.equal(s.totals.handsRaised, 4);
  assert.deepEqual(s.findingsByKind, [{ key: "code", count: 1, medianMs: null }]);
});

test("the store reads a window, plus the earlier review rounds of only the tasks it names", () => {
  const store = new Store(sqlStorage());
  const add = (kind: StatEvent["kind"], task: string, at: number) => store.recordStat({ at, kind, task, goal: "g1", role: null, actor: null, detail: {} });
  add("review.round", "A-1", NOW - 40 * DAY);
  add("review.round", "B-1", NOW - 40 * DAY);
  add("hand.raised", "A-1", NOW - 40 * DAY);
  add("review.round", "A-1", NOW - 2 * DAY);
  add("merged", "A-1", NOW - DAY);
  const since = NOW - 30 * DAY;
  assert.deepEqual(store.statEvents(since).map((e) => e.kind), ["review.round", "merged"]);
  assert.deepEqual(store.statRoundsBefore(["A-1"], since).map((e) => [e.task, e.kind]), [["A-1", "review.round"]]);
  assert.deepEqual(store.statRoundsBefore([], since), []);
});

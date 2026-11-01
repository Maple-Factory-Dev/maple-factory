// summarize on fixture events: counts, medians, rates, the window's cut-off, and the backfill that
// works out older tasks' history from their documents (in a node:sqlite store, as queue.test.ts does).
import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { findingArea, findingDetail, inferEvents, manualReason, median, statsWindow, summarize, type StatEvent } from "../src/factory/stats.ts";
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

test("24 hours and 3 days go by the hour, ending with this one", () => {
  const now = NOW + 30 * 60_000; // 12:30 UTC
  const at = (kind: StatEvent["kind"], ago: number, detail: Record<string, unknown> = {}): StatEvent =>
    ({ id: String(n++), at: now - ago, kind, task: "H-1", goal: "g1", role: null, actor: null, detail });
  const rows = [
    at("merged", 10 * 60_000, { auto: true, cycleMs: H }), // 12:20 today, this hour
    at("hand.raised", 15 * H, { reason: "needsInput" }), // 21:30 yesterday evening
    at("merged", 25 * H, { auto: false, cycleMs: H }), // 11:30 yesterday: outside 24 hours
    at("hand.raised", 50 * H, { reason: "proofBurden" }),
    at("merged", 80 * H, { auto: false, cycleMs: H }), // outside 3 days
  ];

  const day = summarize(rows, [], { days: 1, now });
  assert.equal(day.days, 1);
  assert.equal(day.since, now - DAY);
  assert.equal(day.daily.length, 24);
  assert.equal(day.daily.at(-1)!.day, "2026-10-29T12:00");
  assert.equal(day.daily[0].day, "2026-10-28T13:00");
  assert.deepEqual(day.daily.at(-1), { day: "2026-10-29T12:00", merges: 1, hands: 0 });
  assert.equal(day.daily.find((d) => d.day === "2026-10-28T21:00")!.hands, 1);
  assert.equal(day.totals.merged, 1);
  assert.equal(day.totals.handsRaised, 1);
  assert.equal(day.daily.reduce((a, d) => a + d.merges, 0), 1);
  assert.equal(day.daily.reduce((a, d) => a + d.hands, 0), 1);

  const three = summarize(rows, [], { days: 3, now });
  assert.equal(three.daily.length, 72);
  assert.equal(three.daily.at(-1)!.day, "2026-10-29T12:00");
  assert.equal(three.daily[0].day, "2026-10-26T13:00");
  assert.equal(three.totals.merged, 2);
  assert.equal(three.totals.handsRaised, 2);
  assert.equal(three.daily.reduce((a, d) => a + d.merges, 0), 2);
  assert.equal(three.daily.reduce((a, d) => a + d.hands, 0), 2);

  // 7 days still goes by the day.
  assert.equal(summarize(rows, [], { days: 7, now }).daily.at(-1)!.day, "2026-10-29");
});

test("the hub's windows: 1, 3, 7, 30 and 90 days, anything else reads as 30", () => {
  for (const d of [1, 3, 7, 30, 90]) assert.equal(statsWindow(d), d);
  for (const d of [5, 0, 2, 365, Number.NaN]) assert.equal(statsWindow(d), 30);
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
  // The backfilled round keeps the finding's file and text too.
  assert.deepEqual(inferred.find((e) => e.kind === "review.round")!.detail.findings, [{ kind: "code", severity: "major", file: null, text: "x" }]);
  assert.deepEqual(s.findings!.outcomes, { fixed: 1, disputed: 0, open: 0, unknown: 0, roundsToFixMedian: 1 });
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

const cost = (session: string, task: string, role: string, agent: string, model: string | null, costUsd: number | null, input: number, output: number, ago = H, goal = "g1") =>
  ({ session, task, goal, role: role as never, agent, model, costUsd, tokens: { input, output, cacheRead: 0, cacheWrite: 0 }, updated: NOW - ago });

test("cost adds up by role and by agent · model; Codex has tokens but no $", () => {
  const costs = [
    cost("s1", "A-1", "planner", "claude", "claude-opus-5-5", 0.5, 1000, 100),
    cost("s2", "A-1", "builder", "claude", "claude-opus-5-5", 2.25, 5000, 900),
    cost("s3", "A-2", "builder", "codex", "gpt-6.1", null, 8000, 400),
    cost("s4", "A-1", "reviewer", "claude", "claude-sonnet-5-5", 0.25, 2000, 50),
    // Outside the window, and another goal's.
    cost("s5", "A-9", "builder", "claude", "claude-opus-5-5", 9, 1, 1, 40 * DAY),
    cost("s6", "B-1", "builder", "claude", "claude-opus-5-5", 7, 1, 1, H, "g2"),
  ];
  const s = summarize(events, tasks, { days: 30, now: NOW, costs, goal: "g1" });
  assert.deepEqual(s.costTotal, { key: "total", sessions: 4, costUsd: 3, tokens: 17_450, unpriced: 1 });
  assert.deepEqual(s.costByRole.map((r) => [r.key, r.sessions, r.costUsd, r.tokens, r.unpriced]), [
    ["builder", 2, 2.25, 14_300, 1],
    ["planner", 1, 0.5, 1100, 0],
    ["reviewer", 1, 0.25, 2050, 0],
  ]);
  assert.deepEqual(s.costByAgent.map((r) => [r.key, r.sessions, r.costUsd]), [
    ["claude · claude-opus-5-5", 2, 2.75],
    ["claude · claude-sonnet-5-5", 1, 0.25],
    ["codex · gpt-6.1", 1, 0],
  ]);
  assert.equal(s.topTasks.find((t) => t.task === "A-1")?.costUsd, 3);
  assert.equal(s.topTasks.find((t) => t.task === "A-3")?.costUsd, null);
  // Nothing measured yet.
  const none = summarize(events, tasks, { days: 30, now: NOW });
  assert.equal(none.costTotal, null);
  assert.deepEqual(none.costByRole, []);
});

test("a later, lower reading doesn't reduce a session's total; the store reads a window and a goal", () => {
  const store = new Store(sqlStorage());
  store.recordSessionCost(cost("s1", "A-1", "builder", "claude", "claude-opus-5-5", 2, 5000, 900));
  // Its status line restarted and counts from zero again.
  store.recordSessionCost(cost("s1", "A-1", "builder", "claude", null, 0.1, 100, 1000, H / 2));
  store.recordSessionCost(cost("s2", "A-2", "builder", "codex", "gpt-6.1", null, 10, 10));
  store.recordSessionCost(cost("s3", "B-1", "planner", "claude", null, 1, 1, 1, H, "g2"));
  store.recordSessionCost(cost("s4", "A-9", "planner", "claude", null, 1, 1, 1, 40 * DAY));
  const s1 = store.sessionCosts(0).find((c) => c.session === "s1")!;
  assert.deepEqual([s1.costUsd, s1.tokens.input, s1.tokens.output, s1.model, s1.updated], [2, 5000, 1000, "claude-opus-5-5", NOW - H / 2]);
  assert.equal(store.sessionCosts(0).find((c) => c.session === "s2")!.costUsd, null);
  assert.deepEqual(store.sessionCosts(NOW - 30 * DAY).map((c) => c.session).sort(), ["s1", "s2", "s3"]);
  assert.deepEqual(store.sessionCosts(NOW - 30 * DAY, "g1").map((c) => c.session).sort(), ["s1", "s2"]);
});

// The findings breakdown: two tasks with their documents (status, fixedIn), one that's gone (only its
// stats rows), one outside the window and one of another goal.
const fnd = (id: string, kind: string, severity: string, file: string | null, raisedIn: number, status = "open", fixedIn: number | null = null) =>
  ({ id, kind, severity, text: `${id} text`, file, raisedIn, status, fixedIn });
const reviewed = (rounds: [number, number][], findings: unknown[]) =>
  ({ maxRounds: 5, summary: "", ask: [], proofs: [], findings, rounds: rounds.map(([number, at]) => ({ number, verdict: "changesRequested", found: 0, at, fix: null })) });
const fTasks = [
  task("F-1", {
    title: "Stats view", agent: "claude",
    autoReview: reviewed([[1, NOW - 3 * DAY], [2, NOW - 2 * DAY], [3, NOW - DAY]], [
      fnd("R1.1", "code", "major", "server/src/factory/stats.ts:120", 1, "fixed", 2),
      fnd("R1.2", "code", "major", "server/src/factory/engine.ts", 1, "fixed", 3),
      fnd("R1.3", "proof", "blocker", null, 1, "disputed"),
      fnd("R2.1", "code", "minor", "README.md", 2),
    ]),
  }),
  task("F-2", {
    title: "Mac view", agent: "codex",
    autoReview: reviewed([[1, NOW - 12 * H]], [fnd("R1.1", "code", "major", "apps/mac/Sources/MapleFactory/Stats/FindingsView.swift", 1, "fixed", 2)]),
  }),
  task("F-8", { goal: "g2", agent: "codex", autoReview: reviewed([[1, NOW - H]], [fnd("R1.1", "risk", "major", "server/src/x.ts", 1)]) }),
];
const fEvents: StatEvent[] = [
  ev("review.round", "F-1", 3 * DAY, { number: 1, verdict: "changesRequested", findings: [] }), // the document's findings win
  ev("review.round", "F-1", 2 * DAY, { number: 2, verdict: "changesRequested", findings: [] }),
  ev("review.round", "F-1", 1 * DAY, { number: 3, verdict: "passed", findings: [] }),
  ev("review.round", "F-2", 12 * H, { number: 1, verdict: "changesRequested", findings: [] }),
  // F-3 is gone: its rows are all there is, one from before file and text were kept.
  ev("review.round", "F-3", 4 * DAY, { number: 1, verdict: "changesRequested", findings: [{ kind: "code", severity: "major", file: "server/src/factory/stats.ts", text: "gone" }, { kind: "risk", severity: "minor" }] }),
  ev("review.round", "F-1", 40 * DAY, { number: 1, verdict: "changesRequested", findings: [{ kind: "scope", severity: "blocker", file: "old.ts", text: "old" }] }),
  ev("review.round", "F-8", H, { number: 1, verdict: "changesRequested", findings: [] }, "g2"),
];

test("findings breakdown: kind × severity, areas, outcomes, per agent, from documents and gone tasks' rows", () => {
  const f = summarize(fEvents, fTasks, { days: 30, now: NOW }).findings!;
  assert.deepEqual(f.matrix, [
    { kind: "code", severity: "major", count: 4 },
    { kind: "code", severity: "minor", count: 1 },
    { kind: "proof", severity: "blocker", count: 1 },
    { kind: "risk", severity: "major", count: 1 },
    { kind: "risk", severity: "minor", count: 1 },
  ]);
  assert.deepEqual(f.areas, [
    { key: "server/src", count: 4, tasks: 3, serious: 4 },
    { key: "(no file)", count: 2, tasks: 2, serious: 1 },
    { key: "(root)", count: 1, tasks: 1, serious: 0 },
    { key: "apps/mac", count: 1, tasks: 1, serious: 1 },
  ]);
  // Fixed a round later, two rounds later, and a round later: 1 is the middle.
  assert.deepEqual(f.outcomes, { fixed: 3, disputed: 1, open: 2, unknown: 2, roundsToFixMedian: 1 });
  assert.deepEqual(f.byAgent, [
    { agent: "claude", rounds: 3, findings: 4, serious: 3, perRound: 1.33 },
    { agent: "codex", rounds: 2, findings: 2, serious: 2, perRound: 1 },
    { agent: "unknown", rounds: 1, findings: 2, serious: 1, perRound: 2 },
  ]);
  // Newest round first; a gone task's row keeps its text and file but has no status.
  assert.deepEqual(f.recent.map((r) => `${r.task} R${r.raisedIn} ${r.kind}/${r.severity}`), [
    "F-8 R1 risk/major", "F-2 R1 code/major", "F-1 R2 code/minor", "F-1 R1 code/major", "F-1 R1 code/major", "F-1 R1 proof/blocker", "F-3 R1 code/major", "F-3 R1 risk/minor",
  ]);
  assert.deepEqual(f.recent[1], {
    task: "F-2", title: "Mac view", kind: "code", severity: "major", text: "R1.1 text", file: "apps/mac/Sources/MapleFactory/Stats/FindingsView.swift",
    area: "apps/mac", status: "fixed", raisedIn: 1, at: NOW - 12 * H,
  });
  const gone = f.recent.find((r) => r.task === "F-3")!;
  assert.deepEqual([gone.title, gone.text, gone.file, gone.area, gone.status], ["F-3", "gone", "server/src/factory/stats.ts", "server/src", null]);
  assert.deepEqual([f.recent.at(-1)!.text, f.recent.at(-1)!.area], ["", "(no file)"]);
});

test("findings breakdown follows the window and the goal, and caps the list at 60", () => {
  const week = summarize(fEvents, fTasks, { days: 2, now: NOW }).findings!;
  assert.deepEqual(week.recent.map((r) => r.task), ["F-8", "F-2", "F-1"]);
  const g2 = summarize(fEvents, fTasks, { days: 30, now: NOW, goal: "g2" }).findings!;
  assert.deepEqual(g2.matrix, [{ kind: "risk", severity: "major", count: 1 }]);
  assert.deepEqual(g2.byAgent.map((a) => a.agent), ["codex"]);

  const many = Array.from({ length: 70 }, (_, i) => ev("review.round", `M-${i}`, (i + 1) * H, { number: 1, verdict: "changesRequested", findings: [{ kind: "code", severity: "minor", file: "a.ts", text: String(i) }] }));
  const capped = summarize(many, [], { days: 30, now: NOW }).findings!;
  assert.equal(capped.recent.length, 60);
  assert.deepEqual([capped.recent[0].text, capped.recent[59].text], ["0", "59"]);
  assert.deepEqual(capped.areas, [{ key: "(root)", count: 70, tasks: 70, serious: 0 }]);
  assert.deepEqual(capped.outcomes, { fixed: 0, disputed: 0, open: 0, unknown: 70, roundsToFixMedian: null });
});

test("a finding's area is its first two folders; its stats row trims long text", () => {
  assert.equal(findingArea("server/src/factory/stats.ts:12-20"), "server/src");
  assert.equal(findingArea("./apps/mac/Package.swift"), "apps/mac");
  assert.equal(findingArea("runner/Cargo.toml"), "runner");
  assert.equal(findingArea("README.md"), "(root)");
  assert.equal(findingArea(""), "(no file)");
  assert.equal(findingArea(null), "(no file)");
  const long = findingDetail(fnd("R1.1", "code", "major", "a/b.ts", 1) as never);
  assert.deepEqual(long, { kind: "code", severity: "major", file: "a/b.ts", text: "R1.1 text" });
  const trimmed = findingDetail({ ...fnd("R1.1", "code", "major", null, 1), text: "x".repeat(500) } as never);
  assert.equal(trimmed.text!.length, 200);
  assert.ok(trimmed.text!.endsWith("…"));
  assert.equal(trimmed.file, null);
});

test("manualReason: the factory's own merge is none; then auto-merge off, classifier, risk, held, GitHub, merged first", () => {
  const on = { autoMerge: true, humanReview: false };
  assert.equal(manualReason({ autoMerge: false, humanReview: true }, { autoMerges: false }, { by: "factory", held: true }), null);
  assert.equal(manualReason({ autoMerge: false, humanReview: true }, { autoMerges: false }, { by: "ann", held: true }), "autoMergeOff");
  assert.equal(manualReason({ autoMerge: false, humanReview: true }, {}, { by: "ann", held: true }), "classifier");
  assert.equal(manualReason({ autoMerge: false, humanReview: false }, {}, { by: null, held: true }), "risk");
  assert.equal(manualReason(on, {}, { by: null, held: true }), "held");
  assert.equal(manualReason(on, {}, { by: null, held: false }), "github");
  assert.equal(manualReason(on, { autoMerges: true }, { by: "ann", held: false }), "mergedFirst");
});

test("merges by people: reasons, as is or after changes, and only steers in review and review requests count", () => {
  const who = (e: StatEvent, actor: string | null) => ({ ...e, actor });
  const rows: StatEvent[] = [
    ev("merged", "M-0", 2 * H, { auto: true, cycleMs: H }),
    who(ev("merged", "M-1", 3 * H, { auto: false, why: "autoMergeOff", level: "low" }), "ann"),
    who(ev("merged", "M-2", 4 * H, { auto: false, why: "risk", level: "medium" }), "ann"),
    who(ev("merged", "M-3", 5 * H, { auto: false, why: "classifier", level: "low" }), "bob"),
    who(ev("merged", "M-4", 6 * H, { auto: false, why: "held", level: "low", heldBy: "bob" }), "bob"),
    who(ev("merged", "M-5", 7 * H, { auto: false, why: "mergedFirst", level: "low" }), "ann"),
    ev("merged", "M-6", 8 * H, { auto: false, why: "github", level: "low" }),
    ev("merged", "M-7", 9 * H, { auto: false }), // before `why` was kept
    // M-2: a steer in review and a requested review → 2 changes; M-3: a steer while building doesn't count.
    ev("steer", "M-2", 5 * H, { state: "reviewing" }),
    ev("review.requested", "M-2", 6 * H, { round: 2 }),
    ev("steer", "M-3", 6 * H, { state: "building" }),
    // M-4's change request was 40 days ago, before the window: still counts.
    ev("steer", "M-4", 40 * DAY, { state: "reviewing" }),
  ];
  const s = summarize(rows, [task("M-2", { title: "Medium one" })], { days: 7, now: NOW });
  const m = s.manualMerges!;
  assert.equal(s.totals.merged, 8);
  assert.equal(s.totals.autoMerged, 1);
  assert.equal(m.total, 7);
  assert.equal(m.withChanges, 2);
  assert.equal(m.asIs, 5);
  assert.deepEqual(m.byReason.map((c) => [c.key, c.count]).sort(), [
    ["autoMergeOff", 1], ["classifier", 1], ["github", 1], ["held", 1], ["mergedFirst", 1], ["risk", 1], ["unknown", 1],
  ]);
  assert.deepEqual(m.recent.map((r) => r.task), ["M-1", "M-2", "M-3", "M-4", "M-5", "M-6", "M-7"]);
  assert.deepEqual(m.recent[1], { task: "M-2", title: "Medium one", at: NOW - 4 * H, by: "ann", reason: "risk", level: "medium", changes: 2 });
  assert.equal(m.recent[2].changes, 0);
  assert.equal(m.recent[3].changes, 1);
  assert.equal(m.recent[5].by, null);
  assert.equal(m.recent[6].reason, "unknown");
});

test("a backfilled merge a person made reads why: unknown; the factory's own has none", () => {
  const merged = (auto: boolean) => task("B-1", {
    state: "merged",
    events: [...(auto ? [{ at: NOW - H, who: "factory", text: "auto-merged" }] : []), { at: NOW - H, who: "factory", text: "merged into main" }],
  });
  assert.equal(inferEvents(merged(false)).find((e) => e.kind === "merged")!.detail.why, "unknown");
  assert.equal(inferEvents(merged(true)).find((e) => e.kind === "merged")!.detail.why, undefined);
});

test("the store hands summarize a merged task's earlier steers and review requests too", () => {
  const store = new Store(sqlStorage());
  const add = (kind: StatEvent["kind"], task: string, at: number) => store.recordStat({ at, kind, task, goal: "g1", role: null, actor: null, detail: {} });
  add("steer", "A-1", NOW - 40 * DAY);
  add("review.requested", "A-1", NOW - 40 * DAY);
  add("steer", "B-1", NOW - 40 * DAY);
  assert.deepEqual(store.statRoundsBefore(["A-1"], NOW - 30 * DAY).map((e) => e.kind), ["steer", "review.requested"]);
});

test("weekday × hour cells: UTC, New York across the DST change, Tokyo, and an unknown zone reads as UTC", () => {
  const now = Date.UTC(2026, 10, 3, 12); // Tue 3 Nov 2026
  const at = (iso: string) => Date.parse(iso);
  const mk = (kind: StatEvent["kind"], iso: string): StatEvent => ({ id: String(n++), at: at(iso), kind, task: "T-1", goal: "g1", role: null, actor: null, detail: {} });
  const list = [
    mk("merged", "2026-10-31T14:00:00Z"), // Sat 14 UTC · Sat 10 EDT · Sat 23 JST
    mk("merged", "2026-10-31T16:00:00Z"), // Sat 16 UTC · Sat 12 EDT · Sun 01 JST
    mk("merged", "2026-11-02T15:00:00Z"), // Mon 15 UTC · Mon 10 EST (after US clocks went back on 1 Nov) · Tue 00 JST
    mk("hand.raised", "2026-11-01T05:30:00Z"), // Sun 05 UTC · Sun 1:30 AM EDT · Sun 14 JST
    mk("hand.raised", "2026-11-01T06:30:00Z"), // Sun 06 UTC · Sun 1:30 AM EST, the second 1 AM once clocks went back · Sun 15 JST
  ];
  const cell = (s: ReturnType<typeof summarize>, weekday: number, hour: number) => s.hours!.find((c) => c.weekday === weekday && c.hour === hour)!;
  const nonZero = (s: ReturnType<typeof summarize>) => s.hours!.filter((c) => c.merges || c.hands).map((c) => `${c.weekday}:${c.hour}:${c.merges}/${c.hands}`).sort();

  const utc = summarize(list, [], { days: 7, now, tz: "UTC" });
  assert.equal(utc.timeZone, "UTC");
  assert.deepEqual(nonZero(utc), ["0:5:0/1", "0:6:0/1", "1:15:1/0", "6:14:1/0", "6:16:1/0"]);

  const ny = summarize(list, [], { days: 7, now, tz: "America/New_York" });
  assert.equal(ny.timeZone, "America/New_York");
  assert.equal(cell(ny, 6, 10).merges, 1); // EDT, UTC−4
  assert.equal(cell(ny, 6, 12).merges, 1);
  assert.equal(cell(ny, 1, 10).merges, 1); // EST, UTC−5: same local hour as Saturday's though five hours later in UTC
  assert.equal(cell(ny, 0, 1).hands, 2); // 05:30Z and 06:30Z are both 1:30 AM local, either side of the change

  const tokyo = summarize(list, [], { days: 7, now, tz: "Asia/Tokyo" });
  assert.deepEqual(nonZero(tokyo), ["0:14:0/1", "0:15:0/1", "0:1:1/0", "2:0:1/0", "6:23:1/0"]);

  for (const tz of ["Mars/Olympus", "", undefined, null]) {
    const s = summarize(list, [], { days: 7, now, tz });
    assert.equal(s.timeZone, "UTC");
    assert.deepEqual(nonZero(s), nonZero(utc));
  }

  for (const s of [utc, ny, tokyo]) {
    assert.equal(s.hours!.length, 168);
    assert.equal(new Set(s.hours!.map((c) => c.weekday * 24 + c.hour)).size, 168);
    assert.equal(s.hours!.reduce((a, c) => a + c.merges, 0), s.totals.merged);
    assert.equal(s.hours!.reduce((a, c) => a + c.hands, 0), s.totals.handsRaised);
  }
});

test("weekday × hour cells follow the window and add up to the 30-day totals", () => {
  const s = summarize(events, [], { days: 30, now: NOW, tz: "Asia/Tokyo" });
  assert.equal(s.hours!.length, 168);
  assert.equal(s.hours!.reduce((a, c) => a + c.merges, 0), s.totals.merged);
  assert.equal(s.hours!.reduce((a, c) => a + c.hands, 0), s.totals.handsRaised);
  const week = summarize([...events, ev("merged", "OLD", 40 * DAY, { cycleMs: 1 })], [], { days: 7, now: NOW });
  assert.equal(week.hours!.reduce((a, c) => a + c.merges, 0), week.totals.merged);
});

// MF-318: idle time (drafting + backlog) apart from the time the task was worked on.
test("idleMs totals drafting and backlog spans, an open one up to until, and skips terminal markers", async () => {
  const { idleMs } = await import("../src/factory/stages.ts");
  const t0 = NOW - 20 * H;
  const spans = [
    { stage: "drafting", from: t0, to: t0 + 12 * H },
    { stage: "planning", from: t0 + 12 * H, to: t0 + 13 * H },
    { stage: "backlog", from: t0 + 13 * H, to: t0 + 15 * H },
    { stage: "building", from: t0 + 15 * H, to: t0 + 16 * H },
    { stage: "merged", from: t0 + 16 * H, to: t0 + 16 * H },
  ] as never[];
  assert.equal(idleMs(spans, NOW), 14 * H);
  // An open backlog span counts up to until; one past until is clipped to it.
  assert.equal(idleMs([{ stage: "drafting", from: t0, to: null }] as never[], t0 + 3 * H), 3 * H);
  assert.equal(idleMs([{ stage: "backlog", from: t0, to: t0 + 5 * H }] as never[], t0 + 2 * H), 2 * H);
  assert.equal(idleMs([], NOW), 0);
});

test("a merge 12h in drafting and 2h worked on records idleMs 12h and activeMs 2h, live and backfilled", async () => {
  const { cycleSplit } = await import("../src/factory/stats.ts");
  const created = NOW - 14 * H;
  const stages = [
    { stage: "drafting", from: created, to: created + 12 * H },
    { stage: "planning", from: created + 12 * H, to: created + 12.5 * H },
    { stage: "awaitingApproval", from: created + 12.5 * H, to: created + 12.6 * H },
    { stage: "building", from: created + 12.6 * H, to: created + 13.5 * H },
    { stage: "reviewing", from: created + 13.5 * H, to: null },
  ];
  // Live: the engine records it while the task's still in review, its reviewing span open.
  const live = task("I-1", { createdAt: created, stages });
  assert.deepEqual(cycleSplit(live, NOW), { cycleMs: 14 * H, idleMs: 12 * H, activeMs: 2 * H });
  // Backfilled, from its stage spans…
  const merged = task("I-1", { createdAt: created, state: "merged", updatedAt: NOW, stages: [...stages.slice(0, 4), { stage: "reviewing", from: created + 13.5 * H, to: NOW }, { stage: "merged", from: NOW, to: NOW }],
    events: [{ at: NOW, who: "factory", text: "merged into main" }] });
  const row = inferEvents(merged).find((e) => e.kind === "merged")!;
  assert.equal(row.detail.idleMs, 12 * H);
  assert.equal(row.detail.activeMs, 2 * H);
  assert.equal(row.detail.cycleMs, 14 * H);
  // …and from its events when it has no spans (inferStages: drafting until it went to planning).
  const old = task("I-2", { createdAt: created, state: "merged", updatedAt: NOW, events: [
    { at: created + 12 * H, who: "me", text: "sent it to planning" },
    { at: created + 12.5 * H, who: "planner", text: "wrote the plan" },
    { at: created + 12.6 * H, who: "me", text: "approved the plan" },
    { at: NOW, who: "factory", text: "merged into main" },
  ] });
  const oldRow = inferEvents(old).find((e) => e.kind === "merged")!;
  assert.equal(oldRow.detail.idleMs, 12 * H);
  assert.equal(oldRow.detail.activeMs, 2 * H);
});

test("summarize: active and idle medians over merges that carry the split; cycle median unchanged; old rows skipped", () => {
  const rows = [
    ev("merged", "S-1", H, { auto: true, cycleMs: 14 * H, idleMs: 12 * H, activeMs: 2 * H }, "g1"),
    ev("merged", "S-2", 2 * H, { auto: true, cycleMs: 6 * H, idleMs: 2 * H, activeMs: 4 * H }, "g1"),
    ev("merged", "S-3", 3 * H, { auto: true, cycleMs: 10 * H, idleMs: 0, activeMs: 10 * H }, "g1"),
    ev("merged", "S-4", 4 * H, { auto: false, cycleMs: 40 * H }, "g1"), // from before MF-318: no split
  ];
  const s = summarize(rows, [], { days: 7, now: NOW });
  assert.equal(s.totals.cycleMedianMs, 12 * H); // median of 6, 10, 14, 40
  assert.equal(s.totals.activeCycleMedianMs, 4 * H);
  assert.equal(s.totals.idleMedianMs, 2 * H);
  const g = s.goals.find((r) => r.goal === "g1")!;
  assert.equal(g.cycleMedianMs, 12 * H);
  assert.equal(g.activeCycleMedianMs, 4 * H);
  assert.equal(g.idleMedianMs, 2 * H);
  // Only old rows: no split medians, cycle median as before.
  const before = summarize([rows[3]], [], { days: 7, now: NOW });
  assert.equal(before.totals.cycleMedianMs, 40 * H);
  assert.equal(before.totals.activeCycleMedianMs, null);
  assert.equal(before.totals.idleMedianMs, null);
});

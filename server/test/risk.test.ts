// The web task page's Risk card: level, why, budget, sign-off, acceptance and the classifier's grade.
import { test } from "node:test";
import assert from "node:assert/strict";
import { riskBadge, riskDetails } from "../web/app/risk.js";

const policy = {
  maxFiles: 12, maxLines: 400, areas: [],
  planApprovals: { low: 0, medium: 1, high: 2 },
  finalReviews: { low: 0, medium: 1, high: 2 },
  autoMerge: { low: true, medium: false, high: false },
};
const task = (over: Record<string, unknown> = {}) => ({
  id: "MF-1", goal: "g1", approvals: [], approvalsNeeded: 1, reviews: [], reviewsNeeded: 1,
  risk: { level: "medium", reasons: ["touches auth"], areas: ["auth"] }, ...over,
});

test("the badge has a label and class per level", () => {
  assert.deepEqual(riskBadge("high"), { label: "High risk", class: "risk-pill risk-high" });
  assert.equal(riskBadge("low").label, "Low risk");
});

test("factors come before the planner's fallback", () => {
  const factors = [{ source: "check", label: "Auth", level: "medium" }];
  const withFactors = riskDetails(task({ risk: { level: "medium", reasons: ["x"], areas: [], factors } }), policy, []);
  assert.deepEqual(withFactors.factors, factors);
  assert.equal(withFactors.fallback, null);
  const without = riskDetails(task(), policy, []);
  assert.deepEqual(without.factors, []);
  assert.deepEqual(without.fallback, { areas: ["auth"], reasons: ["touches auth"] });
});

test("the diff wins over the footprint, which is marked estimated", () => {
  const diffed = riskDetails(task({ diff: { added: 150, removed: 30, files: ["a", "b", "c", "d"] }, footprint: { files: 9, lines: 900, estimated: true } }), policy, []);
  assert.deepEqual(diffed.budget, { files: { used: 4, max: 12, over: false }, lines: { used: 180, max: 400, over: false }, estimated: false, over: false });
  const planned = riskDetails(task({ footprint: { files: 3, lines: 120, estimated: true } }), policy, []);
  assert.equal(planned.budget.estimated, true);
  assert.equal(planned.budget.lines.used, 120);
});

test("going over the budget flags it", () => {
  const d = riskDetails(task({ diff: { added: 500, removed: 10, files: ["a"] } }), policy, []);
  assert.equal(d.budget.lines.over, true);
  assert.equal(d.budget.files.over, false);
  assert.equal(d.budget.over, true);
});

test("sign-off is read for the task's level", () => {
  const high = riskDetails(task({ risk: { level: "high", reasons: [], areas: [] }, approvals: ["ana"], approvalsNeeded: 2, reviewsNeeded: 2 }), policy, []);
  assert.deepEqual(high.signOff.planApprovals, { needed: 2, policy: 2, have: 1 });
  assert.deepEqual(high.signOff.finalReviews, { needed: 2, policy: 2, have: 0 });
  assert.deepEqual(high.signOff.autoMerge, { on: false, label: "Off at this level" });
  const low = riskDetails(task({ risk: { level: "low", reasons: [], areas: [] } }), policy, []);
  assert.deepEqual(low.signOff.autoMerge, { on: true, label: "On" });
});

test("auto-merge is off for the factory when autoMerges is false", () => {
  const d = riskDetails(task({ risk: { level: "low", reasons: [], areas: [] } }), { ...policy, autoMerges: false }, []);
  assert.deepEqual(d.signOff.autoMerge, { on: false, label: "Off for the factory" });
});

test("the goal's acceptance is found by goal", () => {
  const d = riskDetails(task(), policy, [{ goal: "other", upTo: "high", by: "x", at: 1 }, { goal: "g1", upTo: "medium", by: "ana", at: 1 }]);
  assert.deepEqual(d.acceptance, { upTo: "medium", by: "ana", note: null });
  assert.equal(riskDetails(task(), policy, []).acceptance, null);
});

test("a classifier asking for a person gives the note", () => {
  const d = riskDetails(task({ classification: { level: "high", humanReview: true, reasons: ["payments"], round: 1, at: 1 } }), policy, []);
  assert.deepEqual(d.classifier, { level: "high", humanReview: true, note: "Asks for a person to review", reasons: ["payments"] });
  const quiet = riskDetails(task({ classification: { level: "low", humanReview: false, reasons: [], round: 1, at: 1 } }), policy, []);
  assert.equal(quiet.classifier.note, null);
  assert.equal(riskDetails(task(), policy, []).classifier, null);
});

test("an old server (no policy, no factors) still gives the level and reasons", () => {
  const d = riskDetails({ id: "MF-2", risk: { level: "low", reasons: ["small"] } }, null, undefined);
  assert.equal(d.level, "low");
  assert.deepEqual(d.fallback, { areas: [], reasons: ["small"] });
  assert.equal(d.budget, null);
  assert.equal(d.signOff, null);
  assert.equal(d.acceptance, null);
  assert.equal(d.classifier, null);
  assert.equal(riskDetails({ id: "MF-3" }, policy, []), null);
});

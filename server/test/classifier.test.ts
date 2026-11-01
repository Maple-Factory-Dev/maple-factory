// The optional risk classifier (policy.classifier): the reviewer grades the built change against the org's
// prompt, and assess() takes that grade as a "classifier" factor. It can only add gates: it raises the level,
// and humanReview makes at least one final review required and turns auto-merge off. A "no" never lowers anything.
import { test } from "node:test";
import assert from "node:assert/strict";
import { DEFAULT_POLICY, assess, validPolicy } from "../src/factory/policy.ts";
import { reviewerPrompt } from "../src/factory/prompts.ts";
import type { Classification, RiskPolicy, Task } from "../src/wire.ts";

const PROMPT = "Anything touching payments or user data needs a person.";
const policy = (p: Partial<RiskPolicy> = {}): RiskPolicy => ({ ...structuredClone(DEFAULT_POLICY), ...p });
const on = (p: Partial<RiskPolicy> = {}) => policy({ classifier: { enabled: true, prompt: PROMPT }, ...p });
const grade = (c: Partial<Classification> = {}): Classification => ({ level: "high", humanReview: true, reasons: ["Touches the refunds flow"], round: 1, at: 1, ...c });

function task(classification: Classification | null = null): Task {
  return {
    id: "MF-1", goal: "g", title: "t", state: "reviewing", owner: "me", brief: "b", createdAt: 0, updatedAt: 0,
    plan: [], planVersion: 1, doneWhen: [], approvals: [], approvalsNeeded: 1, reviews: [], reviewsNeeded: 0,
    comments: [], changes: [], events: [], mockups: [], artifacts: [], tickets: [], shareable: false, agent: "claude",
    after: [], followUps: [],
    risk: { level: "low", reasons: ["Small copy change"], areas: [], factors: null },
    diff: { added: 4, removed: 1, files: ["src/copy.ts"] },
    classification,
  } as unknown as Task;
}

test("a low-risk task the classifier grades high with humanReview becomes high, needs a review and doesn't auto-merge", () => {
  const before = assess(task(), on(), undefined);
  assert.equal(before.level, "low");
  assert.equal(before.reviews, 0);
  assert.equal(before.autoMerge, true);
  const a = assess(task(grade()), on(), undefined);
  assert.equal(a.level, "high");
  assert.ok(a.reviews >= 1);
  assert.equal(a.autoMerge, false);
  const f = a.factors.find((x) => x.source === "classifier");
  assert.ok(f);
  assert.equal(f.level, "high");
  assert.equal(f.detail, "Touches the refunds flow");
  assert.equal(a.factors[0].source, "classifier", "highest first");
});

test("humanReview on a low grade still forces one review and no auto-merge, even with zero reviews in the policy", () => {
  const a = assess(task(grade({ level: "low" })), on({ finalReviews: { low: 0, medium: 0, high: 0 } }), undefined);
  assert.equal(a.level, "low");
  assert.equal(a.reviews, 1);
  assert.equal(a.autoMerge, false);
});

test("humanReview beats a goal's risk acceptance", () => {
  const acceptance = { goal: "g", upTo: "high", by: "me", at: 1, note: null } as never;
  const accepted = assess(task(), on(), acceptance);
  assert.equal(accepted.accepted, true);
  assert.equal(accepted.reviews, 0);
  const a = assess(task(grade()), on(), acceptance);
  assert.equal(a.accepted, false);
  assert.ok(a.reviews >= 1);
  assert.equal(a.autoMerge, false);
});

test("a 'no review needed' grade never lowers what the policy asks for", () => {
  const high = { ...task(grade({ level: "low", humanReview: false })), diff: { added: 900, removed: 0, files: ["src/copy.ts"] } } as Task;
  const without = assess({ ...high, classification: null } as Task, on(), undefined);
  const a = assess(high, on(), undefined);
  assert.equal(a.level, without.level);
  assert.equal(a.reviews, without.reviews);
  assert.equal(a.autoMerge, without.autoMerge);
  assert.equal(a.approvals, without.approvals);
  // Low with no review asked: nothing changes for a low task either.
  const low = assess(task(grade({ level: "low", humanReview: false })), on(), undefined);
  const plain = assess(task(), on(), undefined);
  assert.deepEqual({ ...low, factors: low.factors.filter((f) => f.source !== "classifier") }, plain);
});

test("with the classifier off, a stored grade changes nothing", () => {
  for (const p of [policy(), policy({ classifier: { enabled: false, prompt: PROMPT } })]) {
    assert.deepEqual(assess(task(grade()), p, undefined), assess(task(), p, undefined));
  }
});

test("validPolicy asks for a prompt when the classifier is on", () => {
  assert.match(validPolicy(policy({ classifier: { enabled: true, prompt: "  " } })) ?? "", /prompt/);
  assert.equal(validPolicy(policy({ classifier: { enabled: false, prompt: "" } })), null);
  assert.equal(validPolicy(on()), null);
  assert.equal(validPolicy(policy()), null);
});

test("the reviewer prompt has a Risk classification section only when the classifier is on", () => {
  const t = { ...task(), autoReview: { maxRounds: 3, rounds: [], summary: "", ask: [], proofs: [], findings: [] } } as Task;
  const with_ = reviewerPrompt(t, null, "main", null, null, null, on().classifier!);
  assert.match(with_, /## Risk classification/);
  assert.ok(with_.includes(PROMPT));
  assert.match(with_, /classification/);
  assert.doesNotMatch(reviewerPrompt(t, null, "main"), /Risk classification/);
  assert.doesNotMatch(reviewerPrompt(t, null, "main", null, null, null, { enabled: false, prompt: PROMPT }), /Risk classification/);
});

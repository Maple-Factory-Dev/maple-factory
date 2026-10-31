// The web Settings page's helpers (web/app/settings.js): the Merging & risk form round-trips a policy and
// clamps what the server would refuse, approved GitHub accounts parse from what an admin types, and a
// form's draft follows another admin's save only while nobody has touched it.
import { test } from "node:test";
import assert from "node:assert/strict";
import { DEFAULT_POLICY, validPolicy } from "../src/factory/policy.ts";
import { clampInt, cleanOwners, formFromPolicy, isDirty, policyFromForm, syncDraft } from "../web/app/settings.js";

const policy = structuredClone(DEFAULT_POLICY);

test("a policy goes through the form and back unchanged", () => {
  assert.deepEqual(policyFromForm(formFromPolicy(policy), policy), policy);
});

test("the form's changes land in the policy, and the sensitive areas it doesn't show are kept", () => {
  const form = formFromPolicy(policy);
  form.autoMerge.medium = true;
  form.autoMerges = false;
  form.planApprovals.high = 3;
  form.maxLines = 800;
  const saved = policyFromForm(form, policy);
  assert.equal(saved.autoMerge.medium, true);
  assert.equal(saved.autoMerges, false);
  assert.equal(saved.planApprovals.high, 3);
  assert.equal(saved.maxLines, 800);
  assert.deepEqual(saved.areas, policy.areas);
  assert.equal(validPolicy(saved), null);
});

test("numbers are clamped to what the server takes; blank or unreadable ones keep the saved value", () => {
  const form = formFromPolicy(policy);
  Object.assign(form, { scoutItems: 40, maxFiles: 0, maxLines: -5 });
  form.planApprovals.low = -2;
  form.finalReviews.high = 2.6;
  form.finalReviews.medium = "";
  form.planApprovals.medium = NaN;
  const saved = policyFromForm(form, policy);
  assert.equal(saved.scoutItems, 10);
  assert.equal(saved.maxFiles, 1);
  assert.equal(saved.maxLines, 1);
  assert.equal(saved.planApprovals.low, 0);
  assert.equal(saved.finalReviews.high, 3);
  assert.equal(saved.finalReviews.medium, policy.finalReviews.medium);
  assert.equal(saved.planApprovals.medium, policy.planApprovals.medium);
  assert.equal(validPolicy(saved), null);
  assert.equal(policyFromForm({ ...formFromPolicy(policy), scoutItems: 0 }, policy).scoutItems, 1);
  assert.equal(clampInt("7", 1, 10, 3), 7);
  assert.equal(clampInt(null, 1, 10, 3), 3);
});

test("a policy from an older server, without the newer switches, reads as on and 3 Scout items", () => {
  const old = { ...policy, autoMerges: undefined, autoFixMerges: null, scoutItems: undefined };
  const form = formFromPolicy(old);
  assert.equal(form.autoMerges, true);
  assert.equal(form.autoFixMerges, true);
  assert.equal(form.scoutItems, 3);
  assert.equal(validPolicy(policyFromForm(form, old)), null);
});

test("owners parse from commas, spaces, @ and GitHub links, once each, without the factory's own org", () => {
  assert.deepEqual(cleanOwners("a, @b, https://github.com/c"), ["a", "b", "c"]);
  assert.deepEqual(cleanOwners(" a\n@A  https://github.com/d/ , ,"), ["a", "d"]);
  assert.deepEqual(cleanOwners("acme, Other", "ACME"), ["Other"]);
  assert.deepEqual(cleanOwners(""), []);
  assert.deepEqual(cleanOwners(undefined), []);
});

test("a new draft starts from the server's value and isn't dirty", () => {
  const d = syncDraft(undefined, { planner: "p", builder: "", reviewer: "" });
  assert.equal(isDirty(d), false);
  d.value.planner = "edited";
  assert.equal(isDirty(d), true);
});

test("another admin's save resets a form nobody touched", () => {
  const d = syncDraft(undefined, { planner: "old", builder: "", reviewer: "" });
  const next = syncDraft(d, { planner: "theirs", builder: "", reviewer: "" });
  assert.equal(next.value.planner, "theirs");
  assert.equal(isDirty(next), false);
});

test("another admin's save leaves edits in progress alone, still dirty against the new value", () => {
  const d = syncDraft(undefined, { planner: "old", builder: "", reviewer: "" });
  d.value.builder = "mine";
  const next = syncDraft(d, { planner: "theirs", builder: "", reviewer: "" });
  assert.deepEqual(next.value, { planner: "old", builder: "mine", reviewer: "" });
  assert.equal(isDirty(next), true);
});

test("our own save coming back makes the form clean, and the draft isn't shared with the server's copy", () => {
  const server = { planner: "old", builder: "", reviewer: "" };
  const d = syncDraft(undefined, server);
  d.value.planner = "new";
  assert.equal(server.planner, "old");
  const echoed = syncDraft(d, { planner: "new", builder: "", reviewer: "" });
  assert.equal(isDirty(echoed), false);
  assert.equal(syncDraft(echoed, { planner: "new", builder: "", reviewer: "" }), echoed);
});

test("the policy form's draft: an untouched one follows policy.updated, an edited one doesn't", () => {
  const theirs = { ...policy, autoMerge: { ...policy.autoMerge, low: false } };
  const untouched = syncDraft(syncDraft(undefined, formFromPolicy(policy)), formFromPolicy(theirs));
  assert.equal(untouched.value.autoMerge.low, false);
  const edited = syncDraft(undefined, formFromPolicy(policy));
  edited.value.maxFiles = 30;
  const kept = syncDraft(edited, formFromPolicy(theirs));
  assert.equal(kept.value.maxFiles, 30);
  assert.equal(kept.value.autoMerge.low, true);
  assert.equal(isDirty(kept), true);
});

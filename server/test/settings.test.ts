// The web Settings page's helpers (web/app/settings.js): the Merging & risk form round-trips a policy and
// clamps what the server would refuse, approved GitHub accounts parse from what an admin types, and a
// form's draft follows another admin's save only while nobody has touched it; an integration's status reads
// as the Mac app's, and its save keeps stored secrets and leaves the env vars' values out.
import { test } from "node:test";
import assert from "node:assert/strict";
import { DEFAULT_POLICY, validPolicy } from "../src/factory/policy.ts";
import { clampInt, cleanOwners, formFromPolicy, integrationForm, integrationSave, integrationStatus, isDirty, keptValues, policyFromForm, syncDraft, webhookUrl } from "../web/app/settings.js";

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

const linear = {
  kind: "linear",
  label: "Linear",
  fields: [
    { name: "webhookSecret", label: "Webhook signing secret", secret: true, required: true, help: "" },
    { name: "apiKey", label: "API key", secret: true, required: false, help: "" },
    { name: "label", label: "Label", secret: false, required: false, help: "" },
  ],
  enabled: true,
  values: { webhookSecret: "", apiKey: "", label: "maple" },
  fromEnv: ["apiKey"],
  webhookUrl: "/integrations/linear",
  lastEventAt: null,
  lastError: null,
  updatedBy: "andrea",
  updatedAt: 1,
};
const ago = (ms: number) => `at ${ms}`;

test("an integration's status: an error first, then connected, off or not set up", () => {
  assert.deepEqual(integrationStatus({ ...linear, lastError: "Linear refused the bot's comment (401)" }, ago), { tone: "error", text: "Error: Linear refused the bot's comment (401)" });
  assert.deepEqual(integrationStatus({ ...linear, lastEventAt: 5 }, ago), { tone: "muted", text: "Connected · last event at 5" });
  assert.deepEqual(integrationStatus(linear, ago), { tone: "muted", text: "Connected · no events yet" });
  assert.deepEqual(integrationStatus({ ...linear, enabled: false }, ago), { tone: "muted", text: "Off" });
  assert.deepEqual(integrationStatus({ ...linear, enabled: false, updatedBy: null, values: {} }, ago), { tone: "faint", text: "Not set up" });
});

test("the kept values leave out the ones the env vars give", () => {
  assert.deepEqual(keptValues(linear), { webhookSecret: "", label: "maple" });
  assert.deepEqual(keptValues({ ...linear, fromEnv: [] }), linear.values);
});

test("a save sends a blank secret, so the stored one is kept, and the edited plain fields", () => {
  const form = integrationForm(linear);
  assert.deepEqual(form, { webhookSecret: "", apiKey: "", label: "maple" });
  form.label = "factory";
  const msg = integrationSave(linear, form, true);
  assert.deepEqual(msg, { type: "integrations.save", kind: "linear", enabled: true, values: { webhookSecret: "", apiKey: "", label: "factory" } });
  // A new secret goes through; the env var's API key isn't copied into Settings.
  assert.equal(integrationSave(linear, { ...form, webhookSecret: "whsec" }, true).values.webhookSecret, "whsec");
  assert.deepEqual(integrationSave(linear, {}, false), { type: "integrations.save", kind: "linear", enabled: false, values: { webhookSecret: "", label: "maple" } });
});

test("the webhook URL: on this server when it's a path, as given when it's whole, Jira's with its secret", () => {
  assert.equal(webhookUrl(linear, "https://maple.example.com/"), "https://maple.example.com/integrations/linear");
  assert.equal(webhookUrl({ ...linear, webhookUrl: "https://factory.acme.dev/integrations/linear" }, "http://localhost:8788"), "https://factory.acme.dev/integrations/linear");
  assert.equal(webhookUrl({ ...linear, kind: "jira", webhookUrl: "/integrations/jira" }, "http://localhost:8788"), "http://localhost:8788/integrations/jira?secret=<webhook secret>");
});

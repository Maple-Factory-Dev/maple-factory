// The web Settings page's helpers (web/app/settings.js): the Merging & risk form round-trips a policy and
// clamps what the server would refuse, approved GitHub accounts parse from what an admin types, and a
// form's draft follows another admin's save only while nobody has touched it; an integration's status reads
// as the Mac app's, and its save keeps stored secrets and leaves the env vars' values out. And how the
// policy's risk checks, size budget and a goal's acceptance give a change its level, with a factor for each.
import { test } from "node:test";
import assert from "node:assert/strict";
import type { RiskPolicy, Task } from "../src/wire.ts";
import { DEFAULT_POLICY, assess, matchesGlob, validPolicy } from "../src/factory/policy.ts";
import { plannerPrompt } from "../src/factory/prompts.ts";
import { areaFromCheck, checksProblem, clampInt, cleanOwners, formFromPolicy, iconFileProblem, integrationForm, integrationSave, integrationStatus, isDirty, keptValues, policyFromForm, serverVersionInfo, syncDraft, webhookUrl } from "../web/app/settings.js";

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
  assert.equal(form.overBudget, "ask");
  form.overBudget = "handOff";
  const saved = policyFromForm(form, policy);
  assert.equal(saved.overBudget, "handOff");
  assert.equal(formFromPolicy(saved).overBudget, "handOff");
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

// ---- risk checks ----

function task(f: Partial<Task> = {}): Task {
  return {
    id: "T-1", goal: "g", title: "A change", state: "reviewing", owner: "me", brief: "Change it", createdAt: 1, updatedAt: 1, plan: [], planVersion: 1, doneWhen: [],
    approvals: [], approvalsNeeded: 1, reviews: [], reviewsNeeded: 1, comments: [], changes: [], events: [], mockups: [], tickets: [],
    shareable: false, agent: "claude", after: [], followUps: [], risk: { level: "low", reasons: ["A small fix"], areas: [] }, ...f,
  } as Task;
}
const withApi: RiskPolicy = { ...policy, areas: [...policy.areas, { name: "Public API", paths: [], rule: "Changes the public HTTP API", level: "high", enabled: true }] };

test("globs: ** spans folders, * stays in one, a bare folder covers what's under it", () => {
  assert.ok(matchesGlob("db/migrations/x.sql", "db/migrations/**"));
  assert.ok(matchesGlob("src/a/b.ts", "**/*.ts"));
  assert.ok(matchesGlob("b.ts", "**/*.ts"));
  assert.ok(matchesGlob("app/models/user.rb", "app/models"));
  assert.ok(!matchesGlob("app/b/a.rb", "app/*.rb"));
  assert.ok(!matchesGlob("lib/authz/x.ts", "lib/auth/**"));
});

test("a diff touching db/migrations raises a planner-low task to medium, naming the Migrations check and the file", () => {
  const a = assess(task({ diff: { added: 10, removed: 2, files: ["db/migrations/x.sql", "src/app.ts"] } }), policy, undefined);
  assert.equal(a.level, "medium");
  assert.deepEqual(a.areas, ["Migrations"]);
  const check = a.factors.find((f) => f.source === "check");
  assert.deepEqual(check, { source: "check", label: "Migrations", level: "medium", detail: null, files: ["db/migrations/x.sql"] });
  // Highest first, and the planner's own read is still there.
  assert.equal(a.factors[0].label, "Migrations");
  assert.deepEqual(a.factors.find((f) => f.source === "planner"), { source: "planner", label: "The planner's read", level: "low", detail: "A small fix", files: null });
});

test("a path check the planner named counts before there's a diff, and goes by the files once there is", () => {
  const named = task({ risk: { level: "low", reasons: [], areas: ["auth"] }, footprint: { files: 2, lines: 30, estimated: true } });
  assert.equal(assess(named, policy, undefined).level, "high");
  assert.equal(assess({ ...named, diff: { added: 5, removed: 0, files: ["src/app.ts"] } }, policy, undefined).level, "low");
});

test("a rule check the planner cites raises the level, with the rule as its detail", () => {
  const t = task({ risk: { level: "low", reasons: ["Adds GET /v1/users"], areas: ["Public API"] }, diff: { added: 20, removed: 0, files: ["src/routes.ts"] } });
  const a = assess(t, withApi, undefined);
  assert.equal(a.level, "high");
  assert.deepEqual(a.factors[0], { source: "check", label: "Public API", level: "high", detail: "Changes the public HTTP API", files: null });
  assert.equal(assess(t, { ...withApi, areas: withApi.areas.map((x) => ({ ...x, enabled: false })) }, undefined).level, "low");
});

test("the size budget is a factor: within it low, over it medium", () => {
  const small = assess(task({ diff: { added: 10, removed: 5, files: ["a.ts"] } }), policy, undefined);
  assert.deepEqual(small.factors.find((f) => f.source === "size"), { source: "size", label: "1 file, 15 lines", level: "low", detail: "Within the PR budget of 12 files and 500 lines", files: null });
  const big = assess(task({ diff: { added: 600, removed: 0, files: ["a.ts", "b.ts"] } }), policy, undefined);
  assert.equal(big.level, "medium");
  assert.equal(big.factors.find((f) => f.source === "size")?.detail, "Over the PR budget of 12 files and 500 lines");
});

test("factors list the planner, each check, the size and the goal's acceptance; reassessing keeps the planner's own level", () => {
  const acceptance = { goal: "g", upTo: "medium" as const, by: "sam", at: 1 };
  const t = task({ diff: { added: 10, removed: 0, files: ["db/migrations/1.sql"] } });
  const a = assess(t, policy, acceptance);
  assert.deepEqual(a.factors.map((f) => f.source), ["check", "acceptance", "planner", "size"]);
  assert.equal(a.accepted, true);
  assert.equal(a.reviews, 0);
  assert.equal(a.factors.find((f) => f.source === "acceptance")?.detail, "Accepted by sam: no final review needed");
  // applyPolicy writes the raised level back; without the migration the planner's low comes back.
  const again = { ...t, risk: { ...t.risk!, level: a.level, factors: a.factors }, diff: { added: 10, removed: 0, files: ["src/a.ts"] } };
  assert.equal(assess(again, policy, undefined).level, "low");
});

test("validPolicy refuses a check without a name, with neither paths nor a rule, or named twice", () => {
  assert.equal(validPolicy(withApi), null);
  const one = (area: object) => validPolicy({ ...policy, areas: [...policy.areas, { name: "X", paths: [], level: "high", enabled: true, ...area }] });
  assert.equal(one({}), "Give X some paths or a rule.");
  assert.equal(one({ rule: "  " }), "Give X some paths or a rule.");
  assert.equal(one({ name: " " }), "Every risk check needs a name.");
  assert.equal(one({ name: "auth", paths: ["x/**"] }), "There are two risk checks named auth.");
});

test("the form's risk checks: a rule row saves its rule without paths, and the form says what the server would refuse", () => {
  const form = formFromPolicy(policy);
  form.checks.push({ name: "Public API", level: "high", enabled: true, kind: "rule", paths: "", rule: " Changes the public HTTP API " });
  const saved = policyFromForm(form, policy);
  assert.deepEqual(saved.areas.at(-1), { name: "Public API", paths: [], level: "high", enabled: true, rule: "Changes the public HTTP API" });
  assert.equal(validPolicy(saved), null);
  assert.deepEqual(policyFromForm(formFromPolicy(saved), saved), saved);
  assert.deepEqual(areaFromCheck({ name: "Docs", level: "low", enabled: true, kind: "paths", paths: "docs/**, README.md", rule: "" }).paths, ["docs/**", "README.md"]);
  assert.equal(checksProblem(form.checks), null);
  form.checks.push({ name: "", level: "low", enabled: true, kind: "rule", paths: "", rule: "" });
  assert.equal(checksProblem(form.checks), "Every risk check needs a name.");
  form.checks.at(-1).name = "Docs";
  assert.equal(checksProblem(form.checks), "Give Docs a rule.");
});

test("the planner's prompt lists the enabled risk checks, with their level and paths or rule", () => {
  const off = { ...withApi, areas: withApi.areas.map((a) => (a.name === "Billing" ? { ...a, enabled: false } : a)) };
  const p = plannerPrompt(task({ state: "planning", planVersion: 0 }), null, null, [], null, off.areas);
  assert.match(p, /## Risk checks\n/);
  assert.match(p, /- Public API \(high\): Changes the public HTTP API/);
  assert.match(p, /- Migrations \(medium\): touches db\/migrations\/\*\*/);
  assert.doesNotMatch(p, /Billing/);
  assert.doesNotMatch(p, /auth, payments, migrations and public APIs are high/);
});

test("the Version card reads up to date when there's no newer maple-server", () => {
  assert.deepEqual(serverVersionInfo("0.78.0", null), { version: "maple-server 0.78.0", status: "Up to date", update: null });
});

test("the Version card says a newer maple-server is out, and how this factory gets it", () => {
  const how = "Run `maple update` on the machine it was installed from.";
  assert.deepEqual(serverVersionInfo("0.78.0", { version: "0.79.0", how }),
    { version: "maple-server 0.78.0", status: "0.79.0 is out", update: { version: "0.79.0", how } });
});

test("the Version card reads unknown for a server too old to send its version", () => {
  const info = serverVersionInfo(null, null);
  assert.equal(info.version, "Unknown");
  assert.equal(info.update, null);
});

test("a policy can ask for 0 plan approvals and 0 final reviews at every risk level, but not fewer or none said", () => {
  const zero: RiskPolicy = { ...policy, planApprovals: { low: 0, medium: 0, high: 0 }, finalReviews: { low: 0, medium: 0, high: 0 } };
  assert.equal(validPolicy(zero), null);
  for (const level of ["low", "medium", "high"] as const) {
    assert.ok(validPolicy({ ...zero, planApprovals: { ...zero.planApprovals, [level]: -1 } }), `-1 ${level} approvals`);
    assert.ok(validPolicy({ ...zero, finalReviews: { ...zero.finalReviews, [level]: -1 } }), `-1 ${level} reviews`);
    const { [level]: _a, ...noApprovals } = zero.planApprovals;
    assert.ok(validPolicy({ ...zero, planApprovals: noApprovals as RiskPolicy["planApprovals"] }), `missing ${level} approvals`);
    const { [level]: _r, ...noReviews } = zero.finalReviews;
    assert.ok(validPolicy({ ...zero, finalReviews: noReviews as RiskPolicy["finalReviews"] }), `missing ${level} reviews`);
  }
});

test("with 0 approvals and 0 reviews in the policy, assess asks for none at that level", () => {
  const zero: RiskPolicy = { ...policy, planApprovals: { low: 0, medium: 0, high: 0 }, finalReviews: { low: 0, medium: 0, high: 0 } };
  for (const level of ["low", "medium", "high"] as const) {
    const a = assess(task({ risk: { level, reasons: [], areas: [] }, diff: { added: 1, removed: 0, files: ["a.ts"] } }), zero, undefined);
    assert.equal(a.level, level);
    assert.equal(a.approvals, 0);
    assert.equal(a.reviews, 0);
  }
});

test("an icon file is checked before it's uploaded, in the server's words", () => {
  const file = (type: string, size = 1024) => ({ type, size });
  for (const type of ["image/png", "image/jpeg", "image/webp"]) assert.equal(iconFileProblem(file(type)), null, type);
  assert.equal(iconFileProblem(file("image/png", 2 * 1024 * 1024)), null);
  assert.equal(iconFileProblem(file("image/png", 3 * 1024 * 1024)), "The icon can be up to 2 MB.");
  assert.equal(iconFileProblem(file("image/png", 0)), "The image is empty.");
  for (const type of ["image/gif", "image/svg+xml", ""]) assert.equal(iconFileProblem(file(type)), "The icon is a PNG, JPEG or WebP image.", type);
});

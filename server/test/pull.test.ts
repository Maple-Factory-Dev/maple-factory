// The web task page's pull request card: the checks' summary, the state label and which checks can run again.
import { test } from "node:test";
import assert from "node:assert/strict";
import { canRerun, checkHref, checkStatusText, checkSummary, prStateLabel } from "../web/app/pull.js";

const check = (status: string, over: Record<string, unknown> = {}) => ({ name: status, status, duration: "1m 2s", required: false, ...over });
const pr = (over: Record<string, unknown> = {}) => ({ number: 12, url: "https://github.com/o/r/pull/12", state: "open", branch: "agent/mf-1", base: "main", checks: [], ...over });
const task = (state = "reviewing") => ({ id: "MF-1", state });

test("no checks", () => {
  const s = checkSummary([]);
  assert.equal(s.tone, "none");
  assert.equal(s.headline, "No checks");
  assert.deepEqual(s.segments, []);
});

test("all passed, and a single check", () => {
  const all = checkSummary([check("passed"), check("passed")]);
  assert.equal(all.tone, "passed");
  assert.equal(all.headline, "All checks passed");
  assert.equal(all.detail, "2 of 2 passed");
  assert.equal(checkSummary([check("passed")]).headline, "Check passed");
});

test("failures lead the headline over running and queued", () => {
  const s = checkSummary([check("queued"), check("failed"), check("running"), check("passed"), check("passed")]);
  assert.equal(s.tone, "failed");
  assert.equal(s.headline, "1 failing");
  assert.equal(s.detail, "2 of 5 passed");
  assert.equal(s.total, 5);
  assert.deepEqual(s.segments, [{ status: "passed", count: 2 }, { status: "failed", count: 1 }, { status: "running", count: 1 }, { status: "queued", count: 1 }]);
});

test("only running, then only queued", () => {
  const running = checkSummary([check("running"), check("running"), check("queued")]);
  assert.equal(running.tone, "running");
  assert.equal(running.headline, "2 running");
  const queued = checkSummary([check("queued"), check("passed")]);
  assert.equal(queued.tone, "running");
  assert.equal(queued.headline, "1 queued");
  assert.deepEqual(queued.segments.map((x) => x.status), ["passed", "queued"]);
});

test("state labels, and a cancelled task's open pull request reads Closed", () => {
  assert.deepEqual(prStateLabel(pr(), task()), { state: "open", label: "Open", icon: "pr-open", class: "pr-state pr-state-open" });
  assert.equal(prStateLabel(pr({ state: "merged" }), task("merged")).label, "Merged");
  assert.equal(prStateLabel(pr({ state: "draft" }), task()).label, "Draft");
  assert.equal(prStateLabel(pr(), task("cancelled")).label, "Closed");
  assert.equal(prStateLabel(pr({ state: "draft" }), task("cancelled")).icon, "pr-closed");
  assert.equal(prStateLabel(pr({ state: "merged" }), task("cancelled")).label, "Merged");
});

test("re-run: finished checks on an open GitHub pull request of a task still going", () => {
  assert.equal(canRerun(check("failed"), pr(), task()), true);
  assert.equal(canRerun(check("passed"), pr({ state: "draft" }), task()), true);
  assert.equal(canRerun(check("failed"), pr({ state: "merged" }), task("merged")), false);
  assert.equal(canRerun(check("failed"), pr({ url: undefined }), task()), false);
  assert.equal(canRerun(check("queued"), pr(), task()), false);
  assert.equal(canRerun(check("running"), pr(), task()), false);
  assert.equal(canRerun(check("failed"), pr(), task("cancelled")), false);
});

test("links and status text", () => {
  assert.equal(checkHref(check("failed", { url: "https://x/run/1" }), pr()), "https://x/run/1");
  assert.equal(checkHref(check("failed"), pr()), "https://github.com/o/r/pull/12/checks");
  assert.equal(checkHref(check("failed"), pr({ url: undefined })), null);
  assert.equal(checkStatusText(check("failed")), "Failed · 1m 2s");
  assert.equal(checkStatusText(check("passed")), "1m 2s");
  assert.equal(checkStatusText(check("running")), "Running…");
  assert.equal(checkStatusText(check("queued")), "Queued");
});

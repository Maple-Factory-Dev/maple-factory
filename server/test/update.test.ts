// The "Update available" bar: shown once a reconnect reports a different maple-server version.
import { test } from "node:test";
import assert from "node:assert/strict";
import { bundleStale } from "../web/app/update.js";
import { fromNotice } from "../src/runner-update.ts";

test("the same version isn't stale", () => {
  assert.equal(bundleStale("0.43.0", "0.43.0"), false);
});

test("a different version is stale, newer or older", () => {
  assert.equal(bundleStale("0.43.0", "0.44.0"), true);
  assert.equal(bundleStale("0.44.0", "0.43.0"), true);
});

test("a missing version on either side isn't stale", () => {
  assert.equal(bundleStale(null, "0.44.0"), false);
  assert.equal(bundleStale(undefined, "0.44.0"), false);
  assert.equal(bundleStale("0.43.0", null), false);
  assert.equal(bundleStale("0.43.0", undefined), false);
  assert.equal(bundleStale("", "0.44.0"), false);
});

// A runner update's notices: `newer` (the feed moved past the version the person was shown) isn't a state of
// the update; the hub clears the update and the card offers the newer release instead.
test("a runner's newer notice moves no update along", () => {
  const checking = { state: "checking" as const, target: "0.10.0", from: "0.9.0", message: null, at: 1 };
  assert.equal(fromNotice(checking, { state: "newer", version: "0.11.0", message: "runner 0.11.0 came out after 0.10.0 was offered; update again to install it" }, "0.9.0", 2), null);
  assert.equal(fromNotice(undefined, { state: "newer", version: "0.11.0" }, "0.9.0", 2), null);
  // The others still do.
  assert.equal(fromNotice(checking, { state: "installing", version: "0.10.0" }, "0.9.0", 2)?.state, "installing");
});

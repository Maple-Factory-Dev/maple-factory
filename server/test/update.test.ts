// The "Update available" bar: shown once a reconnect reports a different maple-server version.
import { test } from "node:test";
import assert from "node:assert/strict";
import { bundleStale } from "../web/app/update.js";

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

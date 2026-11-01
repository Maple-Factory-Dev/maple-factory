// Presence across a person's open apps: the most recent view wins, and `mobile` is true only when
// every one of their connections is the iPhone or Android app.
import { test } from "node:test";
import assert from "node:assert/strict";
import { aggregatePresence, isMobileClient } from "../src/presence.ts";

test("someone only on their phone is mobile", () => {
  assert.deepEqual(aggregatePresence([{ login: "ana", viewing: "MF-1", since: 5, mobile: true }]), [{ login: "ana", viewing: "MF-1", since: 5, mobile: true }]);
});

test("someone on two phones is still mobile", () => {
  const [ana] = aggregatePresence([
    { login: "ana", viewing: null, since: 1, mobile: true },
    { login: "ana", viewing: "MF-2", since: 2, mobile: true },
  ]);
  assert.equal(ana.mobile, true);
  assert.equal(ana.viewing, "MF-2");
});

test("a phone and the Mac app together is not mobile, and the latest view still wins", () => {
  const online = aggregatePresence([
    { login: "ana", viewing: "MF-1", since: 1, mobile: false },
    { login: "ana", viewing: "MF-9", since: 9, mobile: true },
  ]);
  assert.deepEqual(online, [{ login: "ana", viewing: "MF-9", since: 9 }]);
  assert.equal("mobile" in online[0], false);
});

test("the Mac app alone leaves the flag out, as old servers did", () => {
  assert.deepEqual(aggregatePresence([{ login: "bo", viewing: undefined, since: 3 }]), [{ login: "bo", viewing: null, since: 3 }]);
});

test("each person is judged on their own connections", () => {
  const online = aggregatePresence([
    { login: "ana", since: 1, mobile: true },
    { login: "bo", since: 2 },
  ]);
  assert.deepEqual(online.map((p) => [p.login, p.mobile ?? false]), [["ana", true], ["bo", false]]);
});

test("only `x-maple-client: mobile` counts as a phone", () => {
  assert.equal(isMobileClient("mobile"), true);
  assert.equal(isMobileClient(" Mobile "), true);
  assert.equal(isMobileClient(null), false);
  assert.equal(isMobileClient("mac"), false);
  assert.equal(isMobileClient(""), false);
});

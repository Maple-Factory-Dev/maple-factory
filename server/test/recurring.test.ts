// Recurring tasks' schedule: runs step on the wall clock in their time zone, so 9:00 stays 9:00 across DST.
import { test } from "node:test";
import assert from "node:assert/strict";
import { everyText, nextRun, runAt } from "../src/factory/recurring.ts";

const ny = (ms: number) => new Intl.DateTimeFormat("en-US", { timeZone: "America/New_York", hourCycle: "h23", hour: "2-digit", minute: "2-digit", weekday: "short", month: "short", day: "numeric" }).format(ms);

test("a weekly 09:00 America/New_York run stays at 09:00 across both DST changes", () => {
  // Saturday 2026-10-24 09:00 EDT (13:00 UTC); DST ends Sunday 2026-11-01.
  const r = { every: 7 * 24 * 60, firstAt: Date.UTC(2026, 9, 24, 13, 0), timeZone: "America/New_York" };
  const runs = Array.from({ length: 22 }, (_, n) => runAt(r, n));
  for (const t of runs) assert.match(ny(t), /09:00$/, ny(t));
  assert.equal(runs[1], Date.UTC(2026, 9, 31, 13, 0)); // still EDT
  assert.equal(runs[2], Date.UTC(2026, 10, 7, 14, 0)); // EST: 14:00 UTC
  // DST starts 2027-03-14: back to 13:00 UTC.
  assert.equal(runs[21], Date.UTC(2027, 2, 20, 13, 0));
  // The next run after the first one is due moves forward one interval.
  assert.equal(nextRun(r, runs[1], true), runs[2]);
  assert.equal(nextRun(r, runs[1]), runs[1]);
  assert.equal(nextRun(r, runs[1] + 1), runs[2]);
});

test("hourly runs step in plain hours", () => {
  const r = { every: 6 * 60, firstAt: Date.UTC(2026, 10, 1, 4, 0), timeZone: "America/New_York" };
  assert.equal(runAt(r, 1) - runAt(r, 0), 6 * 3_600_000);
  assert.equal(nextRun(r, Date.UTC(2026, 10, 1, 5, 0)), Date.UTC(2026, 10, 1, 10, 0));
});

test("everyText", () => {
  assert.equal(everyText({ every: 7 * 24 * 60, unit: "weeks" }), "every week");
  assert.equal(everyText({ every: 2 * 24 * 60, unit: "days" }), "every 2 days");
  assert.equal(everyText({ every: 360, unit: "hours" }), "every 6 hours");
});

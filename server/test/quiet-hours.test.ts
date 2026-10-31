// Quiet hours (MF-224): the window logic (same-day, overnight, weekday-only, several windows, DST)
// and the store's checks on what it's sent.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { inQuietHours, quietUntil, validateQuietHours } from "../src/quiet-hours.ts";
import { Store } from "../src/factory/store.ts";
import type { QuietHours } from "../src/wire.ts";

const fixture = JSON.parse(readFileSync(new URL("../../protocol/quiet-hours-cases.json", import.meta.url), "utf8")) as {
  schedules: Record<string, QuietHours>;
  cases: { name: string; schedule: string; at: string; until: string | null }[];
};

for (const c of fixture.cases) {
  test(`quiet hours: ${c.name}`, () => {
    const q = fixture.schedules[c.schedule];
    const at = Date.parse(c.at);
    assert.equal(inQuietHours(q, at), c.until !== null);
    const until = quietUntil(q, at);
    assert.equal(until === null ? null : new Date(until).toISOString().replace(".000Z", "Z"), c.until);
  });
}

test("no schedule, or no windows: never quiet", () => {
  const now = Date.parse("2026-10-28T03:00:00Z");
  assert.equal(inQuietHours(null, now), false);
  assert.equal(quietUntil(undefined, now), null);
  assert.equal(inQuietHours({ timeZone: "UTC", windows: [] }, now), false);
});

test("quiet around the clock still answers", () => {
  const q: QuietHours = { timeZone: "UTC", windows: [{ days: [0, 1, 2, 3, 4, 5, 6], start: 0, end: 1439 }, { days: [0, 1, 2, 3, 4, 5, 6], start: 1439, end: 0 }] };
  const now = Date.parse("2026-10-28T03:00:00Z");
  assert.equal(inQuietHours(q, now), true);
  assert.ok(quietUntil(q, now)! > now);
});

const ok: QuietHours = { timeZone: "America/Toronto", windows: [{ days: [5, 1, 1], start: 1320, end: 420 }] };

test("validate: tidies days, keeps the rest", () => {
  assert.deepEqual(validateQuietHours(ok), { timeZone: "America/Toronto", windows: [{ days: [1, 5], start: 1320, end: 420 }] });
});

test("validate: rejects what isn't a schedule", () => {
  const bad: [unknown, RegExp][] = [
    [null, /must be a schedule/],
    [{ ...ok, timeZone: "Mars/Olympus" }, /isn't a time zone/],
    [{ ...ok, timeZone: "" }, /isn't a time zone/],
    [{ timeZone: "UTC" }, /list of windows/],
    [{ ...ok, windows: Array(8).fill({ days: [1], start: 0, end: 60 }) }, /at most 7/],
    [{ ...ok, windows: [{ days: [], start: 0, end: 60 }] }, /at least one day/],
    [{ ...ok, windows: [{ days: [7], start: 0, end: 60 }] }, /0 \(Sunday\) to 6/],
    [{ ...ok, windows: [{ days: [-1], start: 0, end: 60 }] }, /0 \(Sunday\) to 6/],
    [{ ...ok, windows: [{ days: [1.5], start: 0, end: 60 }] }, /0 \(Sunday\) to 6/],
    [{ ...ok, windows: [{ days: [1], start: 1440, end: 60 }] }, /start must be/],
    [{ ...ok, windows: [{ days: [1], start: 0, end: -1 }] }, /end must be/],
    [{ ...ok, windows: [{ days: [1], start: 600, end: 600 }] }, /same time/],
  ];
  for (const [q, message] of bad) assert.throws(() => validateQuietHours(q), message, JSON.stringify(q));
});

function sqlStorage() {
  const db = new DatabaseSync(":memory:");
  return {
    exec(query: string, ...bindings: unknown[]) {
      const statements = query.split(";").map((s) => s.trim()).filter(Boolean);
      if (statements.length > 1) {
        db.exec(query);
        return { toArray: () => [], one: () => undefined };
      }
      const rows = db.prepare(query).all(...(bindings as never[]));
      return { toArray: () => rows, one: () => rows[0] };
    },
  } as unknown as SqlStorage;
}

test("store: each person's own schedule, saved, replaced and cleared", () => {
  const store = new Store(sqlStorage());
  assert.equal(store.quietHours("ada"), null);
  store.setQuietHours("ada", ok);
  assert.deepEqual(store.quietHours("ada")?.windows[0].days, [1, 5]);
  assert.equal(store.quietHours("bob"), null);
  store.setQuietHours("ada", { timeZone: "UTC", windows: [] });
  assert.deepEqual(store.quietHours("ada"), { timeZone: "UTC", windows: [] });
  store.setQuietHours("ada", null);
  assert.equal(store.quietHours("ada"), null);
});

test("store: an invalid schedule throws and leaves the saved one alone", () => {
  const store = new Store(sqlStorage());
  store.setQuietHours("ada", ok);
  assert.throws(() => store.setQuietHours("ada", { timeZone: "Nowhere/Land", windows: [] }), /time zone/);
  assert.equal(store.quietHours("ada")?.timeZone, "America/Toronto");
});

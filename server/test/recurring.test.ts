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

// Scheduled (once) items: one task at their time, then they're gone.

import { DatabaseSync } from "node:sqlite";
import { Recurrings, whenText } from "../src/factory/recurring.ts";
import { Store } from "../src/factory/store.ts";
import { Engine } from "../src/factory/engine.ts";
import type { Recurring } from "../src/wire.ts";

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

const T0 = Date.UTC(2026, 10, 1, 12, 0);
const HOUR = 3_600_000;

function item(f: Partial<Recurring> = {}): Recurring {
  return {
    id: "r1", goal: "g", title: "Bump deps", brief: "Bump the deps.", repo: null, agent: "claude", every: 24 * 60, unit: "days",
    firstAt: T0 + 2 * HOUR, timeZone: "America/New_York", nextAt: 0, paused: false, lastRunAt: null, lastTask: null, by: "me", ...f,
  };
}

function setup() {
  const store = new Store(sqlStorage());
  store.saveGoal({ id: "g", name: "G", prefix: "MF", summary: "", lead: "me", repos: ["acme/app"], repo: "acme/app", archived: false } as never);
  const made: string[] = [];
  const removed: string[] = [];
  const updated: string[] = [];
  let n = 0;
  const recurrings = new Recurrings(store, {
    make: async (r) => {
      made.push(r.id);
      return { id: `MF-${++n}`, state: "planning" } as never;
    },
    note: () => {},
    updated: (r) => updated.push(r.id),
    removed: (r) => removed.push(r.id),
  });
  return { store, recurrings, made, removed, updated };
}

test("a scheduled item saved for later runs at its time", () => {
  const { recurrings } = setup();
  const saved = recurrings.clean(item({ once: true, every: 0 }), "me", T0);
  assert.equal(saved.once, true);
  assert.equal(saved.nextAt, T0 + 2 * HOUR);
  assert.equal(saved.every, 24 * 60); // a placeholder interval, ignored
});

test("a scheduled item in the past is rejected", () => {
  const { recurrings } = setup();
  assert.throws(() => recurrings.clean(item({ once: true, firstAt: T0 - HOUR }), "me", T0), /Pick a time from now on/);
  // Within the leeway it counts as now.
  assert.equal(recurrings.clean(item({ once: true, firstAt: T0 - 30_000 }), "me", T0).nextAt, T0 - 30_000);
});

test("when due, a scheduled item starts exactly one task and is removed", async () => {
  const { store, recurrings, made, removed } = setup();
  store.saveRecurring(recurrings.clean(item({ once: true }), "me", T0));
  assert.equal(await recurrings.run(T0 + HOUR), T0 + 2 * HOUR); // not yet
  assert.deepEqual(made, []);
  assert.equal(await recurrings.run(T0 + 2 * HOUR), null);
  assert.deepEqual(made, ["r1"]);
  assert.deepEqual(removed, ["r1"]);
  assert.equal(store.recurring("r1"), null);
  await recurrings.run(T0 + 30 * HOUR);
  assert.deepEqual(made, ["r1"]); // never again
});

test("a scheduled item ignores the skip-while-open rule", async () => {
  const { store, recurrings, made } = setup();
  store.saveTask({ id: "MF-9", goal: "g", title: "x", state: "building", owner: "me", brief: "", createdAt: T0, updatedAt: T0, plan: [], planVersion: 0, doneWhen: [],
    approvals: [], approvalsNeeded: 1, reviews: [], reviewsNeeded: 1, comments: [], changes: [], events: [], mockups: [], tickets: [], shareable: false, agent: "claude" } as never);
  store.saveRecurring({ ...recurrings.clean(item({ once: true }), "me", T0), lastTask: "MF-9" });
  await recurrings.run(T0 + 3 * HOUR);
  assert.deepEqual(made, ["r1"]);
});

test("resuming a paused scheduled item runs it at its time, or now if that's passed", () => {
  const { recurrings } = setup();
  const saved = recurrings.clean(item({ once: true, paused: true }), "me", T0);
  assert.equal(recurrings.pause(saved, false, T0).nextAt, T0 + 2 * HOUR);
  assert.equal(recurrings.pause(saved, false, T0 + 5 * HOUR).nextAt, T0 + 5 * HOUR);
});

test("repeating items keep their schedule and are never removed", async () => {
  const { store, recurrings, made, removed } = setup();
  store.saveRecurring(recurrings.clean(item(), "me", T0));
  await recurrings.run(T0 + 2 * HOUR);
  assert.deepEqual(made, ["r1"]);
  assert.deepEqual(removed, []);
  assert.equal(store.recurring("r1")!.nextAt, T0 + 26 * HOUR);
  assert.equal(store.recurring("r1")!.once, undefined);
  assert.throws(() => recurrings.clean(item({ every: 30 }), "me", T0), /at most once an hour/);
});

test("whenText shows the time in its zone", () => {
  assert.equal(whenText({ firstAt: T0 + 2 * HOUR, timeZone: "America/New_York" }), "Nov 1, 2026, 9:00 AM EST");
});

test("runNow on a scheduled item starts it, then removes it with a deleted broadcast", async () => {
  const store = new Store(sqlStorage());
  store.saveGoal({ id: "g", name: "G", prefix: "MF", summary: "", lead: "me", repos: ["acme/app"], repo: "acme/app", archived: false } as never);
  const sent: { type: string; id?: string }[] = [];
  const noop = () => {};
  const hooks = { broadcast: (m: never) => sent.push(m), sendTo: noop, machines: async () => [], members: async () => [], machineChanged: async () => {}, waitUntil: noop, wakeIn: noop };
  const engine = new Engine({} as never, store, hooks as never, {} as never, {} as never);
  const made: string[] = [];
  (engine as unknown as { recurringRun: (r: Recurring) => Promise<unknown> }).recurringRun = async (r) => {
    made.push(r.id);
    return { id: "MF-1", state: "planning" };
  };
  const me = { member: { login: "me", role: "admin" } } as never;
  await engine.command({ type: "recurring.save", recurring: item({ once: true, firstAt: Date.now() + 5 * HOUR }) }, me);
  assert.equal(store.recurring("r1")!.once, true);
  await engine.command({ type: "recurring.runNow", id: "r1" }, me);
  assert.deepEqual(made, ["r1"]);
  assert.equal(store.recurring("r1"), null);
  assert.deepEqual(sent.at(-1), { type: "recurring.deleted", id: "r1" });
});

// Recurring tasks: a goal's saved prompt that starts a new task every N hours, days or weeks. The
// OrgHub alarm runs the due ones (`run`), whether or not any app or machine is connected; each run is
// an ordinary task sent to planning, so the queue hands it to whichever runner is online. A `once` one
// (a scheduled task) runs one time at its firstAt and is then removed: its task is the record.

import type { Goal, Recurring, Task } from "../wire.ts";
import type { Store } from "./store.ts";
import { goalRepos } from "./repos.ts";

const MINUTE = 60_000;
const DAY_MINUTES = 24 * 60;
/** The shortest interval: an hour. */
export const MIN_EVERY = 60;
/** A save whose first run is at most this far in the past counts as "now". */
const NOW_LEEWAY = MINUTE;

/** How long one unit is, in minutes. */
export const UNIT_MINUTES = { hours: 60, days: DAY_MINUTES, weeks: 7 * DAY_MINUTES } as const;

/** "every 2 days", "every week". */
export function everyText(r: Pick<Recurring, "every" | "unit">): string {
  const n = Math.max(1, Math.round(r.every / UNIT_MINUTES[r.unit]));
  const name = r.unit.slice(0, -1);
  return n === 1 ? `every ${name}` : `every ${n} ${r.unit}`;
}

// Time zones, without a library: the zone's offset from what Intl says its wall clock reads.

const formatters = new Map<string, Intl.DateTimeFormat>();
function wallClock(ms: number, timeZone: string): number {
  let f = formatters.get(timeZone);
  if (!f) {
    f = new Intl.DateTimeFormat("en-US", { timeZone, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit" });
    formatters.set(timeZone, f);
  }
  const p = Object.fromEntries(f.formatToParts(ms).map((x) => [x.type, x.value]));
  return Date.UTC(+p.year, +p.month - 1, +p.day, +p.hour, +p.minute, +p.second) + (ms % 1000 + 1000) % 1000;
}

/** The instant that reads `wall` (a wall-clock time written as if UTC) in `timeZone`. */
function fromWallClock(wall: number, timeZone: string): number {
  let guess = wall - (wallClock(wall, timeZone) - wall);
  guess = wall - (wallClock(guess, timeZone) - guess);
  return guess;
}

export function validTimeZone(tz: string): boolean {
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: tz });
    return true;
  } catch {
    return false;
  }
}

/** The `n`th run (from 0): whole days step on the wall clock in its time zone (9:00 stays 9:00 across DST),
 *  anything else in plain minutes. */
export function runAt(r: Pick<Recurring, "every" | "firstAt" | "timeZone">, n: number): number {
  if (r.every % DAY_MINUTES !== 0) return r.firstAt + n * r.every * MINUTE;
  const wall = wallClock(r.firstAt, r.timeZone) + n * r.every * MINUTE;
  return fromWallClock(wall, r.timeZone);
}

/** The first run at or after `at` (strictly after when `strict`). */
export function nextRun(r: Pick<Recurring, "every" | "firstAt" | "timeZone">, at: number, strict = false): number {
  const after = (t: number) => (strict ? t > at : t >= at);
  if (after(r.firstAt)) return r.firstAt;
  let n = Math.max(0, Math.floor((at - r.firstAt) / (r.every * MINUTE)) - 1);
  while (!after(runAt(r, n))) n++;
  return runAt(r, n);
}

type Hooks = {
  /** Make the run's task and send it to planning. */
  make(r: Recurring, goal: Goal): Promise<Task>;
  /** Note on a task (the last run's) why this run was skipped. */
  note(task: Task, text: string): void;
  updated(r: Recurring): void;
  /** A scheduled (once) one ran and is gone. */
  removed(r: Recurring): void;
};

export class Recurrings {
  constructor(private store: Store, private hooks: Hooks) {}

  /** A save from an app, checked and with its schedule worked out. `before` is the stored one, if any. */
  clean(r: Recurring, by: string, now: number): Recurring {
    const goal = this.store.goal(r.goal);
    if (!goal) throw new Error("That goal isn't there any more.");
    if (goal.archived) throw new Error(`${goal.name} is archived; unarchive it to add recurring tasks.`);
    const before = this.store.recurring(r.id);
    if (before && before.goal !== r.goal) throw new Error("A recurring task can't move to another goal.");
    const title = r.title.trim();
    if (!title) throw new Error("A recurring task needs a title.");
    if (!r.brief.trim()) throw new Error("Say what each run should do.");
    const repo = r.repo ? goalRepos(goal).find((x) => x.toLowerCase() === r.repo!.toLowerCase()) : null;
    if (r.repo && !repo) throw new Error(`${goal.name} doesn't work in ${r.repo}; add it to the goal's repos first.`);
    const once = !!r.once;
    // A one-off ignores its interval; keep whatever valid one it has so switching back to repeating is easy.
    const every = once && !(Number.isInteger(r.every) && r.every >= MIN_EVERY) ? DAY_MINUTES : r.every;
    const unit = once && !(r.unit in UNIT_MINUTES) ? "days" : r.unit;
    if (!Number.isInteger(every) || every < MIN_EVERY) throw new Error("A recurring task runs at most once an hour.");
    if (!(unit in UNIT_MINUTES)) throw new Error("Every hours, days or weeks.");
    const timeZone = r.timeZone?.trim() || "UTC";
    if (!validTimeZone(timeZone)) throw new Error(`${timeZone} isn't a time zone.`);
    if (!Number.isFinite(r.firstAt) || r.firstAt <= 0) throw new Error("Pick when it first runs.");
    if (once && r.firstAt < now - NOW_LEEWAY) throw new Error("Pick a time from now on.");
    const saved: Recurring = {
      id: r.id, goal: goal.id, title, brief: r.brief.trim(), repo: repo ?? null, agent: r.agent || "claude",
      every, unit, firstAt: r.firstAt, timeZone, paused: !!r.paused,
      nextAt: 0, lastRunAt: before?.lastRunAt ?? null, lastTask: before?.lastTask ?? null, by,
    };
    if (once) saved.once = true;
    saved.nextAt = once ? r.firstAt : nextRun(saved, now - NOW_LEEWAY);
    return saved;
  }

  /** Pause, or resume from the next due time from now. */
  pause(r: Recurring, paused: boolean, now: number): Recurring {
    const saved = { ...r, paused };
    if (!paused) saved.nextAt = r.once ? Math.max(r.firstAt, now) : nextRun(r, now - NOW_LEEWAY);
    return saved;
  }

  /** Whether its last run's task is still open (not merged, cancelled or closed). */
  private lastOpen(r: Recurring): Task | null {
    const t = r.lastTask ? this.store.task(r.lastTask) : null;
    return t && t.state !== "merged" && t.state !== "cancelled" && t.state !== "closed" ? t : null;
  }

  /** One run: a new task in planning. Its schedule is the caller's. */
  async start(r: Recurring, now: number): Promise<Recurring> {
    const goal = this.store.goal(r.goal);
    if (!goal || goal.archived) throw new Error("Its goal is archived or gone.");
    const task = await this.hooks.make(r, goal);
    return { ...r, lastTask: task.id, lastRunAt: now };
  }

  /** Every due one: a run, or a skip while its last task is still open; then its next run. Returns the next due time. */
  async run(now: number): Promise<number | null> {
    for (const due of this.store.dueRecurring(now)) {
      if (due.once) {
        await this.runOnce(due, now);
        continue;
      }
      let r: Recurring = { ...due, nextAt: nextRun(due, now, true) };
      const open = this.lastOpen(due);
      const goal = this.store.goal(due.goal);
      if (!goal || goal.archived) {
        r.paused = true;
      } else if (open) {
        this.hooks.note(open, `Recurring "${due.title}" skipped a run: ${open.id} is still open.`);
      } else {
        try {
          r = await this.start(r, now);
        } catch (e) {
          console.warn(`recurring ${due.id}: ${(e as Error).message}`);
        }
      }
      this.store.saveRecurring(r);
      this.hooks.updated(r);
    }
    return this.store.nextRecurringAt();
  }

  /** A due scheduled one: its task, then it's removed. No skip-while-open rule: it only ever runs once.
   *  If its goal is gone or the run fails, it's paused instead so nobody loses it. */
  private async runOnce(due: Recurring, now: number) {
    const goal = this.store.goal(due.goal);
    if (goal && !goal.archived) {
      try {
        await this.start(due, now);
        this.remove(due);
        return;
      } catch (e) {
        console.warn(`scheduled ${due.id}: ${(e as Error).message}`);
      }
    }
    const r = { ...due, paused: true };
    this.store.saveRecurring(r);
    this.hooks.updated(r);
  }

  /** A scheduled one is done: gone from the store, and from the apps. */
  remove(r: Recurring) {
    this.store.deleteRecurring(r.id);
    this.hooks.removed(r);
  }
}

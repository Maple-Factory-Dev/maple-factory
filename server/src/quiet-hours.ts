// Quiet hours (MF-224): someone's weekly schedule when nothing notifies them, on any device.
// Each window starts on its `days` at `start` (minutes after midnight, in the schedule's own time
// zone) and ends at `end`; an `end` at or before `start` runs past midnight into the next day.
// The Mac app (QuietHours+Schedule.swift) and the web app (app.js) carry ports of the same logic,
// checked against the same cases (test/quiet-hours-cases.json).

import type { QuietHours, QuietWindow } from "./wire.ts";

export const MAX_QUIET_WINDOWS = 7;
const MINUTE = 60_000;
const DAY_MINUTES = 1440;

/** Checks a schedule someone sent, and gives it back tidied (days sorted, no repeats); throws a readable Error when it's not valid. */
export function validateQuietHours(q: unknown): QuietHours {
  if (!q || typeof q !== "object") throw new Error("Quiet hours must be a schedule.");
  const { timeZone, windows } = q as Partial<QuietHours>;
  if (typeof timeZone !== "string" || !timeZone || !isTimeZone(timeZone)) throw new Error(`"${String(timeZone)}" isn't a time zone (like America/Toronto).`);
  if (!Array.isArray(windows)) throw new Error("Quiet hours need a list of windows.");
  if (windows.length > MAX_QUIET_WINDOWS) throw new Error(`Quiet hours can have at most ${MAX_QUIET_WINDOWS} windows.`);
  const tidy: QuietWindow[] = windows.map((w, i) => {
    const n = i + 1;
    if (!w || typeof w !== "object") throw new Error(`Window ${n} isn't a window.`);
    const { days, start, end } = w as QuietWindow;
    if (!Array.isArray(days) || days.length === 0) throw new Error(`Window ${n} needs at least one day.`);
    if (!days.every((d) => Number.isInteger(d) && d >= 0 && d <= 6)) throw new Error(`Window ${n}: days go from 0 (Sunday) to 6 (Saturday).`);
    for (const [name, m] of [["start", start], ["end", end]] as const) {
      if (!Number.isInteger(m) || m < 0 || m >= DAY_MINUTES) throw new Error(`Window ${n}: ${name} must be minutes after midnight, 0 to 1439.`);
    }
    if (start === end) throw new Error(`Window ${n} starts and ends at the same time.`);
    return { days: [...new Set(days)].sort((a, b) => a - b), start, end };
  });
  return { timeZone, windows: tidy };
}

export function isTimeZone(zone: string): boolean {
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: zone });
    return true;
  } catch {
    return false;
  }
}

const formatters = new Map<string, Intl.DateTimeFormat>();
function formatter(zone: string): Intl.DateTimeFormat {
  let f = formatters.get(zone);
  if (!f) {
    f = new Intl.DateTimeFormat("en-US", { timeZone: zone, hourCycle: "h23", year: "numeric", month: "numeric", day: "numeric", hour: "numeric", minute: "numeric", second: "numeric" });
    formatters.set(zone, f);
  }
  return f;
}

/** The wall clock in `zone` at `at` (ms): its weekday (0 Sunday), minute of the day, and its offset from UTC in ms. */
export function wallClock(zone: string, at: number): { day: number; minute: number; offset: number } {
  const parts: Record<string, number> = {};
  for (const p of formatter(zone).formatToParts(new Date(at))) if (p.type !== "literal") parts[p.type] = Number(p.value);
  const asUTC = Date.UTC(parts.year, parts.month - 1, parts.day, parts.hour, parts.minute, parts.second);
  const day = new Date(Date.UTC(parts.year, parts.month - 1, parts.day)).getUTCDay();
  const secondStart = at - (((at % 1000) + 1000) % 1000);
  return { day, minute: parts.hour * 60 + parts.minute, offset: asUTC - secondStart };
}

/** Wall-clock minutes left in the windows that cover `day`/`minute`; the longest, or 0 when none does. */
function minutesLeft(windows: QuietWindow[], day: number, minute: number): number {
  let left = 0;
  const yesterday = (day + 6) % 7;
  for (const w of windows) {
    if (w.end > w.start) {
      if (w.days.includes(day) && minute >= w.start && minute < w.end) left = Math.max(left, w.end - minute);
    } else {
      if (w.days.includes(day) && minute >= w.start) left = Math.max(left, DAY_MINUTES - minute + w.end);
      if (w.days.includes(yesterday) && minute < w.end) left = Math.max(left, w.end - minute);
    }
  }
  return left;
}

/** Whether `now` (ms) is inside one of the schedule's windows. No schedule: never quiet. */
export function inQuietHours(q: QuietHours | null | undefined, now: number): boolean {
  if (!q || q.windows.length === 0) return false;
  const { day, minute } = wallClock(q.timeZone, now);
  return minutesLeft(q.windows, day, minute) > 0;
}

/**
 * When the quiet that covers `now` ends (ms), following windows that run straight into one another;
 * null when `now` isn't quiet. Across a DST change it's the real instant the wall clock reads the end.
 */
export function quietUntil(q: QuietHours | null | undefined, now: number): number | null {
  if (!q || q.windows.length === 0) return null;
  let at = now;
  for (let hops = 0; hops < 16; hops++) {
    const here = wallClock(q.timeZone, at);
    const left = minutesLeft(q.windows, here.day, here.minute);
    if (left === 0) return hops === 0 ? null : at;
    // The wall-clock end, then corrected for any change in the zone's offset by then (twice, to settle on the far side of a DST change).
    const wallEnd = at - (at % MINUTE) + left * MINUTE;
    let end = wallEnd;
    for (let i = 0; i < 2; i++) end = wallEnd - (wallClock(q.timeZone, end).offset - here.offset);
    at = Math.max(end, at + MINUTE);
  }
  return at; // Quiet around the clock: the furthest we looked.
}

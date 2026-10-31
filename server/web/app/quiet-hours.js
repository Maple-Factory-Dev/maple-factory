// Quiet hours (MF-224) in the browser: the same window logic as the server's src/quiet-hours.ts and the
// Mac's QuietHours+Schedule.swift, checked against the same cases (test/quiet-hours.test.ts runs both).
// A window starts on its `days` (0 Sunday) at `start` minutes after midnight in the schedule's zone; an
// `end` at or before `start` runs past midnight. Mention notifications stay quiet inside one.

const formatters = new Map();
const WEEKDAYS = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };

function wallClock(zone, at) {
  let f = formatters.get(zone);
  if (!f) {
    f = new Intl.DateTimeFormat("en-US", { timeZone: zone, hourCycle: "h23", weekday: "short", hour: "numeric", minute: "numeric" });
    formatters.set(zone, f);
  }
  const parts = {};
  for (const p of f.formatToParts(new Date(at))) parts[p.type] = p.value;
  return { day: WEEKDAYS[parts.weekday], minute: Number(parts.hour) * 60 + Number(parts.minute) };
}

/** Whether `now` (ms) is inside one of the schedule's windows. No schedule, or a zone this browser doesn't know: never quiet. */
export function inQuietHours(q, now = Date.now()) {
  if (!q || !q.windows?.length) return false;
  let here;
  try {
    here = wallClock(q.timeZone, now);
  } catch {
    return false;
  }
  const yesterday = (here.day + 6) % 7;
  return q.windows.some((w) => w.end > w.start
    ? w.days.includes(here.day) && here.minute >= w.start && here.minute < w.end
    : (w.days.includes(here.day) && here.minute >= w.start) || (w.days.includes(yesterday) && here.minute < w.end));
}

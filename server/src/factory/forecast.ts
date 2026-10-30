// Merge forecasts: which in-flight tasks change the same files, so a merge that's about to land on
// another task's base can be checked (`task.merge_check`) before that task's own merge fails.
// Pure: given the tasks and where each one merges, it says what each forecast's overlaps should be.

import type { MergeForecast, MergeOverlap, Task } from "../wire.ts";

/** Where a task merges: its repo (or folder) and base branch. Tasks only overlap within one lane. */
export interface Lane {
  repo: string;
  base: string;
}

/** Building or reviewing: its branch is still on its way to its base. */
export const inFlight = (t: Task) => t.state === "building" || t.state === "reviewing";

export const emptyForecast = (): MergeForecast => ({ overlaps: [], conflicts: [], since: null, checkedAt: null, base: null });

/** Each in-flight task's overlaps: the other in-flight tasks in its lane whose `diff.files` share
 *  files with its own, linked both ways and sorted by task id. Tasks with no diff overlap nothing. */
export function overlaps(tasks: Task[], lane: (t: Task) => Lane | null): Map<string, MergeOverlap[]> {
  const open = tasks
    .filter((t) => inFlight(t) && t.diff?.files.length)
    .map((t) => ({ t, lane: lane(t), files: new Set(t.diff!.files) }))
    .filter((o): o is { t: Task; lane: Lane; files: Set<string> } => o.lane != null);
  const out = new Map<string, MergeOverlap[]>(tasks.filter(inFlight).map((t) => [t.id, []]));
  for (const [i, a] of open.entries()) {
    for (const b of open.slice(i + 1)) {
      if (a.lane.repo.toLowerCase() !== b.lane.repo.toLowerCase() || a.lane.base !== b.lane.base) continue;
      const files = [...a.files].filter((f) => b.files.has(f)).sort();
      if (!files.length) continue;
      out.get(a.t.id)!.push({ task: b.t.id, files });
      out.get(b.t.id)!.push({ task: a.t.id, files });
    }
  }
  for (const list of out.values()) list.sort((x, y) => x.task.localeCompare(y.task, undefined, { numeric: true }));
  return out;
}

/** Sets every task's `mergeForecast.overlaps` from `overlaps`, clearing them on tasks that aren't in
 *  flight any more, and returns the tasks that changed (to save and broadcast). */
export function refreshOverlaps(tasks: Task[], lane: (t: Task) => Lane | null): Task[] {
  const now = overlaps(tasks, lane);
  const changed: Task[] = [];
  for (const t of tasks) {
    const next = now.get(t.id) ?? [];
    const before = t.mergeForecast?.overlaps ?? [];
    if (JSON.stringify(before) === JSON.stringify(next)) continue;
    t.mergeForecast = { ...(t.mergeForecast ?? emptyForecast()), overlaps: next };
    changed.push(t);
  }
  return changed;
}

/** The in-flight tasks a merge of `merged` could have broken: the ones it overlapped, still open. */
export function affectedBy(merged: Task, tasks: Task[]): Task[] {
  const ids = new Set((merged.mergeForecast?.overlaps ?? []).map((o) => o.task));
  return tasks.filter((t) => ids.has(t.id) && inFlight(t));
}

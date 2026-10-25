// Which GitHub repos a goal's work spans, and the one each task changes.

import type { Goal, Task } from "../wire.ts";

export const REPO = /^[\w.-]+\/[\w.-]+$/;

/** Every repo a goal's work spans, its `repo` first. */
export function goalRepos(goal: Goal): string[] {
  const all = [goal.repo, ...(goal.repos ?? [])].filter((r): r is string => !!r);
  return all.filter((r, i) => all.findIndex((x) => x.toLowerCase() === r.toLowerCase()) === i);
}

/** The repo a task changes: its own pick, else its goal's. */
export function taskRepo(task: Task, goal: Goal | null): string | null {
  return task.repo ?? goal?.repo ?? null;
}

// Which GitHub repos a goal's work spans, and the one each task changes.

import type { Goal, Task } from "../wire.ts";

export const REPO = /^[\w.-]+\/[\w.-]+$/;
/** A GitHub account's login: letters, digits and single hyphens, at most 39. */
export const OWNER = /^[a-z\d](?:[a-z\d]|-(?=[a-z\d])){0,38}$/i;

/** Every repo a goal's work spans, its `repo` first. */
export function goalRepos(goal: Goal): string[] {
  const all = [goal.repo, ...(goal.repos ?? [])].filter((r): r is string => !!r);
  return all.filter((r, i) => all.findIndex((x) => x.toLowerCase() === r.toLowerCase()) === i);
}

/** Whether a read-only fetch of owner/repo is a goal's: one of its repos, or, for a goal that names a
 *  folder and lists no repos, any repo the app reaches (the folder's origin; tasks on it get tokens alike). */
export function goalMayFetch(goal: Goal, repo: string): boolean {
  const repos = goalRepos(goal);
  if (!repos.length) return !!goal.folder;
  return repos.some((r) => r.toLowerCase() === repo.toLowerCase());
}

/** The repo a task changes: its own pick, else its goal's. */
export function taskRepo(task: Task, goal: Goal | null): string | null {
  return task.repo ?? goal?.repo ?? null;
}

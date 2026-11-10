// Search and filters behind the outside MCP tools list_goals and list_tasks (MF-416). Pure, so it's tested
// without the engine. It looks at a goal's name, prefix, summary and repos, and a task's id, title and brief;
// never plan text, logs or comments.

import type { Goal, Priority, Task, TaskState } from "../wire.ts";

/** The longest `q` looked at, and the most words in it. */
export const MAX_Q = 200;
export const MAX_WORDS = 8;

/** The words of a search, lowercased: at most 8 from its first 200 characters. */
export const words = (q: string | null | undefined): string[] => (q ?? "").slice(0, MAX_Q).toLowerCase().split(/\s+/).filter(Boolean).slice(0, MAX_WORDS);

/** Whether every word of `q` appears in at least one field, whatever the case. An empty `q` matches. */
export function matchesWords(q: string | null | undefined, ...fields: (string | null | undefined)[]): boolean {
  const hay = fields.map((f) => (f ?? "").toLowerCase());
  return words(q).every((w) => hay.some((f) => f.includes(w)));
}

/** A goal's repos: `repos`, or its one `repo` on an older goal. */
const reposOf = (goal: Goal): string[] => (goal.repos?.length ? goal.repos : goal.repo ? [goal.repo] : []);

/** Goals matching `q` (name, prefix, summary or a repo), by name; archived ones only when asked. */
export function filterGoals(goals: Goal[], f: { q?: string | null; archived?: boolean } = {}): Goal[] {
  return goals
    .filter((g) => (f.archived || !g.archived) && matchesWords(f.q, g.name, g.prefix, g.summary, ...reposOf(g)))
    .sort((a, b) => a.name.localeCompare(b.name));
}

/** The goal named by its id, prefix or name (whatever the case), or null. */
export function findGoal(goals: Goal[], ref: string): Goal | null {
  const want = ref.trim().toLowerCase();
  if (!want) return null;
  return goals.find((g) => g.id.toLowerCase() === want) ?? goals.find((g) => g.prefix.toLowerCase() === want) ?? goals.find((g) => g.name.toLowerCase() === want) ?? null;
}

/** Still in play: not merged, closed or cancelled. */
export const isOpen = (state: TaskState) => state !== "merged" && state !== "closed" && state !== "cancelled";

export interface TaskFilter {
  q?: string | null;
  /** A goal's id, prefix or name; one that names no goal matches nothing. */
  goal?: string | null;
  state?: TaskState | "open" | null;
  owner?: string | null;
  priority?: Priority | null;
  effort?: string | null;
}

/** Tasks matching every filter given and `q` (id, title or brief): a task whose id is `q` exactly ("MF-416", or
 *  "416") first, then most recently updated first. */
export function filterTasks(tasks: Task[], goals: Goal[], f: TaskFilter = {}): Task[] {
  const goal = f.goal?.trim() ? findGoal(goals, f.goal) : undefined;
  if (goal === null) return [];
  const owner = f.owner?.trim().replace(/^@/, "").toLowerCase();
  const effort = f.effort?.trim().toLowerCase();
  const q = (f.q ?? "").trim().toLowerCase();
  const exact = (t: Task) => (q && (t.id.toLowerCase() === q || t.id.toLowerCase().endsWith(`-${q}`)) ? 0 : 1);
  return tasks
    .filter((t) => (!goal || t.goal === goal.id)
      && (!f.state || (f.state === "open" ? isOpen(t.state) : t.state === f.state))
      && (!owner || t.owner.toLowerCase() === owner)
      && (!f.priority || t.priority === f.priority)
      && (!effort || (t.effort ?? "").toLowerCase() === effort)
      && matchesWords(f.q, t.id, t.title, t.brief))
    .sort((a, b) => exact(a) - exact(b) || b.updatedAt - a.updatedAt);
}

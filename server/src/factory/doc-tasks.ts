// Tasks from docs (MF-368, docs/planning-docs.md): the pure part of `doc.makeTasks`, kept here so it's
// unit-testable. The split itself is shared with the editor's Make tasks dialog (docs-editor/src/split.js).
import type { Decision, Doc, Goal, TaskDocSource } from "../wire.ts";
import { splitSection, titleOf, MAX_TASKS, MAX_TITLE } from "../../docs-editor/src/split.js";

export { splitSection, titleOf, MAX_TASKS, MAX_TITLE };
export const MAX_BRIEF = 20_000;
export const MAX_EXCERPT = 8_000;

/** The link back to the source, as the app's hash route: `#/docs/<id>` (with `?decision=<id>` for a decision). */
export function sourceLink(source: Pick<TaskDocSource, "doc" | "decision">): string {
  return `#/docs/${source.doc}${source.decision ? `?decision=${source.decision}` : ""}`;
}

/** "<title> › <heading>": where a task came from, for its brief, its page and its event. */
export function sourceLabel(source: Pick<TaskDocSource, "docTitle" | "heading">): string {
  return [source.docTitle, source.heading].filter(Boolean).join(" › ");
}

/** A task's brief: what the dialog said, then a closing line linking back to the doc. */
export function composeBrief(item: { brief: string }, source: Pick<TaskDocSource, "doc" | "docTitle" | "heading" | "decision">): string {
  const line = `From doc [${sourceLabel(source).replace(/[[\]]/g, "")}](${sourceLink(source)})${source.decision ? " (a decision)" : ""}.`;
  return `${item.brief.trim()}\n\n${line}`;
}

export type SourceCheck = {
  doc: Doc | null;
  /** The doc's goal, or the one picked when it has none. */
  goal: Goal | null;
  /** A goal was named in the message (only allowed when the doc has none). */
  picked: boolean;
  decision: Decision | null;
  decisionAsked: boolean;
  tasks: { title: unknown; brief: unknown }[];
  effort?: unknown;
};

/** Why `doc.makeTasks` can't make these tasks, or null. Nothing is made when this says no. */
export function checkSource(c: SourceCheck): string | null {
  if (!c.doc) return "That doc isn't there any more.";
  if (c.doc.archived) return `"${c.doc.title}" is archived; bring it back before making tasks from it.`;
  if (c.decisionAsked) {
    if (!c.decision || c.decision.doc !== c.doc.id) return "That decision isn't in this doc.";
    if (c.decision.status !== "accepted") return `Only an accepted decision can become tasks; this one is ${c.decision.status}.`;
  }
  if (c.doc.goal && c.picked && c.goal?.id !== c.doc.goal) return "This doc already belongs to a goal; its tasks go there.";
  if (!c.goal) return c.doc.goal || c.picked ? "That goal isn't there any more." : "This doc has no goal: pick the goal the tasks go in.";
  if (c.goal.archived) return `${c.goal.name} is archived.`;
  if (!Array.isArray(c.tasks) || !c.tasks.length) return "Give at least one task.";
  if (c.tasks.length > MAX_TASKS) return `At most ${MAX_TASKS} tasks at once.`;
  for (const [i, t] of c.tasks.entries()) {
    const title = typeof t?.title === "string" ? t.title.trim() : "";
    const brief = typeof t?.brief === "string" ? t.brief.trim() : "";
    if (!title) return `Task ${i + 1} needs a title.`;
    if (title.length > MAX_TITLE) return `Task ${i + 1}'s title is over ${MAX_TITLE} characters.`;
    if (!brief) return `Task ${i + 1} needs a brief.`;
    if (brief.length > MAX_BRIEF - 500) return `Task ${i + 1}'s brief is over ${MAX_BRIEF - 500} characters.`;
  }
  if (c.effort != null && (typeof c.effort !== "string" || c.effort.length > 80)) return "An effort name is at most 80 characters.";
  return null;
}

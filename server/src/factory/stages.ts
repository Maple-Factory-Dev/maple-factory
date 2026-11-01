// A task's time, span by span: which stage it was in and what it waited on (MF-302).
// Engine.save calls trackStage on every save, so wherever a state, hand, question or wait changes,
// the change lands here without each of those places knowing about it.

import type { StageSpan, StageWait, Task, TaskState } from "../wire.ts";

export const TERMINAL: readonly TaskState[] = ["merged", "cancelled", "closed"];

export interface Phase {
  stage: TaskState;
  wait: StageWait | null;
}

/** Where a task is now: its state, and what it's waiting on (a hand first, then a question, then a slot). */
export function phaseOf(task: Task): Phase {
  const wait: StageWait | null = task.hand ? "hand" : task.question ? "question" : task.waiting ? "queued" : null;
  return { stage: task.state, wait: TERMINAL.includes(task.state) ? null : wait };
}

/**
 * Close the open span and open a new one when the task's phase changed. A terminal state closes
 * the open span and leaves a zero-length marker. Returns whether it added a span.
 */
export function trackStage(task: Task, at: number): boolean {
  const stages = (task.stages ??= []);
  const { stage, wait } = phaseOf(task);
  const last = stages.at(-1);
  if (last && last.stage === stage && (last.wait ?? null) === wait && (last.to == null || TERMINAL.includes(stage))) return false;
  // An open span that began this same instant never really happened: replace it.
  if (last && last.to == null && last.from >= at) {
    stages.pop();
    return trackStage(task, at) || true;
  }
  if (last && last.to == null) last.to = Math.max(last.from, at);
  const from = last ? Math.max(at, last.to ?? at) : Math.min(task.createdAt || at, at);
  stages.push(span(stage, wait, from, TERMINAL.includes(stage) ? from : null));
  return true;
}

function span(stage: TaskState, wait: StageWait | null, from: number, to: number | null, inferred?: boolean): StageSpan {
  const s: StageSpan = { stage, from, to };
  if (wait) s.wait = wait;
  if (inferred) s.inferred = true;
  return s;
}

/** Which stage an event moves a task into, as best its text says. */
function stageOfEvent(text: string): TaskState | null {
  if (text === "sent it to planning" || text === "sent it back to the planner") return "planning";
  if (/^(?:wrote the plan|revised the plan \(v\d+\))$/.test(text)) return "awaitingApproval";
  if (text === "approved the plan") return "building";
  if (/^opened pull request #\d+/.test(text)) return "reviewing";
  if (text === "sent it to the backlog") return "backlog";
  if (text.startsWith("merged into") || /^rechecked GitHub: pull request #\d+ merged$/.test(text)) return "merged";
  return null;
}

/**
 * Best-effort spans for a task from before `stages`: worked out from createdAt and its events
 * (plan written or approved, PR opened, merged), each flagged inferred. Hands and queue waits
 * don't show in events reliably, so these spans carry no waits.
 */
export function inferStages(task: Task): StageSpan[] {
  const marks: { stage: TaskState; at: number }[] = [{ stage: "drafting", at: task.createdAt }];
  for (const e of task.events ?? []) {
    const stage = stageOfEvent(e.text);
    if (stage && e.at >= marks.at(-1)!.at) marks.push({ stage, at: e.at });
  }
  if (TERMINAL.includes(task.state) && marks.at(-1)!.stage !== task.state) {
    marks.push({ stage: task.state, at: Math.max(task.updatedAt, marks.at(-1)!.at) });
  } else if (!TERMINAL.includes(task.state) && marks.at(-1)!.stage !== task.state) {
    marks.push({ stage: task.state, at: marks.at(-1)!.at });
  }
  const out: StageSpan[] = [];
  for (const m of marks) {
    const last = out.at(-1);
    if (last?.stage === m.stage) continue;
    if (last && TERMINAL.includes(last.stage)) break;
    if (last) last.to = m.at;
    out.push(span(m.stage, null, m.at, TERMINAL.includes(m.stage) ? m.at : null, true));
  }
  // A span that ended the moment it began says nothing: drop it (but keep terminal markers).
  return out.filter((s) => s.to == null || s.to > s.from || TERMINAL.includes(s.stage));
}

/**
 * Time a task sat idle before anyone asked it to move: its drafting and backlog spans, an open one
 * counted up to `until`. Terminal markers count nothing. Matches the apps' TaskTimes.idle.
 */
export function idleMs(stages: readonly StageSpan[], until: number): number {
  let total = 0;
  for (const s of stages) {
    if (s.stage !== "drafting" && s.stage !== "backlog") continue;
    const to = Math.min(s.to ?? until, until);
    if (to > s.from) total += to - s.from;
  }
  return total;
}

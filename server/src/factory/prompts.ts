// What each factory session is told. Agents report back only through the `maple` MCP tools
// (tools.ts); the prompts say which, and when to stop.

import type { Goal, Task } from "../wire.ts";

const plain = (task: Task) => `${task.id} · ${task.title}`;

function brief(task: Task, goal: Goal | null) {
  return [
    `Task ${plain(task)}`,
    goal ? `Goal: ${goal.name}${goal.summary ? ` — ${goal.summary}` : ""}` : null,
    "",
    "## Brief",
    task.brief.trim() || task.title,
    task.tickets.filter((t) => t.asContext).length
      ? "\n## Linked tickets\n" + task.tickets.filter((t) => t.asContext).map((t) => `- ${t.key}: ${t.title} (${t.status})`).join("\n")
      : null,
  ].filter((l) => l !== null).join("\n");
}

function changes(task: Task) {
  const queued = task.changes.filter((c) => c.status !== "applied");
  if (!queued.length) return "";
  return "\n\n## Change requests to apply\n" + queued.map((c) => `- (${c.id}) ${c.author}: ${c.text}${c.anchor ? ` [on: ${c.anchor}]` : ""}`).join("\n");
}

function comments(task: Task) {
  const recent = task.comments.slice(-10);
  if (!recent.length) return "";
  return "\n\n## Discussion so far\n" + recent.map((c) => `- ${c.author}: ${c.text}`).join("\n");
}

export function plannerPrompt(task: Task, goal: Goal | null): string {
  return `You are the planner for a software factory task. You write the plan; you do NOT change code.

${brief(task, goal)}${comments(task)}${changes(task)}

Read the repository (this worktree) to understand where the change goes. Then call the \`submit_plan\` tool once with:
- summary: two or three sentences on the approach.
- steps: 3–8 concrete steps, each with the main file it touches.
- doneWhen: 2–5 checks that prove it works, each with the proof kind the builder will produce (tests, terminal, screenshot or video).
- risk: low, medium or high, with reasons (auth, payments, migrations and public APIs are high) and the areas it touches.
- footprint: your estimate of files and lines changed.
- mockups: for UI changes, at least one screen mockup as a small self-contained HTML page (inline CSS, no scripts) of the changed screen,
  with numbered callouts in its notes; for CLI or API changes, a terminal mockup (lines with style command/output/highlight/dim/error,
  and callout numbers on the lines that change). Skip mockups for pure refactors.

If something essential is ambiguous, call \`ask\` with the question and a few options, then end your turn and wait: the answer will be typed here.
If the task can't be planned as asked, call \`raise_hand\`. After \`submit_plan\` succeeds, end your turn; your session will be closed.`;
}

export function builderPrompt(task: Task, goal: Goal | null, resumed: { reason: string } | null): string {
  const steps = task.plan.map((s, i) => `${i + 1}. ${s.text} (${s.file})${s.progress === "done" ? " — done" : ""}`).join("\n");
  const done = task.doneWhen.map((d, i) => `${i + 1}. ${d.text} — proof: ${d.proof}${d.status === "proven" ? " (proven)" : ""}`).join("\n");
  const review = task.autoReview?.findings.filter((f) => f.status === "open");
  return `You are the builder for a software factory task, working in this git worktree on its own branch.

${brief(task, goal)}

## Approved plan (v${task.planVersion})
${task.planSummary ?? ""}
${steps}

## Done when
${done}${comments(task)}${changes(task)}${
    review?.length
      ? `\n\n## Review round ${task.autoReview!.rounds.length} asked for changes\n` + review.map((f) => `- [${f.severity}] (${f.id}) ${f.text}${f.file ? ` (${f.file})` : ""}`).join("\n")
      : ""
  }${resumed ? `\n\n## Picking up again\n${resumed.reason} Check \`git status\` and \`git log\` to see where you were, then carry on.` : ""}

Work through the steps in order. Call \`progress\` when you start and finish each step (step numbers from 1).
Commit as you go with clear messages. When a change request is applied, call \`progress\` with its id in \`applied\`.
For each Done when item, produce real evidence and call \`prove\` (item numbers from 1): paste the command and its output for terminal/tests proofs.
If you're stuck on a decision only a person can make, call \`ask\`, end your turn and wait. If you can't meet a proof or the fix grows past the plan, call \`raise_hand\`.
When every step is done and every item is proven, call \`finish\` with a short summary of what changed. The factory commits anything left, pushes and opens the review.`;
}

export function reviewerPrompt(task: Task, goal: Goal | null, base: string): string {
  const done = task.doneWhen
    .map((d, i) => `${i + 1}. ${d.text} — ${d.evidence ? `evidence (${d.evidence.kind}): ${d.evidence.summary}${d.evidence.output.length ? "\n   " + d.evidence.output.slice(-15).join("\n   ") : ""}` : "NO EVIDENCE"}`)
    .join("\n");
  const previous = task.autoReview?.findings.filter((f) => f.status === "open") ?? [];
  return `You are the review agent for a software factory task. You review; you do not change code.

${brief(task, goal)}

## The plan it was built to
${task.planSummary ?? ""}
${task.plan.map((s, i) => `${i + 1}. ${s.text} (${s.file})`).join("\n")}

## Done when, with the builder's evidence
${done}
${previous.length ? `\n## Open findings from earlier rounds (say which are fixed)\n${previous.map((f) => `- (${f.id}) [${f.severity}] ${f.text}`).join("\n")}\n` : ""}
Review the change with \`git diff origin/${base}...HEAD\` (and \`git log origin/${base}..HEAD\`). Answer three things:
1. Did it do the ask? One check per part of the brief: met, partial or missed.
2. Are the proofs real? One check per Done when item: does the evidence actually show it?
3. Code: bugs, missing cases, risky changes.

Then call \`submit_review\` once: verdict "passed" only with no blocker or major findings, otherwise "changesRequested".
List \`fixed\` with the ids of earlier findings this round resolves. End your turn after it succeeds.`;
}

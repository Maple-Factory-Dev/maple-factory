// What each factory session is told. Agents report back only through the `maple` MCP tools
// (tools.ts); the prompts say which, and when to stop.

import type { Goal, PromptAdditions, RiskClassifier, Role, SensitiveArea, Task } from "../wire.ts";
import { goalRepos, taskRepo } from "./repos.ts";
import type { BudgetUse } from "./policy.ts";

/** The anchor on a change request made because the branch didn't merge: "Didn't merge into <base>". */
export const MERGE_ANCHOR = "Didn't merge into";

const plain = (task: Task) => `${task.id} · ${task.title}`;

function brief(task: Task, goal: Goal | null) {
  return [
    `Task ${plain(task)}`,
    goal ? `Goal: ${goal.name}${goal.summary ? ` — ${goal.summary}` : ""}` : null,
    taskRepo(task, goal) ? `Repo: ${taskRepo(task, goal)}` : null,
    task.after.length ? `Builds on ${task.after.join(", ")}, merged before this starts building.` : null,
    "",
    "## Brief",
    task.brief.trim() || task.title,
    task.tickets.filter((t) => t.asContext).length
      ? "\n## Linked tickets\n" + task.tickets.filter((t) => t.asContext).map((t) => `- ${t.key}: ${t.title} (${t.status})`).join("\n")
      : null,
  ].filter((l) => l !== null).join("\n");
}

/** The longest a single prompt addition can be, so one can't crowd out the task itself. */
export const PROMPT_ADDITION_MAX = 4000;

/** Trimmed and capped, ready to save. */
export function cleanPrompts(p: PromptAdditions): PromptAdditions {
  const clean = (text: string | undefined) => (text ?? "").trim().slice(0, PROMPT_ADDITION_MAX).trim();
  return { planner: clean(p.planner), builder: clean(p.builder), reviewer: clean(p.reviewer) };
}

/** The org's, then the task's repo's, then the goal's instructions for this role: each adds to the ones before, never replaces them. */
function extra(role: Role, org: PromptAdditions | null, goal: Goal | null, repo: PromptAdditions | null) {
  const orgText = org?.[role]?.trim();
  const repoText = repo?.[role]?.trim();
  const goalText = goal?.prompts?.[role]?.trim();
  return (orgText ? `\n\n## Org instructions\n${orgText}` : "") + (repoText ? `\n\n## Repo instructions\n${repoText}` : "") + (goalText ? `\n\n## Goal instructions\n${goalText}` : "");
}

function changes(task: Task) {
  const queued = task.changes.filter((c) => c.status !== "applied");
  if (!queued.length) return "";
  return "\n\n## Change requests to apply\n" + queued.map((c) => `- (${c.id}) ${c.author}: ${c.text}${c.anchor ? ` [on: ${c.anchor}]` : ""}`).join("\n");
}

/** Another task building or in review in the same repo and base, and the files its branch changes so far. */
export interface Moving {
  id: string;
  title: string;
  state: string;
  files: string[];
}

/** The longest list of moving tasks, and of each one's files, a prompt carries. */
const MOVING_MAX = 10;
const MOVING_FILES_MAX = 15;

function moving(others: Moving[]) {
  if (!others.length) return "";
  const line = (m: Moving) => {
    const files = m.files.length ? m.files.slice(0, MOVING_FILES_MAX).join(", ") + (m.files.length > MOVING_FILES_MAX ? `, and ${m.files.length - MOVING_FILES_MAX} more` : "") : "no files pushed yet";
    return `- ${m.id} · ${m.title} (${m.state}): ${files}`;
  };
  return `\n\n## Work in flight in this repo\nThese tasks are building or in review against the same base and will merge around the same time. Where you can, keep clear of the files they change; where you can't, keep your edits there small so the merge stays easy.\n${others.slice(0, MOVING_MAX).map(line).join("\n")}`;
}

function comments(task: Task) {
  const recent = task.comments.slice(-10);
  if (!recent.length) return "";
  return "\n\n## Discussion so far\n" + recent.map((c) => `- ${c.author}${c.replyTo ? ` (in thread ${c.replyTo})` : ""}: ${c.text}`).join("\n");
}

/** The org's enabled risk checks, for the planner to judge and cite. */
function riskChecks(checks: SensitiveArea[]) {
  const on = checks.filter((c) => c.enabled);
  if (!on.length) return "";
  const line = (c: SensitiveArea) => {
    const what = [c.rule?.trim(), c.paths.length ? `touches ${c.paths.join(", ")}` : ""].filter(Boolean).join("; or ");
    return `- ${c.name} (${c.level}): ${what}`;
  };
  return `\n\n## Risk checks\nThe org's checks; each one that applies raises the change to at least its level. Path checks are also matched against the diff's files once there's code.\n${on.map(line).join("\n")}`;
}

export function plannerPrompt(task: Task, goal: Goal | null, org: PromptAdditions | null = null, inFlight: Moving[] = [], repo: PromptAdditions | null = null, checks: SensitiveArea[] = []): string {
  const others = goal ? goalRepos(goal).filter((r) => r.toLowerCase() !== taskRepo(task, goal)?.toLowerCase()) : [];
  return `You are the planner for a software factory task. You write the plan; you do NOT change code.

${brief(task, goal)}${extra("planner", org, goal, repo)}${riskChecks(checks)}${moving(inFlight)}${comments(task)}${changes(task)}${
    others.length
      ? `\n\n## The goal's other repos\n${others.map((r) => `- ${r}`).join("\n")}\nThis task changes ${taskRepo(task, goal)} only. If the work also needs changes in one of these, plan just this repo's part and list each other repo's part in \`otherRepos\` (repo, title, brief): it becomes its own task, planned and built there once this one merges.`
      : ""
  }

Read the repository (this worktree) to understand where the change goes. Then call the \`submit_plan\` tool once with:
- summary: two or three sentences on the approach.
- title (optional): a clearer title for the task, only when its current one ("${task.title}") is vague or misleading; it's renamed once the plan is approved.
- steps: 3–8 concrete steps, each with the main file it touches.
- doneWhen: 2–5 checks that prove it works, each with the proof kind the builder will produce (tests, terminal, screenshot or video).
- risk: low, medium or high, with reasons; in \`areas\`, name each risk check above that applies (its exact name), and say why in \`reasons\`.
- footprint: your estimate of files and lines changed.
- mockups: for UI changes, at least one screen mockup as a small self-contained HTML page (inline CSS, no scripts) of the changed screen,
  with numbered callouts in its notes; for CLI or API changes, a terminal mockup (lines with style command/output/highlight/dim/error,
  and callout numbers on the lines that change). Skip mockups for pure refactors.

If something essential is ambiguous, call \`ask\` with the question and a few options, then end your turn and wait: the answer will be typed here.
When the brief asks you to find work or propose tickets (e.g. "scan the iOS app for missing features and propose tickets"), call \`propose_tasks\` once with every proposal instead of writing a plan. Each becomes a draft in this goal for a person to accept, and this task closes (there's nothing to merge): end your turn after it. Don't build them yourself. When the work has to land in order (an epic), give each proposal \`after\` (#n for an earlier proposal in the call, or an existing task id) and the whole set one \`effort\` name: once approved, each starts building on its own after everything it waits on has merged.
${THREADS}
If the task can't be planned as asked, call \`raise_hand\`. After \`submit_plan\` succeeds, end your turn; your session will be closed.`;
}

/** When a queued change request is there because the reviewed branch didn't merge. */
function unmerged(task: Task) {
  const c = task.changes.find((c) => c.status !== "applied" && c.anchor?.startsWith(MERGE_ANCHOR));
  if (!c) return "";
  const base = c.anchor!.slice(MERGE_ANCHOR.length).trim();
  return `\n\n## It didn't merge
The branch already has the reviewed, approved work, but it doesn't merge into ${base}. Only bring it up to date with origin/${base} and resolve the conflicts (${c.id}); don't redo or extend the plan. Re-prove only the Done when items the conflict resolution touched, then call \`finish\`.`;
}

/** The task's time and cost budget, what's left of it, and to ask before going past it. Empty with both limits off. */
export function budgetSection(use: BudgetUse | null): string {
  if (!use || (use.allowMinutes == null && use.allowCostUsd == null)) return "";
  const parts: string[] = [];
  if (use.allowMinutes != null) parts.push(`${Math.max(0, Math.round(use.allowMinutes - use.minutes))} of its ${Math.round(use.allowMinutes)} minutes of agent time`);
  if (use.allowCostUsd != null) parts.push(`$${Math.max(0, use.allowCostUsd - use.costUsd).toFixed(2)} of its $${use.allowCostUsd.toFixed(2)}`);
  return `\n\n## Budget\nThis task has ${parts.join(" and ")} left (all its sessions count). As soon as it looks like you'll go past that (stuck proving something, say, or the fix keeps growing), call \`raise_hand\` with reason \`overBudget\`: where you are, what's left, and the options. Ask before you reach it, not after.`;
}

export function builderPrompt(task: Task, goal: Goal | null, resumed: { reason: string } | null, org: PromptAdditions | null = null, others: Moving[] = [], repo: PromptAdditions | null = null, checks: string[] = [], budget: BudgetUse | null = null): string {
  const steps = task.plan.map((s, i) => `${i + 1}. ${s.text} (${s.file})${s.progress === "done" ? " — done" : ""}`).join("\n");
  const done = task.doneWhen.map((d, i) => `${i + 1}. ${d.text} — proof: ${d.proof}${d.status === "proven" ? " (proven)" : ""}`).join("\n");
  const review = task.autoReview?.findings.filter((f) => f.status === "open");
  return `You are the builder for a software factory task, working in this git worktree on its own branch.

${brief(task, goal)}${extra("builder", org, goal, repo)}

## Approved plan (v${task.planVersion})
${task.planSummary ?? ""}
${steps}

## Done when
${done}${moving(others)}${comments(task)}${changes(task)}${
    review?.length
      ? `\n\n## Review round ${task.autoReview!.rounds.length} asked for changes\n` + review.map((f) => `- [${f.severity}] (${f.id}) ${f.text}${f.file ? ` (${f.file})` : ""}`).join("\n")
      : ""
  }${unmerged(task)}${checksSection(checks)}${budgetSection(budget)}${resumed ? `\n\n## Picking up again\n${resumed.reason} Check \`git status\` and \`git log\` to see where you were, then carry on.` : ""}

Work through the steps in order. Call \`progress\` when you start and finish each step (step numbers from 1).
Commit as you go with clear messages. When a change request is applied, call \`progress\` with its id in \`applied\`.
For each Done when item, produce real evidence and call \`prove\` (item numbers from 1): paste the command and its output for terminal/tests proofs.
${ARTIFACTS(task)}
${THREADS}
When the brief asks you to find work or propose tickets (e.g. "scan the iOS app for missing features and propose tickets"), call \`propose_tasks\` once with every proposal. Each becomes a draft in this goal for a person to accept; don't build them yourself. (Proposing from planning closes a task; once it's building, it carries on.)
If you're stuck on a decision only a person can make, call \`ask\`, end your turn and wait. If you can't meet a proof or the fix grows past the plan, call \`raise_hand\`.
When every step is done and every item is proven, call \`finish\` with a short summary of what changed. ${checks.length ? "The factory runs the repo's checks, then commits anything left (its git hooks run too), pushes and opens the review." : "The factory commits anything left, pushes and opens the review."}`;
}

/** Comment threads: people talking to the session mid-flight, answered with \`reply\`. */
const THREADS =
  "People can talk to you in the task's comment threads while you work: it arrives as \"<who> in comment thread <id>: …\" (and \`get_task\` lists any threads still waiting on an answer). Answer briefly with \`reply\` in that thread, then carry on with the work. It's conversation, not a change request.";

/** What \`share_artifact\` is for: something people look at, not evidence (proofs stay that). The builder
 *  also shares a "Change walkthrough" before \`finish\`, which the pull request lists (\`pullArtifacts\`). */
const ARTIFACTS = (task: Task, role: "builder" | "reviewer" = "builder") => {
  const where = `Save the file (HTML with everything inline and no network, SVG, PNG, PDF, Markdown, CSV…) under ~/.cache/maple-proof/${task.branch ?? "<this task's branch>"}/, never in the worktree.`;
  const share = `When a picture says it better than words, share it with \`share_artifact\`: a chart of results, a page that reproduces a bug, a visual walkthrough of a change. ${where} Proofs stay the evidence for Done when; artifacts are for people to look at, and the pull request lists each one.`;
  return role === "builder"
    ? `${share}\nBefore \`finish\`, share one artifact titled "${WALKTHROUGH}" with \`share_artifact\`: a self-contained page (HTML, or SVG/Markdown) showing what the change does — before/after for UI, a flow or diagram for logic, sample output for a CLI or API. After a review round, share it again under the same title to add a new version. Skip it only for a trivial one-file fix.`
    : `${share} You may add your own (e.g. "Review notes"); it's optional.`;
};

/** The builder's walkthrough artifact's title. */
export const WALKTHROUGH = "Change walkthrough";

/** The repo's checks, which a finish runs before anything is committed. */
function checksSection(checks: string[]): string {
  if (!checks.length) return "";
  return `\n\n## Checks\nThese must exit 0 in the worktree before \`finish\` is accepted; run them yourself first and fix what they find:\n${checks.map((c) => `- \`${c}\``).join("\n")}\nIf one fails when you finish, nothing is committed or pushed and its output is typed into this session: fix it, then call \`finish\` again.`;
}

/** The org's risk classifier, when its policy turns it on: the reviewer grades the diff against the org's prompt. */
function classifySection(c: RiskClassifier | null): string {
  if (!c?.enabled || !c.prompt.trim()) return "";
  return `
## Risk classification
Your org asks you to grade this change's risk against its own guidance:

${c.prompt.trim()}

Judge the diff against that guidance and fill \`classification\` in \`submit_review\` (required): \`level\` low, medium or high; \`humanReview\` true when a person should review the change before it merges; \`reasons\`, a short line each. It can only add sign-off, never remove what the policy already asks for.
`;
}

export function reviewerPrompt(task: Task, goal: Goal | null, base: string, org: PromptAdditions | null = null, repo: PromptAdditions | null = null, budget: BudgetUse | null = null, classifier: RiskClassifier | null = null): string {
  const done = task.doneWhen
    .map((d, i) => `${i + 1}. ${d.text} — ${d.evidence?.attested ? `ATTESTED by ${d.evidence.by}: ${d.evidence.reason ?? "(no reason given)"}` : d.evidence ? `evidence (${d.evidence.kind}): ${d.evidence.summary}${d.evidence.output.length ? "\n   " + d.evidence.output.slice(-15).join("\n   ") : ""}` : "NO EVIDENCE"}`)
    .join("\n");
  const previous = task.autoReview?.findings.filter((f) => f.status === "open") ?? [];
  const round = task.autoReview?.rounds.at(-1);
  const asked = round?.focus
    ? `\n## Asked for this round by ${round.by ?? "a teammate"}\n${round.focus}\n\nA teammate asked for this round with that focus: look into it first and report what you find there as findings, on top of the usual three questions below.\n`
    : "";
  return `You are the review agent for a software factory task. You review; you do not change code.

${brief(task, goal)}${extra("reviewer", org, goal, repo)}

## The plan it was built to
${task.planSummary ?? ""}
${task.plan.map((s, i) => `${i + 1}. ${s.text} (${s.file})`).join("\n")}

## Done when, with the builder's evidence
${done}${budgetSection(budget)}
${previous.length ? `\n## Open findings from earlier rounds (say which are fixed)\n${previous.map((f) => `- (${f.id}) [${f.severity}] ${f.text}`).join("\n")}\n` : ""}${asked}
Review the change with \`git diff origin/${base}...HEAD\` (and \`git log origin/${base}..HEAD\`). Answer three things:
1. Did it do the ask? One check per part of the brief: met, partial or missed.
2. Are the proofs real? One check per Done when item: does the evidence actually show it? An ATTESTED item was signed off by a person themselves: accept it as proven, don't flag its proof as not real.
3. Code: bugs, missing cases, risky changes.

${classifySection(classifier)}
Then call \`submit_review\` once: verdict "passed" only with no blocker or major findings, otherwise "changesRequested".
List \`fixed\` with the ids of earlier findings this round resolves. End your turn after it succeeds.
${ARTIFACTS(task, "reviewer")}
${THREADS}`;
}

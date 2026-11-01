// What the factory is working on, for @Maple in Slack: `@Maple status` (or "what's in progress") is
// answered with this straight from the server, and every other ask carries it in its agent's prompt.

import type { Goal, Task } from "../wire.ts";

/** Lines shown per group before "…and N more". */
export const GROUP_CAP = 8;

/** States with nothing in flight: done, set aside, or not yet started. */
const IDLE = new Set(["merged", "cancelled", "closed", "drafting", "backlog"]);

/** How long since `at`: "4m", "2h 5m", "3d". */
function since(at: number, now: number): string {
  const m = Math.max(0, Math.floor((now - at) / 60_000));
  if (m < 60) return `${m}m`;
  if (m < 24 * 60) return `${Math.floor(m / 60)}h${m % 60 ? ` ${m % 60}m` : ""}`;
  return `${Math.floor(m / (24 * 60))}d`;
}

const line = (t: Task, more: string[]) => `• *${t.id}* ${t.title.replace(/\s+/g, " ").slice(0, 100)}${more.length ? ` · ${more.join(" · ")}` : ""}`;

function group(name: string, lines: string[]): string | null {
  if (!lines.length) return null;
  const shown = lines.slice(0, GROUP_CAP);
  if (lines.length > GROUP_CAP) shown.push(`…and ${lines.length - GROUP_CAP} more`);
  return `*${name}*\n${shown.join("\n")}`;
}

/** The in-flight work of `goals` as Slack mrkdwn: building, queued (in `queued`'s order), in review, planning, and waiting on a person. */
export function workSummary(tasks: Task[], queued: Task[], goals: Goal[], now: number): string {
  const ids = new Set(goals.map((g) => g.id));
  const live = tasks.filter((t) => ids.has(t.goal) && !IDLE.has(t.state));
  const needs = live.filter((t) => t.hand || t.question);
  const rest = live.filter((t) => !t.hand && !t.question);
  const building = rest.filter((t) => t.state === "building" && t.worker);
  const order = new Map(queued.map((t, i) => [t.id, i]));
  const waiting = rest
    .filter((t) => t.state === "building" && !t.worker)
    .sort((a, b) => (order.get(a.id) ?? Infinity) - (order.get(b.id) ?? Infinity));
  const reviewing = rest.filter((t) => t.state === "reviewing");
  const planning = rest.filter((t) => t.state === "planning" || t.state === "awaitingApproval");
  const groups = [
    group("Building", building.map((t) => line(t, [t.owner, t.worker!.agent, `running ${since(t.worker!.startedAt, now)}`]))),
    group("Queued", waiting.map((t, i) => line(t, [order.has(t.id) ? `#${i + 1} in line` : "not in line", t.owner, ...(t.waiting ? [t.waiting] : [])]))),
    group("In review", reviewing.map((t) => {
      const failing = t.pr?.checks.filter((c) => c.status === "failed").length ?? 0;
      return line(t, [...(t.pr ? [`PR #${t.pr.number}`] : []), `reviews ${t.reviews.length}/${t.reviewsNeeded}`, ...(failing ? [`${failing} CI failing`] : []), ...(t.worker ? ["being reviewed"] : [])]);
    })),
    group("Planning / awaiting approval", planning.map((t) => line(t, [t.state === "planning" ? "planning" : `approvals ${t.approvals.length}/${t.approvalsNeeded}`, t.owner]))),
    group("Needs someone", needs.map((t) => line(t, [t.hand ? `hand raised (${t.hand.reason}) for ${t.hand.assignee}: ${t.hand.summary.replace(/\s+/g, " ").slice(0, 140)}` : `question: ${t.question!.text.replace(/\s+/g, " ").slice(0, 140)}`]))),
  ].filter((g): g is string => !!g);
  const scope = goals.length === 1 ? goals[0].name : goals.map((g) => g.name).join(", ");
  if (!groups.length) return `Nothing is in flight in ${scope} right now: nothing building, queued, in review or in planning.`;
  return `Work in flight in ${scope}:\n\n${groups.join("\n\n")}`;
}

/** Whether a mention asks what the factory is working on (`status`, "what's in progress", "what's queued"…), not a question about the code. */
export function wantsStatus(question: string): boolean {
  const said = question.replace(/[*_`~]/g, "").replace(/[’‘]/g, "'").replace(/[\s.!?:]+$/, "").replace(/\s+/g, " ").trim().toLowerCase();
  if (/^(status|queue|the queue|progress|in progress|in flight|wip)$/.test(said)) return true;
  if (/^(what'?s|what is|what are|whats) (the )?(status|queue)( (here|now|right now|today))?$/.test(said)) return true;
  return /^((so|hey|ok|okay),? )?(what'?s|what is|what are|whats|what all is|what's all|anything|is anything|(show( me)?|list)( what'?s| what is)?) (currently |still |being )?(in progress|in flight|queued|being built|building|in the queue|on the queue|in review|being worked on|getting built|cooking)( (here|now|right now|today|at the moment))?$/.test(said);
}

/**
 * One member's work as Slack mrkdwn, for `@Maple mine` and an ask's prompt: their own tasks in flight; plans and
 * PRs in goals they lead that still wait on their approval or review (not their own tasks, not ones they've already
 * approved or reviewed); and raised hands assigned to them or questions on their own tasks.
 */
export function mineSummary(tasks: Task[], goals: Goal[], login: string, now: number): string {
  const me = login.toLowerCase();
  const is = (who: string | null | undefined) => (who ?? "").toLowerCase() === me;
  const leads = new Set(goals.filter((g) => is(g.lead)).map((g) => g.id));
  const live = tasks.filter((t) => !IDLE.has(t.state));
  const mine = live.filter((t) => is(t.owner));
  const approve = live.filter((t) => t.state === "awaitingApproval" && leads.has(t.goal) && !is(t.owner) && !t.approvals.some(is) && t.approvals.length < t.approvalsNeeded);
  const review = live.filter((t) => t.state === "reviewing" && leads.has(t.goal) && !is(t.owner) && !t.reviews.some(is) && t.reviews.length < t.reviewsNeeded);
  const needs = live.filter((t) => (t.hand && is(t.hand.assignee)) || (!t.hand && t.question && is(t.owner)));
  const state = (t: Task) => (t.state === "building" ? (t.worker ? `building ${since(t.worker.startedAt, now)}` : "queued") : t.state === "awaitingApproval" ? `approvals ${t.approvals.length}/${t.approvalsNeeded}` : t.state === "reviewing" ? `in review${t.pr ? ` · PR #${t.pr.number}` : ""}` : t.state);
  const groups = [
    group("Your tasks in flight", mine.map((t) => line(t, [state(t)]))),
    group("Plans waiting on your approval", approve.map((t) => line(t, [t.owner, `approvals ${t.approvals.length}/${t.approvalsNeeded}`]))),
    group("PRs waiting on your review", review.map((t) => line(t, [t.owner, ...(t.pr ? [`PR #${t.pr.number}`] : []), `reviews ${t.reviews.length}/${t.reviewsNeeded}`]))),
    group("Waiting on you", needs.map((t) => line(t, [t.hand ? `hand raised (${t.hand.reason}): ${t.hand.summary.replace(/\s+/g, " ").slice(0, 140)}` : `question: ${t.question!.text.replace(/\s+/g, " ").slice(0, 140)}`]))),
  ].filter((g): g is string => !!g);
  if (!groups.length) return `Nothing is on your plate, @${login}: no tasks of yours in flight and nothing waiting on you.`;
  return `Your work, @${login}:\n\n${groups.join("\n\n")}`;
}

/** What `@Maple mine` says to someone whose Slack account isn't linked. */
export const LINK_HINT = "I don't know which factory member you are yet. Mention me with `link` and I'll send you a one-time link (only you see it) to connect your Slack account to your factory login. `@Maple help` lists everything I can do.";

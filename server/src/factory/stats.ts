// Factory statistics: every touchpoint (a hand, a question, a plan version, a steer, a review round, a
// merge…) is a row in `stats_events` as it happens, and `summarize` adds a window of them up for the
// Statistics page and `GET /api/stats`. Pure, so test/stats.test.ts runs it on fixtures.

import type { Goal, StatsCount, StatsSummary, Task } from "../wire.ts";

export type StatKind =
  | "plan.submitted" // detail: version
  | "plan.approved" // detail: version
  | "steer" // detail: state
  | "question.asked"
  | "question.answered" // detail: waitMs
  | "hand.raised" // detail: reason
  | "hand.resolved" // detail: reason, openMs, option
  | "prompt.answered" // detail: choice, tool
  | "review.round" // detail: number, verdict, found, findings [{kind, severity}], fixed
  | "session.restarted" // detail: cause
  | "session.ended" // detail: cause (an end nobody chose that stopped the task)
  | "merged" // detail: auto, cycleMs
  | "cancelled"; // detail: state

export interface StatEvent {
  id: string;
  at: number;
  kind: StatKind;
  task: string;
  goal: string;
  role: string | null;
  actor: string | null;
  /** What the kind records, and `inferred: true` on rows the backfill worked out from older task documents. */
  detail: Record<string, unknown>;
}

const DAY = 86_400_000;
/** What counts as a touchpoint: something that took a person, or made an agent go round again. */
const TOUCHPOINTS = new Set<StatKind>(["hand.raised", "question.asked", "steer", "prompt.answered", "session.restarted", "session.ended"]);

/** The stats an older task's document shows, for history from before `stats_events` (each flagged inferred). */
export function inferEvents(task: Task): Omit<StatEvent, "id">[] {
  const out: Omit<StatEvent, "id">[] = [];
  const add = (at: number, kind: StatKind, role: string | null, actor: string | null, detail: Record<string, unknown> = {}) =>
    out.push({ at, kind, task: task.id, goal: task.goal, role, actor, detail: { ...detail, inferred: true } });
  const events = task.events ?? [];
  let version = 0;
  for (const e of events) {
    const plan = /^(?:wrote the plan|revised the plan \(v(\d+)\))$/.exec(e.text);
    if (plan) {
      version = plan[1] ? Number(plan[1]) : 1;
      add(e.at, "plan.submitted", "planner", null, { version });
    } else if (e.text === "approved the plan") add(e.at, "plan.approved", null, e.who, { version: version || 1 });
    else if (e.text === "raised a hand") add(e.at, "hand.raised", e.who, null, { reason: "needsInput" });
    else if (e.text.startsWith("stopped and needs a hand: ")) add(e.at, "hand.raised", e.who, null, { reason: "sessionEnded" });
    else if (e.text.startsWith("asked: ")) add(e.at, "question.asked", e.who, null);
    else if (/^(allowed|denied) /.test(e.text)) add(e.at, "prompt.answered", null, e.who, { choice: e.text.startsWith("allowed") ? "yes" : "no" });
    else if (/ended \(.+\); starting it again$/.test(e.text)) add(e.at, "session.restarted", null, null, { cause: "unknown" });
  }
  // Plan versions the events lost (they're capped): the document still says how many there were.
  if (!out.some((e) => e.kind === "plan.submitted")) {
    for (let v = 1; v <= task.planVersion; v++) add(task.createdAt, "plan.submitted", "planner", null, { version: v });
  }
  if (task.approvals.length && task.state !== "awaitingApproval" && !out.some((e) => e.kind === "plan.approved")) {
    add(task.createdAt, "plan.approved", null, task.approvals[0], { version: Math.max(1, task.planVersion) });
  }
  for (const c of task.changes ?? []) add(c.at, "steer", null, c.author, {});
  for (const r of task.autoReview?.rounds ?? []) {
    if (r.verdict === "inProgress") continue;
    const findings = (task.autoReview?.findings ?? []).filter((f) => f.raisedIn === r.number).map((f) => ({ kind: f.kind, severity: f.severity }));
    add(r.at, "review.round", "reviewer", null, { number: r.number, verdict: r.verdict, found: r.found, findings });
  }
  if (task.state === "merged") {
    const at = [...events].reverse().find((e) => e.text.startsWith("merged into"))?.at ?? task.updatedAt;
    const auto = events.some((e) => e.who === "factory" && e.text.startsWith("auto-merged"));
    add(at, "merged", null, auto ? "factory" : null, { auto, cycleMs: at - task.createdAt });
  }
  if (task.state === "cancelled") add(task.updatedAt, "cancelled", null, null, {});
  return out;
}

export interface SummarizeOptions {
  days: number;
  goal?: string | null;
  goals?: Goal[];
  now?: number;
}

/** Totals, rates and medians over the last `days`, for one goal or all of them. */
export function summarize(all: StatEvent[], tasks: Task[], opts: SummarizeOptions): StatsSummary {
  const at = opts.now ?? Date.now();
  const since = at - opts.days * DAY;
  const goal = opts.goal || null;
  const byId = new Map(tasks.map((t) => [t.id, t]));
  const scoped = goal ? all.filter((e) => e.goal === goal) : all;
  const events = scoped.filter((e) => e.at >= since && e.at <= at);
  const of = (kind: StatKind, list = events) => list.filter((e) => e.kind === kind);

  const merges = of("merged");
  const approvals = of("plan.approved");
  const hands = of("hand.raised");
  const resolved = of("hand.resolved");
  const steers = of("steer");
  const rounds = of("review.round");
  const findings = rounds.flatMap((r) => (r.detail.findings as { kind: string; severity: string }[] | undefined) ?? []);
  // Review rounds per merge count every round the merged tasks had, not only the window's.
  const mergedIds = new Set(merges.map((e) => e.task));
  const roundsOfMerged = of("review.round", scoped).filter((e) => mergedIds.has(e.task)).length;
  const touched = new Set(events.map((e) => e.task));
  const handsOpen = tasks.filter((t) => t.hand && (!goal || t.goal === goal)).length;
  const created = tasks.filter((t) => t.createdAt >= since && t.createdAt <= at && (!goal || t.goal === goal)).length;

  const approvalVersions = approvals.map((e) => num(e.detail.version) || 1);
  const goalName = new Map((opts.goals ?? []).map((g) => [g.id, g.name]));

  const daily = [];
  for (let d = opts.days - 1; d >= 0; d--) {
    const start = startOfDay(at) - d * DAY;
    const inDay = (e: StatEvent) => e.at >= start && e.at < start + DAY;
    daily.push({ day: new Date(start).toISOString().slice(0, 10), merges: merges.filter(inDay).length, hands: hands.filter(inDay).length });
  }

  const goalRows = group(events, (e) => e.goal).map(([id, list]) => ({
    goal: id,
    name: goalName.get(id) ?? id,
    tasks: new Set(list.map((e) => e.task)).size,
    merged: of("merged", list).length,
    hands: of("hand.raised", list).length,
    steers: of("steer", list).length,
    reviewRounds: of("review.round", list).length,
    cycleMedianMs: median(of("merged", list).map((e) => num(e.detail.cycleMs))),
  })).sort((a, b) => b.merged - a.merged || b.tasks - a.tasks);

  const agentRows = group(events, (e) => byId.get(e.task)?.agent ?? "unknown").map(([agent, list]) => ({
    agent,
    tasks: new Set(list.map((e) => e.task)).size,
    merged: of("merged", list).length,
    hands: of("hand.raised", list).length,
    steers: of("steer", list).length,
    reviewRounds: of("review.round", list).length,
    firstTryApproval: rate(of("plan.approved", list).map((e) => (num(e.detail.version) || 1) === 1)),
  })).sort((a, b) => b.tasks - a.tasks);

  const topTasks = group(events, (e) => e.task).map(([id, list]) => {
    const t = byId.get(id);
    return {
      task: id,
      title: t?.title ?? id,
      goal: t?.goal ?? list[0].goal,
      state: t?.state ?? "cancelled",
      touchpoints: list.filter((e) => TOUCHPOINTS.has(e.kind)).length + of("review.round", list).filter((e) => e.detail.verdict !== "passed").length,
      hands: of("hand.raised", list).length,
      steers: of("steer", list).length,
      questions: of("question.asked", list).length,
      reviewRounds: of("review.round", list).length,
    };
  }).filter((r) => r.touchpoints > 0).sort((a, b) => b.touchpoints - a.touchpoints || a.task.localeCompare(b.task)).slice(0, 10);

  return {
    days: opts.days,
    goal,
    since,
    generatedAt: at,
    inferred: events.filter((e) => e.detail.inferred).length,
    totals: {
      merged: merges.length,
      autoMerged: merges.filter((e) => e.detail.auto === true).length,
      cancelled: of("cancelled").length,
      created,
      tasksTouched: touched.size,
      handsRaised: hands.length,
      handsOpen,
      questions: of("question.asked").length,
      steers: steers.length,
      prompts: of("prompt.answered").length,
      restarts: of("session.restarted").length,
      reviewRounds: rounds.length,
      findings: findings.length,
      planVersions: of("plan.submitted").length,
      approvals: approvals.length,
      cycleMedianMs: median(merges.map((e) => num(e.detail.cycleMs))),
      handOpenMedianMs: median(resolved.map((e) => num(e.detail.openMs))),
      answerMedianMs: median(of("question.answered").map((e) => num(e.detail.waitMs))),
      firstTryApproval: rate(approvalVersions.map((v) => v === 1)),
      avgPlanVersions: approvalVersions.length ? round2(approvalVersions.reduce((a, b) => a + b, 0) / approvalVersions.length) : null,
      reviewRoundsPerMerge: merges.length ? round2(roundsOfMerged / merges.length) : null,
      steersPerTask: touched.size ? round2(steers.length / touched.size) : null,
    },
    handsByReason: counts(hands, (e) => String(e.detail.reason ?? "unknown"), (key) => median(resolved.filter((r) => r.detail.reason === key).map((r) => num(r.detail.openMs)))),
    findingsByKind: counts(findings, (f) => f.kind),
    findingsBySeverity: counts(findings, (f) => f.severity),
    restartsByCause: counts([...of("session.restarted"), ...of("session.ended")], (e) => String(e.detail.cause ?? "unknown")),
    prompts: counts(of("prompt.answered"), (e) => String(e.detail.choice ?? "unknown")),
    reviewVerdicts: counts(rounds, (e) => String(e.detail.verdict ?? "unknown")),
    daily,
    goals: goalRows,
    agents: agentRows,
    topTasks,
  };
}

export function median(values: number[]): number | null {
  if (!values.length) return null;
  const s = [...values].sort((a, b) => a - b);
  const mid = s.length >> 1;
  return s.length % 2 ? s[mid] : Math.round((s[mid - 1] + s[mid]) / 2);
}

function rate(hits: boolean[]): number | null {
  return hits.length ? round2(hits.filter(Boolean).length / hits.length) : null;
}

function counts<T>(list: T[], key: (x: T) => string, ms?: (key: string) => number | null): StatsCount[] {
  return group(list, key).map(([k, xs]) => ({ key: k, count: xs.length, medianMs: ms ? ms(k) : null })).sort((a, b) => b.count - a.count || a.key.localeCompare(b.key));
}

function group<T>(list: T[], key: (x: T) => string): [string, T[]][] {
  const m = new Map<string, T[]>();
  for (const x of list) {
    const k = key(x);
    m.set(k, [...(m.get(k) ?? []), x]);
  }
  return [...m.entries()];
}

const num = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : 0);
const round2 = (n: number) => Math.round(n * 100) / 100;
const startOfDay = (ms: number) => ms - (ms % DAY);

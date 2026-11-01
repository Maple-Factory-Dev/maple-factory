// How much sign-off a change needs: its risk, from the planner's read, the risk checks it trips (path
// checks against the diff's files, rule checks the planner cites) and its size against the PR budget,
// then the policy's approvals, reviews and auto-merge for that level. Every reason is kept as a factor
// so people can see why a change is low, medium or high. This one is enforced; the apps show its factors.

import type { RiskAcceptance, RiskFactor, RiskLevel, RiskPolicy, SensitiveArea, Task } from "../wire.ts";

/** A task's time budget when the policy doesn't say. */
export const DEFAULT_TASK_MINUTES = 60;

export const DEFAULT_POLICY: RiskPolicy = {
  maxFiles: 12,
  maxLines: 500,
  areas: [
    { name: "Auth", paths: ["lib/auth/**", "app/api/auth/**"], level: "high", enabled: true },
    { name: "Billing", paths: ["lib/billing/**", "app/api/billing/**"], level: "high", enabled: true },
    { name: "Migrations", paths: ["db/migrations/**"], level: "medium", enabled: true },
  ],
  planApprovals: { low: 1, medium: 1, high: 2 },
  finalReviews: { low: 0, medium: 1, high: 2 },
  autoMerge: { low: true, medium: false, high: false },
  autoFixMerges: true,
  autoMerges: true,
  scoutItems: 3,
  taskMinutes: DEFAULT_TASK_MINUTES,
  taskCostUsd: null,
};

const ORDER: RiskLevel[] = ["low", "medium", "high"];
const max = (a: RiskLevel, b: RiskLevel): RiskLevel => (ORDER.indexOf(a) >= ORDER.indexOf(b) ? a : b);

export interface Assessment {
  level: RiskLevel;
  /// The policy's names for the risk checks it trips.
  areas: string[];
  /// Every reason behind the level, highest first.
  factors: RiskFactor[];
  approvals: number;
  reviews: number;
  autoMerge: boolean;
  /// Set when a goal's acceptance is what lets it merge without people.
  accepted: boolean;
}

/** Whether a path matches a glob: `**` spans folders, `*` and `?` stay within one; a bare folder matches what's under it. */
export function matchesGlob(path: string, glob: string): boolean {
  const g = glob.trim().replace(/^\.?\//, "");
  if (!g) return false;
  if (!/[*?]/.test(g)) return path === g || path.startsWith(g.endsWith("/") ? g : `${g}/`);
  let re = "";
  for (let i = 0; i < g.length; i++) {
    const c = g[i];
    if (c === "*" && g[i + 1] === "*") {
      i++;
      if (g[i + 1] === "/") { i++; re += "(?:.*/)?"; } else re += ".*";
    } else if (c === "*") re += "[^/]*";
    else if (c === "?") re += "[^/]";
    else re += c.replace(/[.+^${}()|[\]\\]/g, "\\$&");
  }
  return new RegExp(`^${re}$`).test(path);
}

const isRule = (a: SensitiveArea) => !!a.rule?.trim();

export function assess(task: Task, policy: RiskPolicy, acceptance: RiskAcceptance | undefined): Assessment {
  const named = (task.risk?.areas ?? []).map((a) => a.toLowerCase().trim());
  const files = task.diff?.files;
  const factors: RiskFactor[] = [];
  // The planner's level, not one the policy raised it to before: applyPolicy writes the assessed level back.
  const planned = task.risk?.factors?.find((f) => f.source === "planner")?.level ?? task.risk?.level ?? "low";
  const reasons = task.risk?.reasons ?? [];
  factors.push({ source: "planner", label: "The planner's read", level: planned, detail: reasons.length ? reasons.join("; ") : null, files: null });
  const areas: SensitiveArea[] = [];
  for (const a of policy.areas) {
    if (!a.enabled) continue;
    const cited = named.includes(a.name.toLowerCase().trim());
    const hits = files ? files.filter((f) => a.paths.some((g) => matchesGlob(f, g))) : [];
    // Path checks go by the diff once there is one; before that, and for rules, by what the planner cited.
    if (hits.length) factors.push({ source: "check", label: a.name, level: a.level, detail: isRule(a) ? a.rule! : null, files: hits });
    else if (cited && (isRule(a) || !files)) factors.push({ source: "check", label: a.name, level: a.level, detail: isRule(a) ? a.rule! : "Named by the planner; no diff to check yet", files: null });
    else continue;
    areas.push(a);
  }
  const size = task.diff ? { files: task.diff.files.length, lines: task.diff.added + task.diff.removed } : task.footprint ?? { files: 0, lines: 0 };
  const over = size.files > policy.maxFiles || size.lines > policy.maxLines;
  factors.push({
    source: "size",
    label: `${task.diff ? "" : "About "}${size.files} file${size.files === 1 ? "" : "s"}, ${size.lines} line${size.lines === 1 ? "" : "s"}`,
    level: over ? "medium" : "low",
    detail: `${over ? "Over" : "Within"} the PR budget of ${policy.maxFiles} files and ${policy.maxLines} lines`,
    files: null,
  });
  const level = factors.reduce<RiskLevel>((l, f) => max(l, f.level), "low");
  const accepted = acceptance ? ORDER.indexOf(level) <= ORDER.indexOf(acceptance.upTo) : false;
  if (acceptance) {
    factors.push({
      source: "acceptance",
      label: `Goal accepts risk up to ${acceptance.upTo}`,
      level: acceptance.upTo,
      detail: accepted ? `Accepted by ${acceptance.by}: no final review needed` : `Accepted by ${acceptance.by}, but this change is ${level}`,
      files: null,
    });
  }
  // Highest first; ties keep their order (planner, checks, size, acceptance).
  factors.sort((a, b) => ORDER.indexOf(b.level) - ORDER.indexOf(a.level));
  return {
    level,
    areas: areas.map((a) => a.name),
    factors,
    approvals: policy.planApprovals[level] ?? 1,
    reviews: accepted ? 0 : (policy.finalReviews[level] ?? 1),
    // Off for the whole org beats both the level's checkbox and a goal's acceptance.
    autoMerge: policy.autoMerges !== false && (accepted || (policy.autoMerge[level] ?? false)),
    accepted,
  };
}

export function validPolicy(p: RiskPolicy): string | null {
  if (!(p.maxFiles >= 1 && p.maxLines >= 1)) return "The PR budget needs at least one file and one line.";
  if (p.scoutItems != null && !(Number.isInteger(p.scoutItems) && p.scoutItems >= 1 && p.scoutItems <= 10)) return "A Scout run picks 1 to 10 items.";
  if (p.taskMinutes != null && !(Number.isInteger(p.taskMinutes) && (p.taskMinutes === 0 || (p.taskMinutes >= 5 && p.taskMinutes <= 1440)))) {
    return "A task's time budget is 5 to 1440 minutes, or 0 for none.";
  }
  if (p.taskCostUsd != null && !(Number.isFinite(p.taskCostUsd) && p.taskCostUsd >= 0)) return "A task's cost budget can't be below $0.";
  for (const level of ORDER) {
    if (!(p.planApprovals[level] >= 0) || !(p.finalReviews[level] >= 0)) return `Say how many approvals and reviews ${level} risk needs.`;
  }
  const names = new Set<string>();
  for (const a of p.areas) {
    const name = a.name?.trim().toLowerCase();
    if (!name) return "Every risk check needs a name.";
    if (names.has(name)) return `There are two risk checks named ${a.name.trim()}.`;
    names.add(name);
    if (!a.paths.some((g) => g.trim()) && !isRule(a)) return `Give ${a.name.trim()} some paths or a rule.`;
    if (!ORDER.includes(a.level)) return `Give ${a.name.trim()} a level.`;
  }
  return null;
}

/** What a task has used of its budget (policy.taskMinutes and taskCostUsd), from its sessions and their costs. */
export interface BudgetUse {
  /** Agent minutes so far: each session's end (or now, while it runs) minus its start. */
  minutes: number;
  /** Dollars so far, from the sessions that report a cost. */
  costUsd: number;
  /** What it may use before it asks: one budget on from where it was last given more (0 at first). Null: that limit is off. */
  allowMinutes: number | null;
  allowCostUsd: number | null;
  /** Which limit it's past, time first; null while it's within both. */
  over: "time" | "cost" | null;
}

/** A task's time budget in minutes; null when it's off. */
export const budgetMinutes = (policy: RiskPolicy): number | null => {
  const m = policy.taskMinutes ?? DEFAULT_TASK_MINUTES;
  return m > 0 ? m : null;
};

/** A task's cost budget in dollars; null when there's none. 0 asks before any spend. */
export const budgetCostUsd = (policy: RiskPolicy): number | null => policy.taskCostUsd ?? null;

/** What a task had used when a person last gave it more budget; its next limit is one budget on from there,
 *  so time spent waiting on that person doesn't eat the new budget. */
export interface BudgetBase { minutes: number; costUsd: number }

/** Pure: how much of its budget a task has used. `base` is where it was when it was last given more
 *  (an overBudget budget hand answered with anything but Cancel); none, it's counted from the start. */
export function budgetUse(
  sessions: { started: number; ended: number | null }[],
  costs: { costUsd: number | null }[],
  policy: RiskPolicy,
  base: BudgetBase | null = null,
  at = Date.now(),
): BudgetUse {
  const ms = sessions.reduce((sum, s) => sum + Math.max(0, (s.ended ?? at) - s.started), 0);
  const minutes = ms / 60_000;
  const costUsd = costs.reduce((sum, c) => sum + (c.costUsd ?? 0), 0);
  const m = budgetMinutes(policy);
  const c = budgetCostUsd(policy);
  const allowMinutes = m == null ? null : (base?.minutes ?? 0) + m;
  const allowCostUsd = c == null ? null : (base?.costUsd ?? 0) + c;
  const over = allowMinutes != null && minutes >= allowMinutes ? "time" : allowCostUsd != null && costUsd > 0 && costUsd >= allowCostUsd ? "cost" : null;
  return { minutes, costUsd, allowMinutes, allowCostUsd, over };
}

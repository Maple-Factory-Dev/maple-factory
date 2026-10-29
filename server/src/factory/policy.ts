// How much sign-off a change needs: its risk, from the planner's read, the sensitive areas it
// touches and its size against the PR budget, then the policy's approvals, reviews and auto-merge
// for that level. The apps show the same assessment (RiskModel.swift); this one is enforced.

import type { RiskAcceptance, RiskLevel, RiskPolicy, Task } from "../wire.ts";

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
};

const ORDER: RiskLevel[] = ["low", "medium", "high"];
const max = (a: RiskLevel, b: RiskLevel): RiskLevel => (ORDER.indexOf(a) >= ORDER.indexOf(b) ? a : b);

export interface Assessment {
  level: RiskLevel;
  /// The policy's names for the sensitive areas it touches.
  areas: string[];
  approvals: number;
  reviews: number;
  autoMerge: boolean;
  /// Set when a goal's acceptance is what lets it merge without people.
  accepted: boolean;
}

export function assess(task: Task, policy: RiskPolicy, acceptance: RiskAcceptance | undefined): Assessment {
  const named = (task.risk?.areas ?? []).map((a) => a.toLowerCase());
  const areas = policy.areas.filter((a) => a.enabled && named.includes(a.name.toLowerCase()));
  const size = task.diff ? { files: task.diff.files.length, lines: task.diff.added + task.diff.removed } : task.footprint ?? { files: 0, lines: 0 };
  let level: RiskLevel = task.risk?.level ?? "low";
  for (const a of areas) level = max(level, a.level);
  if (size.files > policy.maxFiles || size.lines > policy.maxLines) level = max(level, "medium");
  const accepted = acceptance ? ORDER.indexOf(level) <= ORDER.indexOf(acceptance.upTo) : false;
  return {
    level,
    areas: areas.map((a) => a.name),
    approvals: policy.planApprovals[level] ?? 1,
    reviews: accepted ? 0 : (policy.finalReviews[level] ?? 1),
    autoMerge: accepted || (policy.autoMerge[level] ?? false),
    accepted,
  };
}

export function validPolicy(p: RiskPolicy): string | null {
  if (!(p.maxFiles >= 1 && p.maxLines >= 1)) return "The PR budget needs at least one file and one line.";
  for (const level of ORDER) {
    if (!(p.planApprovals[level] >= 0) || !(p.finalReviews[level] >= 0)) return `Say how many approvals and reviews ${level} risk needs.`;
  }
  return null;
}

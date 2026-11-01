// A task's risk at a glance on the web, the way the Mac app's Risk box shows it: the level, why, the change's
// size against the policy's budget, the sign-off it needs, the goal's risk acceptance and the classifier's
// grade. Pure, so the tests can call it; every field is safe to leave out for older servers.

const LABELS = { low: "Low risk", medium: "Medium risk", high: "High risk" };

/** The header pill for a risk level: its label and class. */
export function riskBadge(level) {
  const known = LABELS[level] ? level : "medium";
  return { label: LABELS[known], class: `risk-pill risk-${known}` };
}

const count = (n) => (typeof n === "number" && Number.isFinite(n) ? n : null);

/** Files and lines from the diff once there is one, else the planner's footprint (estimated), against the budget. */
function budgetOf(task, policy) {
  const maxFiles = count(policy?.maxFiles);
  const maxLines = count(policy?.maxLines);
  if (maxFiles == null && maxLines == null) return null;
  let files, lines, estimated;
  if (task.diff) {
    files = (task.diff.files ?? []).length;
    lines = (task.diff.added ?? 0) + (task.diff.removed ?? 0);
    estimated = false;
  } else if (task.footprint) {
    files = task.footprint.files ?? 0;
    lines = task.footprint.lines ?? 0;
    estimated = true;
  } else return null;
  const meter = (used, max) => max == null ? null : { used, max, over: used > max };
  const out = { files: meter(files, maxFiles), lines: meter(lines, maxLines), estimated };
  return { ...out, over: !!(out.files?.over || out.lines?.over) };
}

/** What sign-off a change at `level` needs under the policy, and how much the task has. */
function signOffOf(task, level, policy) {
  if (!policy) return null;
  const planApprovals = count(policy.planApprovals?.[level]);
  const finalReviews = count(policy.finalReviews?.[level]);
  const factoryOff = policy.autoMerges === false;
  const levelAuto = policy.autoMerge?.[level];
  const autoMerge = factoryOff
    ? { on: false, label: "Off for the factory" }
    : levelAuto == null ? null : { on: !!levelAuto, label: levelAuto ? "On" : "Off at this level" };
  if (planApprovals == null && finalReviews == null && !autoMerge) return null;
  return {
    planApprovals: planApprovals == null ? null : { needed: task.approvalsNeeded ?? planApprovals, policy: planApprovals, have: (task.approvals ?? []).length },
    finalReviews: finalReviews == null ? null : { needed: task.reviewsNeeded ?? finalReviews, policy: finalReviews, have: (task.reviews ?? []).length },
    autoMerge,
  };
}

/** Everything the Risk card shows for `task`; null when the task has no risk yet. */
export function riskDetails(task, policy, acceptances) {
  const risk = task?.risk;
  if (!risk) return null;
  const level = risk.level;
  const factors = (risk.factors ?? []).filter(Boolean);
  // Without the server's factors, the planner's areas and reasons.
  const fallback = factors.length ? null : { areas: risk.areas ?? [], reasons: risk.reasons ?? [] };
  const accepted = (acceptances ?? []).find((a) => a && a.goal === task.goal);
  const c = task.classification;
  return {
    level,
    badge: riskBadge(level),
    factors,
    fallback,
    budget: budgetOf(task, policy),
    signOff: signOffOf(task, level, policy),
    acceptance: accepted ? { upTo: accepted.upTo, by: accepted.by ?? null, note: accepted.note ?? null } : null,
    classifier: c ? {
      level: c.level,
      humanReview: !!c.humanReview,
      note: c.humanReview ? "Asks for a person to review" : null,
      reasons: c.reasons ?? [],
    } : null,
  };
}

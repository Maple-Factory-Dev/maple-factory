// A task's pull request card on the web, the way the Mac app's PullRequestCard shows it (PullRequestViews.swift):
// the checks' summary and bar, the state label and which checks can run again. Pure, so the tests can call it;
// only `octicon` touches the DOM.

/** Finished tasks: no Recheck or Re-run on their pull request. */
const FINISHED = new Set(["merged", "cancelled", "closed"]);
export const taskFinished = (task) => FINISHED.has(task?.state);

/** What the checks add up to: counts, tone, "2 failing" / "4 of 5 passed" and the bar's parts in order. */
export function checkSummary(checks) {
  const n = { passed: 0, failed: 0, running: 0, queued: 0 };
  for (const c of checks ?? []) if (c.status in n) n[c.status] += 1;
  const total = n.passed + n.failed + n.running + n.queued;
  const tone = total === 0 ? "none" : n.failed > 0 ? "failed" : n.running + n.queued > 0 ? "running" : "passed";
  const headline = tone === "none" ? "No checks"
    : tone === "passed" ? (total === 1 ? "Check passed" : "All checks passed")
      : tone === "failed" ? `${n.failed} failing`
        : n.running > 0 ? `${n.running} running` : `${n.queued} queued`;
  const segments = ["passed", "failed", "running", "queued"].filter((s) => n[s] > 0).map((status) => ({ status, count: n[status] }));
  return { ...n, total, tone, headline, detail: `${n.passed} of ${total} passed`, segments };
}

const STATE_LABEL = { open: "Open", draft: "Draft", merged: "Merged", closed: "Closed" };

/** The pull request's state as it reads: a cancelled task's still-open pull request reads Closed. */
export function prState(pr, task) {
  if (task?.state === "cancelled" && (pr.state === "open" || pr.state === "draft")) return "closed";
  return STATE_LABEL[pr.state] ? pr.state : "open";
}

/** The filled label: its words, Octicon and class. */
export function prStateLabel(pr, task) {
  const s = prState(pr, task);
  return { state: s, label: STATE_LABEL[s], icon: `pr-${s}`, class: `pr-state pr-state-${s}` };
}

/** A finished check, on a GitHub pull request that's still open, of a task still going. */
export function canRerun(check, pr, task) {
  return (check.status === "passed" || check.status === "failed") && !!pr.url
    && (pr.state === "open" || pr.state === "draft") && !taskFinished(task);
}

/** The check's own run, or the pull request's Checks tab when the server didn't say; none for a local repo. */
export function checkHref(check, pr) {
  return check.url || (pr.url ? `${pr.url}/checks` : null);
}

/** "Failed · 1m 2s", "1m 2s", "Running…" or "Queued". */
export function checkStatusText(check) {
  switch (check.status) {
    case "passed": return check.duration ?? "Passed";
    case "failed": return check.duration ? `Failed · ${check.duration}` : "Failed";
    case "running": return "Running…";
    default: return "Queued";
  }
}

// GitHub's Octicons, 16×16 (github.com/primer/octicons, MIT licence, (c) GitHub Inc.), copied from the Mac
// app's Resources/*.svg: mark-github, git-pull-request, git-pull-request-draft, git-merge, git-pull-request-closed.
export const OCTICONS = {
  github: "M6.766 11.328c-2.063-.25-3.516-1.734-3.516-3.656 0-.781.281-1.625.75-2.188-.203-.515-.172-1.609.063-2.062.625-.078 1.468.25 1.968.703.594-.187 1.219-.281 1.985-.281.765 0 1.39.094 1.953.265.484-.437 1.344-.765 1.969-.687.218.422.25 1.515.046 2.047.5.593.766 1.39.766 2.203 0 1.922-1.453 3.375-3.547 3.64.531.344.89 1.094.89 1.954v1.625c0 .468.391.734.86.547C13.781 14.359 16 11.53 16 8.03 16 3.61 12.406 0 7.984 0 3.563 0 0 3.61 0 8.031a7.88 7.88 0 0 0 5.172 7.422c.422.156.828-.125.828-.547v-1.25c-.219.094-.5.156-.75.156-1.031 0-1.64-.562-2.078-1.609-.172-.422-.36-.672-.719-.719-.187-.015-.25-.093-.25-.187 0-.188.313-.328.625-.328.453 0 .844.281 1.25.86.313.452.64.655 1.031.655s.641-.14 1-.5c.266-.265.47-.5.657-.656",
  "pr-open": "M1.5 3.25a2.25 2.25 0 1 1 3 2.122v5.256a2.251 2.251 0 1 1-1.5 0V5.372A2.25 2.25 0 0 1 1.5 3.25Zm5.677-.177L9.573.677A.25.25 0 0 1 10 .854V2.5h1A2.5 2.5 0 0 1 13.5 5v5.628a2.251 2.251 0 1 1-1.5 0V5a1 1 0 0 0-1-1h-1v1.646a.25.25 0 0 1-.427.177L7.177 3.427a.25.25 0 0 1 0-.354ZM3.75 2.5a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Zm0 9.5a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Zm8.25.75a.75.75 0 1 0 1.5 0 .75.75 0 0 0-1.5 0Z",
  "pr-draft": "M3.25 1A2.25 2.25 0 0 1 4 5.372v5.256a2.251 2.251 0 1 1-1.5 0V5.372A2.251 2.251 0 0 1 3.25 1Zm9.5 14a2.25 2.25 0 1 1 0-4.5 2.25 2.25 0 0 1 0 4.5ZM2.5 3.25a.75.75 0 1 0 1.5 0 .75.75 0 0 0-1.5 0ZM3.25 12a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Zm9.5 0a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5ZM14 7.5a1.25 1.25 0 1 1-2.5 0 1.25 1.25 0 0 1 2.5 0Zm0-4.25a1.25 1.25 0 1 1-2.5 0 1.25 1.25 0 0 1 2.5 0Z",
  "pr-merged": "M5.45 5.154A4.25 4.25 0 0 0 9.25 7.5h1.378a2.251 2.251 0 1 1 0 1.5H9.25A5.734 5.734 0 0 1 5 7.123v3.505a2.25 2.25 0 1 1-1.5 0V5.372a2.25 2.25 0 1 1 1.95-.218ZM4.25 13.5a.75.75 0 1 0 0-1.5.75.75 0 0 0 0 1.5Zm8.5-4.5a.75.75 0 1 0 0-1.5.75.75 0 0 0 0 1.5ZM5 3.25a.75.75 0 1 0 0 .005V3.25Z",
  "pr-closed": "M3.25 1A2.25 2.25 0 0 1 4 5.372v5.256a2.251 2.251 0 1 1-1.5 0V5.372A2.251 2.251 0 0 1 3.25 1Zm9.5 5.5a.75.75 0 0 1 .75.75v3.378a2.251 2.251 0 1 1-1.5 0V7.25a.75.75 0 0 1 .75-.75Zm-2.03-5.273a.75.75 0 0 1 1.06 0l.97.97.97-.97a.748.748 0 0 1 1.265.332.75.75 0 0 1-.205.729l-.97.97.97.97a.751.751 0 0 1-.018 1.042.751.751 0 0 1-1.042.018l-.97-.97-.97.97a.749.749 0 0 1-1.275-.326.749.749 0 0 1 .215-.734l.97-.97-.97-.97a.75.75 0 0 1 0-1.06ZM2.5 3.25a.75.75 0 1 0 1.5 0 .75.75 0 0 0-1.5 0ZM3.25 12a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Zm9.5 0a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Z",
};

const SVG = "http://www.w3.org/2000/svg";

/** An Octicon at `size` px, filled in currentColor. */
export function octicon(name, size = 16) {
  const svg = document.createElementNS(SVG, "svg");
  for (const [k, v] of Object.entries({ width: size, height: size, viewBox: "0 0 16 16", fill: "currentColor", "aria-hidden": "true", class: "octicon" })) svg.setAttribute(k, String(v));
  const path = document.createElementNS(SVG, "path");
  path.setAttribute("d", OCTICONS[name] ?? "");
  svg.append(path);
  return svg;
}

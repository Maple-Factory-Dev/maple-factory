// Whether GitHub is having issues, from githubstatus.com (a Statuspage): the org hub reads it while apps
// are connected and tells them, so a stuck push or a slow check has a reason on screen. The apps never
// read it themselves.

import type { GitHubIndicator, GitHubStatus } from "./wire.ts";

export const GITHUB_STATUS_URL = "https://www.githubstatus.com/api/v2/summary.json";

const INDICATORS: GitHubIndicator[] = ["none", "minor", "major", "critical", "maintenance"];

interface Summary {
  status?: { indicator?: string; description?: string };
  components?: { name?: string; status?: string; group?: boolean }[];
  incidents?: { id?: string; name?: string; status?: string; shortlink?: string; created_at?: string }[];
}

/** summary.json reduced to what the apps show: unresolved incidents (newest first) and the components
 *  that aren't operational. Throws when it isn't a Statuspage summary. */
export function reduceSummary(summary: Summary, checkedAt = Date.now()): GitHubStatus {
  const indicator = summary?.status?.indicator;
  if (!INDICATORS.includes(indicator as GitHubIndicator)) throw new Error(`unknown indicator: ${indicator}`);
  const incidents = (summary.incidents ?? [])
    .filter((i) => i.name && i.status !== "resolved" && i.status !== "postmortem")
    .sort((a, b) => (b.created_at ?? "").localeCompare(a.created_at ?? ""))
    .map((i) => ({
      name: i.name!,
      status: i.status ?? "investigating",
      url: i.id ? `https://www.githubstatus.com/incidents/${i.id}` : i.shortlink ?? null,
    }));
  const components = (summary.components ?? [])
    .filter((c) => c.name && !c.group && c.status && c.status !== "operational")
    .map((c) => c.name!);
  return { indicator: indicator as GitHubIndicator, description: summary.status?.description ?? "", incidents, components, checkedAt };
}

/** What the apps show: the status while something's wrong, null when all is clear. */
export function notice(status: GitHubStatus): GitHubStatus | null {
  return status.indicator === "none" && !status.incidents.length && !status.components.length ? null : status;
}

/** Reads githubstatus.com (or `url`, for tests). Null when it can't be read or parsed, so an outage of
 *  the status page itself neither clears nor invents a notice. */
export async function fetchGitHubStatus(url = GITHUB_STATUS_URL): Promise<GitHubStatus | null> {
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(5000), headers: { accept: "application/json" } });
    if (!res.ok) return null;
    return reduceSummary((await res.json()) as Summary);
  } catch {
    return null;
  }
}

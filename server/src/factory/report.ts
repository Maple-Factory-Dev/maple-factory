// A member's day report ("EOD"): what they merged, reviewed for others, have waiting on review and
// have in progress, across every goal, for one local day. Built from the tasks and `stats_events`,
// and written as Markdown and as Slack mrkdwn ready to paste. Pure, so test/report.test.ts runs it on fixtures.

import type { DayReport, Goal, ReportItem, ReportSection, Task } from "../wire.ts";
import type { StatEvent } from "./stats.ts";

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

/** "Fri, Oct 31" for the day [since, until): its middle, read in UTC, falls on the asker's local date for any offset within ±12h. */
export function dayLabel(since: number, until: number): string {
  const d = new Date(since + Math.max(0, until - since) / 2);
  return `${WEEKDAYS[d.getUTCDay()]}, ${MONTHS[d.getUTCMonth()]} ${d.getUTCDate()}`;
}

/**
 * `login`'s report for [since, until). Merged and Reviewed come from that day's events; Pending review and
 * In progress are the tasks' state now, so they're shown only when the day reaches `now` (today).
 */
export function dayReport(login: string, since: number, until: number, tasks: Task[], events: StatEvent[], goals: Goal[], base = "", now = Date.now()): DayReport {
  const root = base.replace(/\/+$/, "");
  const byId = new Map(tasks.map((t) => [t.id, t]));
  const goalName = new Map(goals.map((g) => [g.id, g.name]));
  const inDay = (e: StatEvent) => e.at >= since && e.at < until;
  const item = (t: Task, at: number | null, note: string | null = null): ReportItem => ({
    id: t.id,
    url: `${root}/t/${t.id}`,
    title: t.title,
    goal: goalName.get(t.goal) ?? null,
    owner: t.owner,
    pr: t.pr?.number ?? null,
    prUrl: t.pr?.url ?? null,
    at,
    note,
  });

  // Merged: their tasks with a merge that day (the last one, if a task somehow has two).
  const merged = new Map<string, ReportItem>();
  for (const e of events) {
    const t = byId.get(e.task);
    if (e.kind !== "merged" || !inDay(e) || !t || t.owner !== login) continue;
    merged.set(t.id, item(t, e.at));
  }

  // Reviewed: other people's tasks whose plan or changes they approved that day; one row per task.
  const reviewed = new Map<string, { t: Task; at: number; what: Set<string> }>();
  for (const e of events) {
    const t = byId.get(e.task);
    if ((e.kind !== "plan.approved" && e.kind !== "changes.approved") || e.actor !== login || !inDay(e) || !t || t.owner === login) continue;
    const r = reviewed.get(t.id) ?? { t, at: e.at, what: new Set<string>() };
    r.at = Math.max(r.at, e.at);
    r.what.add(e.kind === "plan.approved" ? "plan" : "changes");
    reviewed.set(t.id, r);
  }

  const today = until > now;
  const mine = tasks.filter((t) => t.owner === login);
  const pending = today
    ? mine.filter((t) => t.state === "awaitingApproval" || t.state === "reviewing")
      .map((t) => item(t, t.updatedAt, t.state === "awaitingApproval" ? "plan approval" : "review"))
    : [];
  const inProgress = today ? mine.filter((t) => t.state === "planning" || t.state === "building").map((t) => item(t, t.updatedAt)) : [];

  const byTime = (a: ReportItem, b: ReportItem) => (a.at ?? 0) - (b.at ?? 0) || a.id.localeCompare(b.id);
  const sections: ReportSection[] = [
    { key: "merged", title: "Merged", items: [...merged.values()].sort(byTime) },
    {
      key: "reviewed",
      title: "Reviewed",
      items: [...reviewed.values()]
        .map((r) => item(r.t, r.at, `approved the ${[...r.what].sort((a, b) => (a === "plan" ? -1 : b === "plan" ? 1 : 0)).join(" and ")}`))
        .sort(byTime),
    },
    { key: "pendingReview", title: "Pending review", items: pending.sort(byTime) },
    { key: "inProgress", title: "In progress", items: inProgress.sort(byTime) },
  ].filter((s) => s.items.length > 0);

  const title = `EOD - ${dayLabel(since, until)}`;
  return { login, since, until, title, sections, markdown: markdown(title, sections), slack: slack(title, sections) };
}

/** Markdown: links on the task ids and PR numbers. */
export function markdown(title: string, sections: ReportSection[]): string {
  const esc = (s: string) => s.replace(/([\\[\]*_`])/g, "\\$1");
  const line = (i: ReportItem) =>
    `- [${i.id}](${i.url}) ${esc(i.title)}${i.pr != null ? ` (${i.prUrl ? `[#${i.pr}](${i.prUrl})` : `#${i.pr}`})` : ""}${i.note ? ` · ${i.note}` : ""}`;
  const body = sections.map((s) => `**${s.title}:**\n${s.items.map(line).join("\n")}`);
  return [`**${title}**`, ...(body.length ? body : ["Nothing to report yet."])].join("\n\n") + "\n";
}

/** Slack mrkdwn: `<url|text>` links, `*bold*`, and `&`, `<`, `>` escaped. */
export function slack(title: string, sections: ReportSection[]): string {
  const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  const line = (i: ReportItem) =>
    `• <${i.url}|${i.id}> ${esc(i.title)}${i.pr != null ? ` (${i.prUrl ? `<${i.prUrl}|#${i.pr}>` : `#${i.pr}`})` : ""}${i.note ? ` · ${i.note}` : ""}`;
  const body = sections.map((s) => `*${s.title}:*\n${s.items.map(line).join("\n")}`);
  return [`*${title}*`, ...(body.length ? body : ["Nothing to report yet."])].join("\n\n") + "\n";
}

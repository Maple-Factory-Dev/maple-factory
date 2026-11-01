// dayReport on fixtures: two goals, two members, merges yesterday and today, an approval on someone
// else's task, tasks waiting on review and plan approval, and the exact Markdown and Slack text.
import { test } from "node:test";
import assert from "node:assert/strict";
import { dayLabel, dayReport } from "../src/factory/report.ts";
import type { StatEvent } from "../src/factory/stats.ts";

const H = 3_600_000;
// Sat, Oct 31 2026 in America/Chicago (UTC-5): local midnight is 05:00 UTC.
const SINCE = Date.UTC(2026, 9, 31, 5);
const UNTIL = SINCE + 24 * H;
const NOW = SINCE + 17 * H; // 5pm local
const BASE = "https://factory.example.com/";

function task(id: string, f: Record<string, unknown> = {}) {
  return {
    id, goal: "g1", title: id, state: "building", owner: "andrea", brief: "", createdAt: SINCE - 72 * H, updatedAt: SINCE + H, plan: [], planVersion: 1, doneWhen: [],
    approvals: [], approvalsNeeded: 1, reviews: [], reviewsNeeded: 1, comments: [], changes: [], events: [], mockups: [], tickets: [],
    shareable: false, agent: "claude", repo: null, after: [], followUps: [], ...f,
  } as never;
}
const pr = (number: number) => ({ number, url: `https://github.com/acme/app/pull/${number}`, state: "merged", branch: "b", base: "main", checks: [] });

const goals = [
  { id: "g1", name: "Maple Factory", prefix: "MF" },
  { id: "g2", name: "Website", prefix: "WEB" },
] as never[];

const tasks = [
  task("MF-229", { title: "Assign the author to its PR", state: "merged", pr: pr(64) }),
  task("WEB-12", { goal: "g2", title: "Pricing page", state: "merged", pr: pr(9) }),
  task("MF-200", { title: "Merged yesterday", state: "merged", pr: pr(50) }),
  task("MF-231", { title: "Someone else's", owner: "sam", state: "reviewing", pr: pr(66) }),
  task("WEB-13", { goal: "g2", title: "Sam's plan", owner: "sam", state: "building" }),
  task("MF-233", { title: "Day report <EOD> & more", state: "reviewing", pr: pr(67), updatedAt: SINCE + 3 * H }),
  task("MF-234", { title: "Theme switch", state: "awaitingApproval", updatedAt: SINCE + 2 * H }),
  task("MF-235", { title: "Still building", state: "building", updatedAt: SINCE + 4 * H }),
  task("MF-236", { title: "Sam's merge", owner: "sam", state: "merged", pr: pr(70) }),
  task("MF-237", { title: "My own approval", state: "merged", pr: pr(71) }),
];

let n = 0;
const ev = (kind: StatEvent["kind"], taskId: string, at: number, actor: string | null = null): StatEvent =>
  ({ id: String(n++), at, kind, task: taskId, goal: "g1", role: null, actor, detail: {} });

const events: StatEvent[] = [
  ev("merged", "MF-200", SINCE - 2 * H, "factory"), // yesterday
  ev("merged", "MF-229", SINCE + 10 * H, "factory"),
  ev("merged", "WEB-12", SINCE + 9 * H, "andrea"),
  ev("merged", "MF-236", SINCE + 11 * H, "factory"), // sam's
  ev("merged", "MF-237", SINCE + 12 * H, "factory"),
  ev("changes.approved", "MF-231", SINCE + 8 * H, "andrea"),
  ev("plan.approved", "MF-231", SINCE + 6 * H, "andrea"),
  ev("plan.approved", "WEB-13", SINCE + 7 * H, "andrea"),
  ev("plan.approved", "MF-237", SINCE + 1 * H, "andrea"), // own task: not a review
  ev("plan.approved", "MF-236", SINCE - 3 * H, "andrea"), // yesterday
  ev("changes.approved", "MF-236", SINCE + 9 * H, "sam"), // someone else's approval
];

const ids = (r: ReturnType<typeof dayReport>) => Object.fromEntries(r.sections.map((s) => [s.key, s.items.map((i) => i.id)]));

test("dayLabel names the asker's local day for any offset", () => {
  assert.equal(dayLabel(SINCE, UNTIL), "Sat, Oct 31");
  // UTC+10: local midnight Oct 31 is Oct 30 14:00 UTC.
  const east = Date.UTC(2026, 9, 30, 14);
  assert.equal(dayLabel(east, east + 24 * H), "Sat, Oct 31");
});

test("sections hold exactly the expected tasks, scoped to the member", () => {
  const r = dayReport("andrea", SINCE, UNTIL, tasks, events, goals, BASE, NOW);
  assert.deepEqual(ids(r), {
    merged: ["WEB-12", "MF-229", "MF-237"],
    reviewed: ["WEB-13", "MF-231"],
    pendingReview: ["MF-234", "MF-233"],
    inProgress: ["MF-235"],
  });
  assert.deepEqual(r.sections.map((s) => s.title), ["Merged", "Reviewed", "Pending review", "In progress"]);
  const reviewed = r.sections[1].items;
  assert.equal(reviewed[1].note, "approved the plan and changes");
  assert.equal(reviewed[1].owner, "sam");
  assert.equal(r.sections[0].items[0].goal, "Website");
  for (const s of r.sections) for (const i of s.items) assert.equal(i.url, `https://factory.example.com/t/${i.id}`);
});

test("yesterday: only that day's merges and approvals, and no current-state sections", () => {
  const r = dayReport("andrea", SINCE - 24 * H, SINCE, tasks, events, goals, BASE, NOW);
  assert.deepEqual(ids(r), { merged: ["MF-200"], reviewed: ["MF-236"] });
  assert.equal(r.title, "EOD - Fri, Oct 30");
});

test("empty sections are left out", () => {
  const r = dayReport("sam", SINCE, UNTIL, tasks, events, goals, BASE, NOW);
  assert.deepEqual(ids(r), { merged: ["MF-236"], pendingReview: ["MF-231"], inProgress: ["WEB-13"] });
  const none = dayReport("nobody", SINCE, UNTIL, tasks, events, goals, BASE, NOW);
  assert.deepEqual(none.sections, []);
  assert.equal(none.markdown, "**EOD - Sat, Oct 31**\n\nNothing to report yet.\n");
});

test("Markdown and Slack text, with the task ids and PRs linked", () => {
  const r = dayReport("andrea", SINCE, UNTIL, tasks, events, goals, BASE, NOW);
  const f = "https://factory.example.com/t";
  const gh = "https://github.com/acme/app/pull";
  assert.equal(r.markdown, [
    "**EOD - Sat, Oct 31**",
    "",
    "**Merged:**",
    `- [WEB-12](${f}/WEB-12) Pricing page ([#9](${gh}/9))`,
    `- [MF-229](${f}/MF-229) Assign the author to its PR ([#64](${gh}/64))`,
    `- [MF-237](${f}/MF-237) My own approval ([#71](${gh}/71))`,
    "",
    "**Reviewed:**",
    `- [WEB-13](${f}/WEB-13) Sam's plan · approved the plan`,
    `- [MF-231](${f}/MF-231) Someone else's ([#66](${gh}/66)) · approved the plan and changes`,
    "",
    "**Pending review:**",
    `- [MF-234](${f}/MF-234) Theme switch · plan approval`,
    `- [MF-233](${f}/MF-233) Day report <EOD> & more ([#67](${gh}/67)) · review`,
    "",
    "**In progress:**",
    `- [MF-235](${f}/MF-235) Still building`,
    "",
  ].join("\n"));
  assert.equal(r.slack, [
    "*EOD - Sat, Oct 31*",
    "",
    "*Merged:*",
    `• <${f}/WEB-12|WEB-12> Pricing page (<${gh}/9|#9>)`,
    `• <${f}/MF-229|MF-229> Assign the author to its PR (<${gh}/64|#64>)`,
    `• <${f}/MF-237|MF-237> My own approval (<${gh}/71|#71>)`,
    "",
    "*Reviewed:*",
    `• <${f}/WEB-13|WEB-13> Sam's plan · approved the plan`,
    `• <${f}/MF-231|MF-231> Someone else's (<${gh}/66|#66>) · approved the plan and changes`,
    "",
    "*Pending review:*",
    `• <${f}/MF-234|MF-234> Theme switch · plan approval`,
    `• <${f}/MF-233|MF-233> Day report &lt;EOD&gt; &amp; more (<${gh}/67|#67>) · review`,
    "",
    "*In progress:*",
    `• <${f}/MF-235|MF-235> Still building`,
    "",
  ].join("\n"));
});

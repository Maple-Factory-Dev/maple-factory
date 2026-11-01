// workSummary and wantsStatus: what @Maple says is in flight, and which mentions ask for it.
import { test } from "node:test";
import assert from "node:assert/strict";
import { GROUP_CAP, wantsStatus, workSummary } from "../src/factory/slack-status.ts";
import type { Goal, Task } from "../src/wire.ts";

const NOW = 10 * 3_600_000;
const goal = (id: string): Goal => ({ id, name: id === "web" ? "Website" : "Mobile app", prefix: id.toUpperCase(), color: "blue", summary: "", lead: "me", repos: [`acme/${id}`], repo: `acme/${id}`, archived: false });
const task = (id: string, f: Partial<Task> = {}): Task => ({
  id, goal: "web", title: `Task ${id}`, state: "building", owner: "dana", brief: "", createdAt: 1, updatedAt: 1, plan: [], planVersion: 1, doneWhen: [],
  approvals: [], approvalsNeeded: 1, reviews: [], reviewsNeeded: 1, comments: [], changes: [], events: [], mockups: [], artifacts: [], tickets: [],
  shareable: false, agent: "claude", after: [], followUps: [], ...f,
});
const worker = (startedAt: number) => ({ role: "builder", agent: "claude", machine: "m1", session: "s", startedAt }) as Task["worker"];

test("workSummary groups the work, keeps queue order and leaves out idle tasks", () => {
  const tasks = [
    task("WEB-1", { worker: worker(NOW - 65 * 60_000) }),
    task("WEB-2", { waiting: "Waiting for a free slot on your machines" }),
    task("WEB-3"),
    task("WEB-4", { state: "reviewing", reviews: ["sam"], reviewsNeeded: 2, pr: { number: 42, state: "open", branch: "b", base: "main", checks: [{ name: "ci", status: "failed", required: true }] } }),
    task("WEB-5", { state: "awaitingApproval", approvals: [], approvalsNeeded: 2 }),
    task("WEB-6", { state: "planning", worker: worker(NOW) }),
    task("WEB-7", { hand: { reason: "proofBurden", summary: "Can't run the iOS sim", at: 1, assignee: "dana", options: [] } }),
    task("WEB-8", { state: "reviewing", question: { text: "Which icon?", options: [], role: "builder" as never, at: 1 } }),
    ...(["merged", "cancelled", "closed", "drafting", "backlog"] as const).map((state, i) => task(`WEB-9${i}`, { state })),
  ];
  const queued = [tasks[2], tasks[1]]; // WEB-3 is ahead of WEB-2
  const said = workSummary(tasks, queued, [goal("web")], NOW);
  assert.match(said, /\*Building\*\n• \*WEB-1\* Task WEB-1 · dana · claude · running 1h 5m/);
  assert.match(said, /\*Queued\*\n• \*WEB-3\*[^\n]*#1 in line[^\n]*\n• \*WEB-2\*[^\n]*#2 in line · dana · Waiting for a free slot/);
  assert.match(said, /\*In review\*\n• \*WEB-4\*[^\n]*PR #42 · reviews 1\/2 · 1 CI failing/);
  assert.match(said, /\*Planning \/ awaiting approval\*\n[^]*WEB-5[^\n]*approvals 0\/2[^]*WEB-6[^\n]*planning/);
  assert.match(said, /\*Needs someone\*\n• \*WEB-7\*[^\n]*hand raised \(proofBurden\) for dana: Can't run the iOS sim\n• \*WEB-8\*[^\n]*question: Which icon\?/);
  for (const id of ["WEB-90", "WEB-91", "WEB-92", "WEB-93", "WEB-94"]) assert.ok(!said.includes(id), `${id} is idle`);
  assert.equal(said.match(/\*WEB-8\*/g)?.length, 1, "a task waiting on someone shows once");
});

test("workSummary counts only the given goals and leaves out empty groups", () => {
  const tasks = [task("WEB-1", { worker: worker(NOW) }), task("MOB-1", { goal: "mob", state: "reviewing" })];
  const web = workSummary(tasks, [], [goal("web")], NOW);
  assert.ok(web.includes("WEB-1") && !web.includes("MOB-1"));
  assert.ok(!/In review|Queued|Planning|Needs someone/.test(web), "empty groups are left out");
  const both = workSummary(tasks, [], [goal("web"), goal("mob")], NOW);
  assert.ok(both.includes("WEB-1") && both.includes("MOB-1"));
});

test("workSummary caps a long group", () => {
  const tasks = Array.from({ length: GROUP_CAP + 4 }, (_, i) => task(`WEB-${i + 1}`));
  const said = workSummary(tasks, tasks, [goal("web")], NOW);
  assert.equal(said.match(/^• /gm)?.length, GROUP_CAP);
  assert.match(said, /…and 4 more/);
  assert.ok(!said.includes(`WEB-${GROUP_CAP + 1}*`));
});

test("workSummary says when nothing is in flight", () => {
  assert.match(workSummary([task("WEB-1", { state: "merged" })], [], [goal("web")], NOW), /^Nothing is in flight in Website right now/);
});

test("wantsStatus matches status phrasings, not code questions", () => {
  for (const q of ["status", "Status?", "*status*", "queue", "what's in progress", "What’s in progress?", "whats in flight", "what is queued", "what's being built",
    "what's building right now", "what is in the queue", "what's the status", "what's in review", "hey, what's in progress?", "in progress", "show me what's queued"]) {
    assert.ok(wantsStatus(q), q);
  }
  for (const q of ["what does the queue module do", "why is the status page slow", "can you look into it?", "what's in progress.ts", "how does the queue order tasks?",
    "status of the export bug in web/src/export.ts", "what's going on with the export button", ""]) {
    assert.ok(!wantsStatus(q), q);
  }
});

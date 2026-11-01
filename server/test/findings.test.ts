// submit_findings: a research task. The planner answers the brief's question instead of planning a
// change: the short answer is saved on the task, a shared Markdown report is linked, any follow-ups
// become drafts, and the task closes with nothing to merge. Through the engine on a node:sqlite store
// (as propose.test.ts does).
import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { Engine } from "../src/factory/engine.ts";
import { Store } from "../src/factory/store.ts";
import { toolsFor } from "../src/factory/tools.ts";
import type { Task } from "../src/wire.ts";

function sqlStorage() {
  const db = new DatabaseSync(":memory:");
  return {
    exec(query: string, ...bindings: unknown[]) {
      const statements = query.split(";").map((s) => s.trim()).filter(Boolean);
      if (statements.length > 1) {
        db.exec(query);
        return { toArray: () => [], one: () => undefined };
      }
      const rows = db.prepare(query).all(...(bindings as never[]));
      return { toArray: () => rows, one: () => rows[0] };
    },
  } as unknown as SqlStorage;
}

const SESSION = "44444444-4444-4444-8444-444444444444";
const REPORT = { id: "art-1", title: "Research report", kind: "markdown", summary: null, file: "/attachments/a1/report.md", mime: "text/markdown", bytes: 120, by: "planner", at: 1, version: 1 };

/** MF-1 `state` in acme/mac, its `role` live in SESSION, with the report already shared. */
function factory(role: "planner" | "builder" = "planner", state = "planning") {
  const store = new Store(sqlStorage());
  const pending: Promise<unknown>[] = [];
  const toasts: string[] = [];
  const hooks = {
    broadcast: (m: { type: string; text?: string }) => m.type === "toast" && toasts.push(m.text!),
    sendTo: () => {},
    machines: async () => [{ id: "mac", sessions: [] }],
    members: async () => [],
    machineChanged: async () => {},
    waitUntil: (p: Promise<unknown>) => pending.push(p),
    wakeIn: () => {},
  };
  const DB = { prepare: () => ({ bind: () => ({ run: async () => {} }) }) };
  const MACHINE = { idFromName: (id: string) => id, get: () => ({ fetch: async () => new Response(null) }) };
  const engine = new Engine({ DB, MACHINE } as never, store, hooks as never, { forTask: () => {} } as never, {} as never);
  store.saveGoal({ id: "g", name: "Apps", prefix: "IOS", summary: "", lead: "owner", repos: ["acme/ios"], repo: "acme/mac", archived: false } as never);
  store.saveTask({
    id: "MF-1", goal: "g", title: "How does the merge queue work?", state, owner: "owner", brief: "How does it work?", createdAt: 1, updatedAt: 1, plan: [], planVersion: 0, doneWhen: [],
    approvals: [], approvalsNeeded: 1, reviews: [], reviewsNeeded: 1, comments: [], changes: [], events: [], mockups: [], tickets: [], artifacts: [REPORT],
    shareable: true, agent: "claude", machine: "mac", repo: "acme/mac", branch: "agent/mf-1",
    worker: { role, agent: "claude", machine: "mac", session: SESSION, startedAt: 1 },
  } as never);
  store.addSession({ id: SESSION, task: "MF-1", role, machine: "mac", agent: "claude", started: 1, ended: null, cause: null, kind: "team" });
  const submit = async (args: unknown) => {
    const reply = (await engine.fromRunner("mac", { type: "mcp.request", reqId: "r", session: SESSION, tool: "submit_findings", args } as never)) as { result?: { summary: string; data: { tasks: string[]; report: string | null } }; error?: string };
    // Not drained: closing the planner kills its session after CLOSE_AFTER_MS.
    return reply;
  };
  const drafts = () => (store.tasks().filter((t) => t.id !== "MF-1") as Task[]).sort((a, b) => a.id.localeCompare(b.id, undefined, { numeric: true }));
  return { store, submit, drafts, toasts, task: () => store.task("MF-1")! };
}

test("submit_findings is the planner's alone", () => {
  assert.ok(toolsFor("planner").some((t) => t.name === "submit_findings"));
  assert.ok(!toolsFor("builder").some((t) => t.name === "submit_findings"));
  assert.ok(!toolsFor("reviewer").some((t) => t.name === "submit_findings"));
});

test("it saves the answer and the report on the task and closes it", async () => {
  const { submit, task, toasts, drafts } = factory();
  const reply = await submit({ answer: "It's a **FIFO** in the engine.", report: "research REPORT" });
  assert.equal(reply.error, undefined);
  const t = task();
  assert.equal(t.state, "closed");
  assert.equal(t.findings!.answer, "It's a **FIFO** in the engine.");
  assert.equal(t.findings!.report, "art-1", "the title matches case-insensitively and is stored as the artifact's id");
  assert.deepEqual(t.findings!.followUps, []);
  assert.equal(t.findings!.by, "claude");
  assert.ok(t.findings!.at > 0);
  assert.equal(t.worker ?? null, null, "the planner's session is closed");
  assert.equal(t.events.at(-1)!.text, "answered it");
  assert.match(reply.result!.summary, /Answered and closed MF-1/);
  assert.equal(reply.result!.data.report, "art-1");
  assert.match(toasts.at(-1)!, /MF-1's planner answered it/);
  assert.equal(drafts().length, 0);
});

test("without a report, the answer is all there is", async () => {
  const { submit, task } = factory();
  assert.equal((await submit({ answer: "Short answer." })).error, undefined);
  assert.equal(task().findings!.report, null);
  assert.equal(task().state, "closed");
});

test("follow-ups become drafts in order, honouring after", async () => {
  const { submit, task, drafts, store } = factory();
  store.saveTask({ ...task(), id: "MF-12", state: "reviewing", worker: null, events: [] } as never);
  const reply = await submit({
    answer: "Yes, it could.",
    report: "Research report",
    followUps: [
      { title: "API: the field", brief: "a", effort: "Queue" },
      { title: "Engine: use it", brief: "b", after: ["#1", "MF-12"], effort: "Queue", repo: "acme/ios" },
    ],
  });
  assert.equal(reply.error, undefined);
  assert.deepEqual(task().findings!.followUps, ["IOS-1", "IOS-2"]);
  const [a, b] = drafts().filter((t) => t.id.startsWith("IOS-"));
  assert.equal(a.state, "drafting");
  assert.equal(b.state, "drafting");
  assert.deepEqual(a.after, []);
  assert.deepEqual(b.after, ["MF-12", "IOS-1"]);
  assert.equal(b.repo, "acme/ios");
  assert.equal(a.effort, "Queue");
  assert.match(a.brief, /Proposed by MF-1's planner\.$/);
  assert.equal(task().events.at(-1)!.text, "answered it; proposed IOS-1, IOS-2");
  assert.match(reply.result!.summary, /IOS-2 Engine: use it \(after MF-12, IOS-1\) \[Queue\]/);
});

test("a report title that isn't one of the task's artifacts is refused, and nothing changes", async () => {
  const { submit, task, drafts } = factory();
  const reply = await submit({ answer: "x", report: "Some other report", followUps: [{ title: "T", brief: "b" }] });
  assert.match(reply.error!, /"Some other report" isn't one of this task's artifacts \("Research report"\)\. Share it with share_artifact first\./);
  assert.equal(task().state, "planning");
  assert.equal(task().findings ?? null, null);
  assert.equal(drafts().length, 0);
});

test("a bad follow-up is refused before anything is made or closed", async () => {
  const { submit, task, drafts } = factory();
  assert.match((await submit({ answer: "x", followUps: [{ title: "A", brief: "a", after: ["#2"] }, { title: "B", brief: "b" }] })).error!, /followUps\[0\]\.after: #2 isn't an earlier proposal/);
  assert.match((await submit({ answer: "  " })).error!, /answer/);
  assert.match((await submit({ answer: "x".repeat(5000) })).error!, /a few paragraphs/);
  assert.equal(task().state, "planning");
  assert.equal(drafts().length, 0);
});

test("the builder can't call it", async () => {
  const { submit, task } = factory("builder", "building");
  assert.match((await submit({ answer: "x" })).error!, /submit_findings isn't one of the builder's tools/);
  assert.equal(task().state, "building");
});

test("it's refused outside planning", async () => {
  const { submit, task } = factory("planner", "awaitingApproval");
  assert.match((await submit({ answer: "x" })).error!, /while it's planning/);
  assert.equal(task().state, "awaitingApproval");
  assert.equal(task().findings ?? null, null);
});

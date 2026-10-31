// propose_tasks: a planner or builder proposes tasks for its goal (e.g. "scan the iOS app for missing
// features and propose tickets"). Each becomes a draft a person sends to planning or deletes; nothing
// is planned or dispatched until they do. Through the engine on a node:sqlite store (as factory-checks.test.ts does).
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

const SESSION = "33333333-3333-4333-8333-333333333333";

/** MF-1 building in acme/mac for `owner`, in a goal that also works in acme/ios; its builder live in SESSION. */
function factory(role: "builder" | "reviewer" = "builder", planner = false) {
  const store = new Store(sqlStorage());
  const pending: Promise<unknown>[] = [];
  const toasts: string[] = [];
  const audits: unknown[][] = [];
  const hooks = {
    broadcast: (m: { type: string; text?: string }) => m.type === "toast" && toasts.push(m.text!),
    sendTo: () => {},
    machines: async () => [{ id: "mac", sessions: [] }],
    members: async () => [],
    machineChanged: async () => {},
    waitUntil: (p: Promise<unknown>) => pending.push(p),
    wakeIn: () => {},
  };
  const DB = { prepare: () => ({ bind: (...args: unknown[]) => ({ run: async () => { audits.push(args); } }) }) };
  const MACHINE = { idFromName: (id: string) => id, get: () => ({ fetch: async () => new Response(null) }) };
  const engine = new Engine({ DB, MACHINE } as never, store, hooks as never, { forTask: () => {} } as never, {} as never);
  store.saveGoal({ id: "g", name: "Apps", prefix: "IOS", summary: "", lead: "owner", repos: ["acme/ios"], repo: "acme/mac", archived: false } as never);
  store.saveTask({
    id: "MF-1", goal: "g", title: "Find iOS gaps", state: "building", owner: "owner", brief: "", createdAt: 1, updatedAt: 1, plan: [], planVersion: 1, doneWhen: [],
    approvals: [], approvalsNeeded: 1, reviews: [], reviewsNeeded: 1, comments: [], changes: [], events: [], mockups: [], tickets: [],
    shareable: true, agent: "codex", model: "gpt-x", effort: "high", machine: "mac", repo: "acme/mac", branch: "agent/mf-1",
    worker: { role, agent: "codex", machine: "mac", session: SESSION, startedAt: 1 },
  } as never);
  store.addSession({ id: SESSION, task: "MF-1", role, machine: "mac", agent: "codex", started: 1, ended: null, cause: null, kind: "team" });
  const propose = async (tasks: unknown) => {
    const reply = (await engine.fromRunner("mac", { type: "mcp.request", reqId: "r", session: SESSION, tool: "propose_tasks", args: { tasks } } as never)) as { result?: { summary: string; data: { tasks: string[] } }; error?: string };
    while (pending.length) await pending.shift();
    return reply;
  };
  // By id: drafts made in the same millisecond come back from store.tasks() in either order.
  const others = () => (store.tasks().filter((t) => t.id !== "MF-1") as Task[]).sort((a, b) => a.id.localeCompare(b.id, undefined, { numeric: true }));
  const settle = async () => { while (pending.length) await pending.shift(); };
  return { store, engine, propose, others, toasts, audits, settle };
}

test("propose_tasks is listed for planners and builders, not reviewers", () => {
  const names = (role: "planner" | "builder" | "reviewer") => toolsFor(role).map((t) => t.name);
  assert.ok(names("planner").includes("propose_tasks"));
  assert.ok(names("builder").includes("propose_tasks"));
  assert.ok(!names("reviewer").includes("propose_tasks"));
});

test("each proposal becomes a draft in the caller's goal, owned by its task's owner", async () => {
  const { store, propose, others, toasts, audits } = factory();
  const reply = await propose([
    { title: "iOS: add Drafts list", brief: "The Mac app has a Drafts list; iOS doesn't." },
    { title: "  iOS: share sheet  ", brief: "Share a task's link.", repo: "ACME/ios" },
  ]);
  assert.equal(reply.error, undefined);
  assert.deepEqual(reply.result!.data.tasks, ["IOS-1", "IOS-2"]);
  const [a, b] = others();
  for (const t of [a, b]) {
    assert.equal(t.goal, "g");
    assert.equal(t.state, "drafting");
    assert.equal(t.owner, "owner");
    assert.equal(t.shareable, true);
    assert.equal(t.agent, "codex");
    assert.equal(t.model, "gpt-x");
    assert.equal(t.effort, "high");
    assert.match(t.brief, /\n\nProposed by MF-1's builder\.$/);
    assert.equal(t.events.at(-1)!.text, "proposed by MF-1");
  }
  assert.equal(a.repo, "acme/mac", "left out, it's the proposing task's repo");
  assert.equal(b.repo, "acme/ios", "named, it's the goal's spelling");
  assert.equal(b.title, "iOS: share sheet");
  // Both drafts (made in the same millisecond, they tie on draftRank).
  assert.deepEqual(store.drafts("g").map((t) => t.id).sort(), ["IOS-1", "IOS-2"]);
  assert.equal(store.task("MF-1")!.events.at(-1)!.text, "proposed IOS-1, IOS-2");
  assert.equal(toasts.length, 1);
  assert.match(toasts[0], /MF-1's builder proposed 2 tasks/);
  assert.deepEqual(audits.map((x) => [x[2], x[3], JSON.parse(x[4] as string).proposedBy]), [["task.created", "IOS-1", "MF-1"], ["task.created", "IOS-2", "MF-1"]]);
});

test("nothing proposed enters planning or waits for a machine", async () => {
  const { propose, others } = factory();
  await propose([{ title: "One", brief: "a" }, { title: "Two", brief: "b" }]);
  for (const t of others()) {
    assert.equal(t.state, "drafting");
    assert.ok(!t.waiting);
    assert.ok(!t.worker);
    assert.equal(t.plan.length, 0);
  }
});

test("a repo outside the goal, an empty title or brief, or too many proposals are refused, and none are made", async () => {
  const { propose, others } = factory();
  assert.match((await propose([{ title: "Ok", brief: "fine" }, { title: "Elsewhere", brief: "x", repo: "acme/web" }])).error!, /acme\/web isn't one of this goal's repos \(acme\/mac, acme\/ios\)/);
  assert.match((await propose([{ title: "  ", brief: "x" }])).error!, /tasks\[\]\.title is required/);
  assert.match((await propose([{ title: "T", brief: "" }])).error!, /tasks\[\]\.brief is required/);
  assert.match((await propose([])).error!, /at least one/);
  assert.match((await propose(Array.from({ length: 21 }, (_, i) => ({ title: `T${i}`, brief: "b" })))).error!, /at most 20/);
  assert.equal(others().length, 0);
});

test("a reviewer can't propose tasks", async () => {
  const { propose, others } = factory("reviewer");
  assert.match((await propose([{ title: "T", brief: "b" }])).error!, /propose_tasks isn't one of the reviewer's tools/);
  assert.equal(others().length, 0);
});

// Ordered proposals: `after` (#n for an earlier proposal, or an existing id) and a shared effort.

test("proposals wait on earlier ones (#n) and existing tasks, and share an effort", async () => {
  const { store, propose, others, toasts } = factory();
  store.saveTask({ ...store.task("MF-1")!, id: "MF-12", state: "reviewing", worker: null, events: [] } as never);
  const reply = await propose([
    { title: "API: dependency field", brief: "a", effort: "Ordered work" },
    { title: "Engine: gate on it", brief: "b", after: ["#1"], effort: "Ordered work" },
    { title: "Mac: show it", brief: "c", after: ["#1", "#2", "MF-12"], effort: "Ordered work" },
  ]);
  assert.equal(reply.error, undefined);
  assert.deepEqual(reply.result!.data.tasks, ["IOS-1", "IOS-2", "IOS-3"]);
  const [a, b, c] = others().filter((t) => t.id.startsWith("IOS-"));
  assert.deepEqual(a.after, []);
  assert.deepEqual(b.after, ["IOS-1"]);
  assert.deepEqual(c.after, ["MF-12", "IOS-1", "IOS-2"]);
  for (const t of [a, b, c]) {
    assert.equal(t.effort, "Ordered work");
    assert.equal(t.state, "drafting");
  }
  assert.equal(c.events.at(-1)!.text, "proposed by MF-1; waits on MF-12, IOS-1, IOS-2");
  assert.match(reply.result!.summary, /IOS-3 Mac: show it \(after MF-12, IOS-1, IOS-2\) \[Ordered work\]/);
  assert.match(toasts[0], /proposed IOS-1 → IOS-2 → IOS-3; .* in order/);
});

test("a forward or self #n, an unknown id, or a cancelled one is refused, and nothing is made", async () => {
  const { store, propose, others } = factory();
  store.saveTask({ ...store.task("MF-1")!, id: "MF-9", state: "cancelled", worker: null } as never);
  const before = others().length;
  // #1 ↔ #2 would be a loop: a proposal can only wait on ones before it.
  assert.match((await propose([{ title: "A", brief: "a", after: ["#2"] }, { title: "B", brief: "b", after: ["#1"] }])).error!, /#2 isn't an earlier proposal in this call; a task can only wait on ones listed before it/);
  assert.match((await propose([{ title: "A", brief: "a", after: ["#1"] }])).error!, /#1 isn't an earlier proposal/);
  assert.match((await propose([{ title: "A", brief: "a" }, { title: "B", brief: "b", after: ["MF-404"] }])).error!, /There's no task MF-404/);
  assert.match((await propose([{ title: "A", brief: "a", after: ["MF-9"] }])).error!, /MF-9 was cancelled/);
  assert.equal(others().length, before);
});

// task.edit `after`, and the gate: a task builds only once everything it waits on has merged.

const OWNER = { member: { login: "owner", role: "member" } } as never;

/** IOS-1 and IOS-2 in review; IOS-3 approved, building once both merge; `mac` online for owner. */
function chain() {
  const f = factory();
  const base = { ...f.store.task("MF-1")!, worker: null, events: [], branch: null, machine: null, plan: [{ text: "Do it", file: "a.ts", done: false }], waiting: null };
  const pr = (n: number) => ({ number: n, url: null, state: "open", head: "a".repeat(40), branch: `agent/ios-${n}`, base: "main", checks: [] });
  f.store.saveTask({ ...base, id: "IOS-1", state: "reviewing", pr: pr(1) } as never);
  f.store.saveTask({ ...base, id: "IOS-2", state: "reviewing", pr: pr(2) } as never);
  f.store.saveTask({ ...base, id: "IOS-3", state: "awaitingApproval", approvalsNeeded: 1, approvals: [], after: ["IOS-1", "IOS-2"] } as never);
  // The proposing task is done with its slot.
  f.store.saveTask({ ...f.store.task("MF-1")!, state: "merged", worker: null } as never);
  f.store.endSession(SESSION, "done");
  const machines = [{ id: "mac", name: "mac", owner: "owner", online: true, sessions: [] }];
  (f.engine as unknown as { hooks: { machines: () => Promise<unknown> } }).hooks.machines = async () => machines;
  const merge = async (id: string) => {
    await f.engine.fromRunner("mac", { type: "task.merged", taskId: id, ok: true, commit: "b".repeat(40), message: null } as never);
    await f.settle();
    await f.engine.pump();
  };
  const edit = (id: string, after: string[]) => f.engine.command({ type: "task.edit", id, after } as never, OWNER);
  return { ...f, merge, edit, t: (id: string) => f.store.task(id)! };
}

test("an approved task waiting on two stays out of building until the second merges, then starts on its own", async () => {
  const { engine, merge, t, settle } = chain();
  await engine.command({ type: "task.approvePlan", id: "IOS-3" } as never, OWNER);
  await settle();
  assert.equal(t("IOS-3").state, "building");
  assert.equal(t("IOS-3").worker ?? null, null);
  assert.equal(t("IOS-3").waiting, "Waiting for IOS-1 and IOS-2 to merge first.");

  await merge("IOS-1");
  assert.equal(t("IOS-1").state, "merged");
  assert.equal(t("IOS-3").worker ?? null, null, "one of two merged: still waiting");
  assert.equal(t("IOS-3").waiting, "Waiting for IOS-2 to merge first.");

  await merge("IOS-2");
  assert.equal(t("IOS-3").worker?.role, "builder", "both merged: a builder starts with no one acting");
  assert.equal(t("IOS-3").waiting ?? null, null);
});

test("task.edit after replaces the list, refuses a loop, itself, an unknown id, and a task already building", async () => {
  const { edit, t, store } = chain();
  await edit("IOS-3", ["IOS-1"]);
  assert.deepEqual(t("IOS-3").after, ["IOS-1"]);
  assert.equal(t("IOS-3").events.at(-1)!.text, "now waits on IOS-1");
  // IOS-1 → IOS-3 → IOS-1.
  await assert.rejects(edit("IOS-1", ["IOS-3"]), /That makes a loop: IOS-1 → IOS-3 → IOS-1/);
  await assert.rejects(edit("IOS-3", ["IOS-3"]), /can't wait on itself/);
  await assert.rejects(edit("IOS-3", ["IOS-404"]), /There's no task IOS-404/);
  const many = Array.from({ length: 11 }, (_, i) => `X-${i}`);
  for (const id of many) store.saveTask({ ...t("IOS-1"), id, state: "drafting", pr: null } as never);
  await assert.rejects(edit("IOS-3", many), /at most 10 others/);
  await edit("IOS-3", many.slice(0, 10));
  await edit("IOS-3", ["IOS-1"]);
  // In review (or building with a builder on it), what it waits on is settled.
  await assert.rejects(edit("IOS-1", ["IOS-2"]), /It's reviewing; what it waits on can't change now/);
  store.saveTask({ ...t("IOS-3"), state: "building", worker: { role: "builder", agent: "codex", machine: "mac", session: "s", startedAt: 1 } } as never);
  await assert.rejects(edit("IOS-3", []), /already building/);
  assert.deepEqual(t("IOS-3").after, ["IOS-1"]);
});

test("taking a cancelled dependency off lets the waiting task start", async () => {
  const { engine, edit, merge, t, store, settle } = chain();
  await engine.command({ type: "task.approvePlan", id: "IOS-3" } as never, OWNER);
  await merge("IOS-1");
  store.saveTask({ ...t("IOS-2"), state: "cancelled" } as never);
  await engine.pump();
  assert.match(t("IOS-3").waiting!, /IOS-2, which it builds on, was cancelled/);
  assert.equal(t("IOS-3").worker ?? null, null);
  await edit("IOS-3", ["IOS-1"]);
  await settle();
  assert.equal(t("IOS-3").worker?.role, "builder");
  assert.equal(t("IOS-3").events.some((e) => e.text === "now waits on IOS-1"), true);
});

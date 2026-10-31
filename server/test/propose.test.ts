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
function factory(role: "builder" | "reviewer" = "builder") {
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
  const engine = new Engine({ DB } as never, store, hooks as never, { forTask: () => {} } as never, {} as never);
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
  return { store, propose, others, toasts, audits };
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
  assert.deepEqual(store.drafts("g").map((t) => t.id), ["IOS-1", "IOS-2"]);
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

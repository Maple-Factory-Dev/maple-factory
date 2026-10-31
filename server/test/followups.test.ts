// Task priority and follow-ups: task.followUp turns a task's leftover review findings (or a note) into
// drafts in its goal, linked back by followUpOf; Scout leaves those findings alone; a P0 entering the
// queue goes to its front; propose_tasks takes a priority. Through the engine on a node:sqlite store
// (as propose.test.ts does).
import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { Engine } from "../src/factory/engine.ts";
import { candidates } from "../src/factory/scout.ts";
import { Store } from "../src/factory/store.ts";
import type { ClientMessage, Finding, Task } from "../src/wire.ts";

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

const finding = (id: string, severity: Finding["severity"], status: Finding["status"] = "open", file: string | null = "src/a.ts"): Finding =>
  ({ id, kind: "code", severity, text: `Problem ${id}`, file, raisedIn: 1, status, fixedIn: null }) as Finding;

/** MF-1 in review (or `state`) in acme/mac with findings f1 (minor), f2 (major), f3 (fixed); its builder live in SESSION. */
function factory(state: Task["state"] = "reviewing") {
  const store = new Store(sqlStorage());
  const pending: Promise<unknown>[] = [];
  const toasts: string[] = [];
  const audits: unknown[][] = [];
  const hooks = {
    broadcast: (m: { type: string; text?: string }) => m.type === "toast" && toasts.push(m.text!),
    sendTo: () => {},
    machines: async () => [],
    members: async () => [],
    machineChanged: async () => {},
    waitUntil: (p: Promise<unknown>) => pending.push(p),
    wakeIn: () => {},
  };
  const DB = { prepare: () => ({ bind: (...args: unknown[]) => ({ run: async () => { audits.push(args); } }) }) };
  const engine = new Engine({ DB } as never, store, hooks as never, { forTask: () => {}, accepted: () => {} } as never, {} as never);
  store.saveGoal({ id: "g", name: "Apps", prefix: "IOS", summary: "", lead: "owner", repos: ["acme/ios"], repo: "acme/mac", archived: false } as never);
  store.saveTask({
    id: "MF-1", goal: "g", title: "Ship it", state, owner: "owner", brief: "", createdAt: 1, updatedAt: 1, plan: [], planVersion: 1, doneWhen: [],
    approvals: [], approvalsNeeded: 1, reviews: [], reviewsNeeded: 1, comments: [], changes: [], events: [], mockups: [], tickets: [],
    shareable: true, agent: "codex", model: "gpt-x", effort: "Launch", machine: "mac", repo: "acme/ios", branch: "agent/mf-1",
    worker: { role: "builder", agent: "codex", machine: "mac", session: SESSION, startedAt: 1 },
    autoReview: { maxRounds: 3, rounds: [], findings: [finding("f1", "minor"), finding("f2", "major", "disputed", null), finding("f3", "blocker", "fixed")] },
  } as never);
  store.addSession({ id: SESSION, task: "MF-1", role: "builder", machine: "mac", agent: "codex", started: 1, ended: null, cause: null, kind: "team" });
  const send = async (msg: Record<string, unknown>, login = "me") => {
    await engine.command(msg as unknown as ClientMessage, { member: { login, role: "member" } } as never);
    while (pending.length) await pending.shift();
  };
  const refused = async (msg: Record<string, unknown>) => {
    try {
      await send(msg);
    } catch (e) {
      return (e as Error).message;
    }
    assert.fail("expected it to be refused");
  };
  const propose = async (tasks: unknown) => {
    const reply = (await engine.fromRunner("mac", { type: "mcp.request", reqId: "r", session: SESSION, tool: "propose_tasks", args: { tasks } } as never)) as { result?: { data: { tasks: string[] } }; error?: string };
    while (pending.length) await pending.shift();
    return reply;
  };
  const others = () => store.tasks().filter((t) => t.id !== "MF-1").sort((a, b) => a.createdAt - b.createdAt || a.id.localeCompare(b.id));
  return { store, send, refused, propose, others, toasts, audits };
}

test("task.followUp makes a linked draft per finding, with its priority and the source's repo, agent and effort", async () => {
  const { store, send, others, toasts, audits } = factory();
  await send({ type: "task.followUp", id: "MF-1", items: [
    { finding: "f1", title: "Tidy a.ts", brief: "", priority: "p3" },
    { finding: "f2", title: "Handle the edge", brief: "Worth a look.", priority: "p2" },
    { title: "Docs for it", brief: "Write up the new flag." },
  ] });
  const [a, b, c] = others();
  assert.deepEqual([a, b, c].map((t) => [t.id, t.followUpOf, t.priority]), [["IOS-1", "MF-1#f1", "p3"], ["IOS-2", "MF-1#f2", "p2"], ["IOS-3", "MF-1", null]]);
  for (const t of [a, b, c]) {
    assert.equal(t.state, "drafting");
    assert.equal(t.goal, "g");
    assert.equal(t.owner, "me", "whoever asked owns it");
    assert.equal(t.repo, "acme/ios");
    assert.equal(t.agent, "codex");
    assert.equal(t.model, "gpt-x");
    assert.equal(t.effort, "Launch");
    assert.match(t.brief, /\n\nFollow-up from MF-1\.$/);
  }
  assert.equal(a.brief, "> **minor code** in `src/a.ts`: Problem f1\n\nFollow-up from MF-1.");
  assert.equal(b.brief, "> **major code**: Problem f2\n\nWorth a look.\n\nFollow-up from MF-1.");
  assert.equal(c.brief, "Write up the new flag.\n\nFollow-up from MF-1.");
  assert.equal(a.events.at(-1)!.text, "made it as a follow-up of MF-1#f1");
  assert.equal(store.task("MF-1")!.events.at(-1)!.text, "made follow-ups IOS-1, IOS-2, IOS-3");
  assert.match(toasts.at(-1)!, /Made 3 follow-ups of MF-1/);
  assert.deepEqual(audits.map((x) => [x[2], x[3], JSON.parse(x[4] as string).followUpOf]), [["task.created", "IOS-1", "MF-1#f1"], ["task.created", "IOS-2", "MF-1#f2"], ["task.created", "IOS-3", "MF-1"]]);
});

test("a duplicate, a fixed or unknown finding, a bad priority or an empty title are refused, and nothing is made", async () => {
  const { send, refused, others } = factory();
  assert.match(await refused({ type: "task.followUp", id: "MF-1", items: [{ finding: "f1", title: "Ok", brief: "" }, { finding: "f9", title: "No", brief: "" }] }), /MF-1 has no finding f9/);
  assert.match(await refused({ type: "task.followUp", id: "MF-1", items: [{ finding: "f3", title: "Fixed", brief: "" }] }), /MF-1#f3 is already fixed/);
  assert.match(await refused({ type: "task.followUp", id: "MF-1", items: [{ finding: "f1", title: "A", brief: "" }, { finding: "f1", title: "B", brief: "" }] }), /MF-1#f1 already has a follow-up/);
  assert.match(await refused({ type: "task.followUp", id: "MF-1", items: [{ finding: "f1", title: "A", brief: "", priority: "p9" }] }), /p9 isn't a priority/);
  assert.match(await refused({ type: "task.followUp", id: "MF-1", items: [{ finding: "f1", title: "  ", brief: "" }] }), /needs a title/);
  assert.match(await refused({ type: "task.followUp", id: "MF-1", items: [{ title: "Note", brief: " " }] }), /Say what "Note" should do/);
  assert.match(await refused({ type: "task.followUp", id: "MF-1", items: [] }), /at least one/);
  assert.equal(others().length, 0);
  await send({ type: "task.followUp", id: "MF-1", items: [{ finding: "f1", title: "Once", brief: "" }] });
  assert.match(await refused({ type: "task.followUp", id: "MF-1", items: [{ finding: "f2", title: "Fine", brief: "" }, { finding: "f1", title: "Twice", brief: "" }] }), /MF-1#f1 already has a follow-up: IOS-1/);
  assert.equal(others().length, 1);
});

test("follow-ups are made only from a task in review or merged", async () => {
  for (const state of ["drafting", "building", "cancelled"] as const) {
    const { refused, others } = factory(state);
    assert.match(await refused({ type: "task.followUp", id: "MF-1", items: [{ finding: "f1", title: "X", brief: "" }] }), /in review or merged/);
    assert.equal(others().length, 0);
  }
  const { send, others } = factory("merged");
  await send({ type: "task.followUp", id: "MF-1", items: [{ finding: "f1", title: "Later", brief: "" }] });
  assert.equal(others()[0].followUpOf, "MF-1#f1");
});

test("Scout skips findings, and tasks, a follow-up already points at", () => {
  const merged = { id: "T-1", goal: "g", state: "merged", title: "T", brief: "", updatedAt: 2, autoReview: { findings: [finding("f1", "minor"), finding("f2", "major")] } } as unknown as Task;
  const backlog = { id: "T-2", goal: "g", state: "backlog", title: "B", brief: "b", updatedAt: 1 } as unknown as Task;
  const followUps = [
    { id: "T-3", goal: "g", state: "drafting", title: "F", brief: "", updatedAt: 0, followUpOf: "T-1#f1" },
    { id: "T-4", goal: "g", state: "drafting", title: "N", brief: "", updatedAt: 0, followUpOf: "T-2" },
  ] as unknown as Task[];
  assert.deepEqual(candidates("g", [merged, backlog]).map((c) => c.from), ["T-1#f1", "T-1#f2", "T-2"]);
  assert.deepEqual(candidates("g", [merged, backlog, ...followUps]).map((c) => c.from), ["T-1#f2"]);
});

test("a P0 sent to planning, or a queued task set to P0, goes to the front of the queue; other priorities keep their place", async () => {
  const { store, send } = factory();
  for (const title of ["One", "Two", "Three"]) await send({ type: "task.create", goal: "g", title, brief: "", shareable: false, plan: true, tickets: [] });
  // Made in the same millisecond: give them distinct places.
  ["IOS-1", "IOS-2", "IOS-3"].forEach((id, i) => store.saveTask({ ...store.task(id)!, queueRank: (i + 1) * 1000 }));
  const queue = () => store.queued().map((t) => t.id);
  assert.deepEqual(queue(), ["IOS-1", "IOS-2", "IOS-3"]);
  await send({ type: "task.create", goal: "g", title: "Urgent", brief: "", shareable: false, plan: true, tickets: [], priority: "p0" });
  assert.equal(store.task("IOS-4")!.priority, "p0");
  assert.deepEqual(queue(), ["IOS-4", "IOS-1", "IOS-2", "IOS-3"]);
  await send({ type: "task.edit", id: "IOS-2", priority: "p1" });
  assert.deepEqual(queue(), ["IOS-4", "IOS-1", "IOS-2", "IOS-3"], "P1 leaves the order alone");
  assert.equal(store.task("IOS-2")!.events.at(-1)!.text, "set priority P1");
  await send({ type: "task.edit", id: "IOS-3", priority: "p0" });
  assert.deepEqual(queue(), ["IOS-3", "IOS-4", "IOS-1", "IOS-2"]);
  assert.equal(store.task("IOS-3")!.events.at(-1)!.text, "moved it to the top of the queue: it's P0");
  await send({ type: "task.edit", id: "IOS-3", clearPriority: true });
  assert.equal(store.task("IOS-3")!.priority, null);
  assert.equal(store.task("IOS-3")!.events.at(-1)!.text, "took its priority off");
  // A draft's priority changes too, and a draft isn't queued.
  await send({ type: "task.create", goal: "g", title: "Draft", brief: "", shareable: false, plan: false, tickets: [] });
  await send({ type: "task.edit", id: "IOS-5", priority: "p2" });
  assert.equal(store.task("IOS-5")!.priority, "p2");
  assert.ok(!queue().includes("IOS-5"));
});

test("propose_tasks stores a priority, and refuses one that isn't p0–p3", async () => {
  const { propose, others } = factory("building");
  assert.match((await propose([{ title: "A", brief: "a", priority: "urgent" }])).error!, /tasks\[\]\.priority: urgent isn't p0, p1, p2 or p3/);
  assert.equal(others().length, 0);
  const reply = await propose([{ title: "Clean-up", brief: "c", priority: "p3" }, { title: "Plain", brief: "p" }]);
  assert.equal(reply.error, undefined);
  assert.deepEqual(others().map((t) => [t.title, t.priority]), [["Clean-up", "p3"], ["Plain", null]]);
});

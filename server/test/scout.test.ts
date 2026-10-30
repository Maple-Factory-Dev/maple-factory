// Scout: which leftovers a goal has, what's made of the agent's picks, and the cap from the policy,
// through the engine on a node:sqlite store (as drafts.test.ts does) with a fake machine hub.
import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { Engine } from "../src/factory/engine.ts";
import { Drafts } from "../src/factory/drafts.ts";
import { goalMayFetch } from "../src/factory/repos.ts";
import { candidates, parsePicks } from "../src/factory/scout.ts";
import { DEFAULT_POLICY, validPolicy } from "../src/factory/policy.ts";
import { Store } from "../src/factory/store.ts";
import type { Finding, ServerToClient, ServerToRunner, Task } from "../src/wire.ts";

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

function task(id: string, f: Partial<Task> = {}): Task {
  return {
    id, goal: "g", title: id, state: "merged", owner: "me", brief: `About ${id}`, createdAt: 1, updatedAt: 1, plan: [], planVersion: 0, doneWhen: [],
    approvals: [], approvalsNeeded: 1, reviews: [], reviewsNeeded: 1, comments: [], changes: [], events: [], mockups: [], tickets: [],
    shareable: false, agent: "claude", after: [], followUps: [], ...f,
  } as Task;
}

const finding = (id: string, f: Partial<Finding> = {}): Finding => ({ id, kind: "code", severity: "minor", text: `finding ${id}`, file: "a.ts", raisedIn: 1, status: "open", fixedIn: null, ...f });
const review = (findings: Finding[]) => ({ maxRounds: 3, rounds: [], summary: "", ask: [], proofs: [], findings });

test("candidates: open and disputed findings on merged tasks, and backlog tasks", () => {
  const tasks = [
    task("T-1", { autoReview: review([finding("f1"), finding("f2", { status: "fixed" }), finding("f3", { severity: "major", status: "disputed" })]) }),
    task("T-2", { state: "reviewing", autoReview: review([finding("f1")]) }),
    task("T-3", { state: "backlog" }),
    task("T-4", { state: "drafting" }),
    task("X-1", { goal: "other", state: "backlog" }),
  ];
  const got = candidates("g", tasks);
  assert.deepEqual(got.map((c) => c.from).sort(), ["T-1#f1", "T-1#f3", "T-3"]);
  assert.equal(got.find((c) => c.from === "T-3")?.kind, "backlog");
  assert.match(got.find((c) => c.from === "T-1#f3")!.text, /disputed/);
});

test("candidates: skips what an earlier run already made a task of", () => {
  const tasks = [
    task("T-1", { autoReview: review([finding("f1"), finding("f2")]) }),
    task("T-5", { state: "planning", scoutedFrom: "T-1#f1" }),
  ];
  assert.deepEqual(candidates("g", tasks).map((c) => c.from), ["T-1#f2"]);
});

test("parsePicks: only leftovers it was shown, each once, capped", () => {
  const shown = candidates("g", [task("T-1", { autoReview: review(["f1", "f2", "f3", "f4", "f5"].map((id) => finding(id))) })]);
  const item = (from: string) => ({ from, title: `Fix ${from}`, brief: "Still wrong in a.ts.", doneWhen: ["A test", " "] });
  const reply = `Here you go:\n\`\`\`json\n${JSON.stringify({ items: [item("T-1#f1"), item("T-1#f1"), item("NOPE"), item("T-1#f2"), item("T-1#f3"), item("T-1#f4"), item("T-1#f5")] })}\n\`\`\``;
  const picks = parsePicks(reply, shown, 3)!;
  assert.deepEqual(picks.map((p) => p.from), ["T-1#f1", "T-1#f2", "T-1#f3"]);
  assert.deepEqual(picks[0].doneWhen, ["A test"]);
  assert.equal(parsePicks("no json here", shown, 3), null);
  assert.deepEqual(parsePicks('{"items": []}', shown, 3), []);
});

test("policy: scoutItems defaults to 3 and must be 1–10", () => {
  assert.equal(DEFAULT_POLICY.scoutItems, 3);
  assert.equal(validPolicy({ ...DEFAULT_POLICY, scoutItems: 0 }), "A Scout run picks 1 to 10 items.");
  assert.equal(validPolicy({ ...DEFAULT_POLICY, scoutItems: 11 }), "A Scout run picks 1 to 10 items.");
  assert.equal(validPolicy({ ...DEFAULT_POLICY, scoutItems: 10 }), null);
  assert.equal(validPolicy({ ...DEFAULT_POLICY, scoutItems: undefined }), null);
});

/** An engine with one goal, a merged task with five open findings and a backlog task, and one online machine. */
function factory() {
  const store = new Store(sqlStorage());
  const sent: ServerToRunner[] = [];
  const broadcast: ServerToClient[] = [];
  const env = {
    DB: { prepare: () => ({ bind: () => ({ run: async () => {} }) }) },
    MACHINE: { idFromName: (n: string) => n, get: () => ({ fetch: async (_: string, init: { body: string }) => (sent.push(JSON.parse(init.body)), new Response("ok")) }) },
  };
  const machine = { id: "m1", name: "m1", owner: "me", online: true, health: null };
  const hooks = { broadcast: (m: ServerToClient) => broadcast.push(m), sendTo: () => {}, machines: async () => [machine], members: async () => [], machineChanged: async () => {}, waitUntil: () => {}, wakeIn: () => {} };
  const engine = new Engine(env as never, store, hooks as never, {} as never, {} as never);
  store.saveGoal({ id: "g", name: "Goal", prefix: "S", summary: "", lead: "me", repos: [], repo: null, archived: false } as never);
  store.saveTask(task("T-1", { autoReview: review(["f1", "f2", "f3", "f4", "f5"].map((id) => finding(id))) }));
  const scout = () => engine.command({ type: "goal.scout", goal: "g" }, { member: { login: "me", role: "member" } } as never);
  const runs = () => broadcast.filter((m) => m.type === "scout.updated").map((m) => (m as { run: { state: string; tasks: string[] } }).run);
  return { store, engine, sent, runs, scout };
}

async function scoutWithFivePicks(scoutItems?: number) {
  const f = factory();
  if (scoutItems) f.store.savePolicy({ ...DEFAULT_POLICY, scoutItems });
  await f.scout();
  const run = f.sent.find((c) => c.type === "draft.run") as Extract<ServerToRunner, { type: "draft.run" }>;
  assert.match(run.id, /^scout-/);
  const items = ["f1", "f2", "f3", "f4", "f5"].map((id) => ({ from: `T-1#${id}`, title: `Fix ${id}`, brief: `${id} is still there.`, doneWhen: ["A test proves it"] }));
  await f.engine.fromRunner("m1", { type: "draft.done", id: run.id, output: JSON.stringify({ items }), error: null });
  const made = f.store.tasks().filter((t) => t.scoutedFrom);
  return { ...f, run, made };
}

test("a reply with 5 items makes 3 tasks in planning by default", async () => {
  const { made, runs, run } = await scoutWithFivePicks();
  assert.match(run.prompt, /Pick at most 3/);
  assert.equal(made.length, 3);
  for (const t of made) {
    assert.equal(t.state, "planning");
    assert.equal(t.goal, "g");
    assert.match(t.brief, /## Done when\n- A test proves it/);
    assert.ok(t.events.some((e) => e.text === "Scouted from T-1"));
  }
  assert.deepEqual(runs().map((r) => r.state), ["running", "done"]);
  assert.equal(runs().at(-1)!.tasks.length, 3);
});

test("with scoutItems 2, a reply with 5 items makes 2 tasks", async () => {
  const { made } = await scoutWithFivePicks(2);
  assert.equal(made.length, 2);
});

test("a second run skips what the first made, and a backlog task is picked up in place", async () => {
  const f = await scoutWithFivePicks();
  f.store.saveTask(task("T-9", { state: "backlog", title: "Parked" }));
  f.sent.length = 0;
  await f.scout();
  const run = f.sent.find((c) => c.type === "draft.run") as Extract<ServerToRunner, { type: "draft.run" }>;
  assert.doesNotMatch(run.prompt, /from T-1#f1\b/);
  assert.match(run.prompt, /from T-1#f4\b/);
  await f.engine.fromRunner("m1", { type: "draft.done", id: run.id, output: JSON.stringify({ items: [{ from: "T-9", title: "Parked", brief: "Still worth it.", doneWhen: [] }] }), error: null });
  assert.equal(f.store.task("T-9")!.state, "planning");
  assert.equal(f.store.tasks().length, 5);
});

test("scoutRuns: a run on a machine is in what a new subscriber's snapshot gets, running", async () => {
  const f = factory();
  await f.scout();
  assert.ok(f.sent.some((c) => c.type === "draft.run"));
  const got = f.engine.scoutRuns();
  assert.equal(got.length, 1);
  assert.equal(got[0].goal, "g");
  assert.equal(got[0].state, "running");
  assert.equal(got[0].error, null);
});

test("scoutRuns: a running run older than 30 minutes comes back failed, and the goal can be scouted again", async () => {
  const f = factory();
  await f.scout();
  const saved = JSON.parse(f.store.get("scout:g")!);
  saved.run.startedAt = Date.now() - 31 * 60_000;
  f.store.set("scout:g", JSON.stringify(saved));
  const [run] = f.engine.scoutRuns();
  assert.equal(run.state, "failed");
  assert.equal(run.error, "Its agent stopped answering.");
  assert.equal(JSON.parse(f.store.get("scout:g")!).run.state, "running", "only reported as failed, not rewritten");
  await f.scout();
  assert.equal(f.engine.scoutRuns()[0].state, "running");
});

test("scoutRuns: goals never scouted aren't in it", () => {
  assert.deepEqual(factory().engine.scoutRuns(), []);
});

test("nothing left over: done straight away, no machine used", async () => {
  const f = factory();
  f.store.saveTask(task("T-1", { autoReview: review([]) }));
  await f.scout();
  assert.equal(f.sent.length, 0);
  assert.deepEqual(f.runs().map((r) => r.state), ["done"]);
});

test("goalMayFetch: a goal's repos, or for a folder goal with none, its origin", () => {
  const goal = (f: Record<string, unknown>) => ({ id: "g", name: "Goal", repos: [], repo: null, ...f }) as never;
  assert.equal(goalMayFetch(goal({ repo: "acme/app", repos: ["acme/app", "acme/web"] }), "ACME/Web"), true);
  assert.equal(goalMayFetch(goal({ repo: "acme/app", repos: ["acme/app"] }), "acme/other"), false);
  assert.equal(goalMayFetch(goal({ folder: "~/code/app" }), "acme/app"), true);
  assert.equal(goalMayFetch(goal({ folder: "~/code/app", repos: ["acme/app"] }), "acme/other"), false);
  assert.equal(goalMayFetch(goal({}), "acme/app"), false);
});

test("Scout mayFetch: a folder goal's origin repo while running on its machine, nothing else", async () => {
  const f = factory();
  f.store.saveGoal({ ...f.store.goal("g")!, folder: "~/code/app" });
  await f.scout();
  const run = f.sent.find((c) => c.type === "draft.run") as Extract<ServerToRunner, { type: "draft.run" }>;
  assert.equal(run.folder, "~/code/app");
  const scout = (f.engine as unknown as { scout: { mayFetch(id: string, m: string, r: string): boolean } }).scout;
  assert.equal(scout.mayFetch(run.id, "m1", "acme/app"), true);
  assert.equal(scout.mayFetch(run.id, "m2", "acme/app"), false);
  assert.equal(scout.mayFetch("scout-nope", "m1", "acme/app"), false);
  await f.engine.fromRunner("m1", { type: "draft.done", id: run.id, output: JSON.stringify({ items: [] }), error: null });
  assert.equal(f.runs().at(-1)!.state, "done");
  assert.equal(scout.mayFetch(run.id, "m1", "acme/app"), false);
});

test("Scout mayFetch: a repo-based goal still fetches only its repos", async () => {
  const f = factory();
  f.store.saveGoal({ ...f.store.goal("g")!, repo: "acme/app", repos: ["acme/app"] });
  await f.scout();
  const run = f.sent.find((c) => c.type === "draft.run") as Extract<ServerToRunner, { type: "draft.run" }>;
  const scout = (f.engine as unknown as { scout: { mayFetch(id: string, m: string, r: string): boolean } }).scout;
  assert.equal(scout.mayFetch(run.id, "m1", "acme/app"), true);
  assert.equal(scout.mayFetch(run.id, "m1", "acme/other"), false);
});

/** Draft with AI on goal "g", run on m1. */
async function drafting(goal: Record<string, unknown>) {
  const store = new Store(sqlStorage());
  store.saveGoal({ id: "g", name: "Goal", prefix: "S", summary: "", lead: "me", repos: [], repo: null, archived: false, ...goal } as never);
  const sent: ServerToRunner[] = [];
  const machine = { id: "m1", name: "m1", owner: "me", online: true, health: null };
  const drafts = new Drafts(store, { sendTo: () => {}, machines: async () => [machine] as never, hasAgent: () => true, paused: () => false, toRunner: async (_, c) => (sent.push(c), true) });
  const id = crypto.randomUUID();
  await drafts.start("me", id, "Make it faster", "g", "claude");
  const run = sent.find((c) => c.type === "draft.run") as Extract<ServerToRunner, { type: "draft.run" }>;
  return { drafts, run };
}

test("Drafts mayFetch: a folder goal's origin repo while reading on its machine", async () => {
  const { drafts, run } = await drafting({ folder: "~/code/app" });
  assert.equal(run.folder, "~/code/app");
  assert.equal(drafts.mayFetch(run.id, "m1", "acme/app"), true);
  assert.equal(drafts.mayFetch(run.id, "m2", "acme/app"), false);
  await drafts.done(run.id, "m1", JSON.stringify({ title: "Faster", brief: "Make it faster.", doneWhen: ["It's faster"] }), null);
  assert.equal(drafts.mayFetch(run.id, "m1", "acme/app"), false);
});

test("Drafts mayFetch: a repo-based goal still fetches only its repos", async () => {
  const { drafts, run } = await drafting({ repo: "acme/app", repos: ["acme/app"] });
  assert.equal(drafts.mayFetch(run.id, "m1", "acme/app"), true);
  assert.equal(drafts.mayFetch(run.id, "m1", "acme/other"), false);
});

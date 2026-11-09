// MF-358: submit_plan's Mermaid diagrams are checked, stored on the task as D1…, broadcast, and replaced by a re-plan.
import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { Engine } from "../src/factory/engine.ts";
import { Store } from "../src/factory/store.ts";
import { MAX_DIAGRAM_SOURCE, parseDiagrams } from "../src/factory/diagrams.ts";
import { plannerPrompt } from "../src/factory/prompts.ts";

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

const REPO = "acme/factory";
const SESSION = "66666666-6666-4666-8666-666666666666";
const FLOW = "flowchart LR\n  plan[Planner] --> runner[Runner]\n  runner --> review[Review]";

function planning() {
  const store = new Store(sqlStorage());
  const broadcasts: unknown[] = [];
  const hooks = {
    broadcast: (m: unknown) => broadcasts.push(m),
    sendTo: () => {},
    machines: async () => [{ id: "droplet", name: "droplet", owner: "andrea", online: true, sessions: [], tags: ["linux"] }],
    members: async () => [],
    machineChanged: async () => {},
    waitUntil: () => {},
    wakeIn: () => {},
  };
  const DB = { prepare: () => ({ bind: () => ({ run: async () => {} }) }) };
  const MACHINE = { idFromName: (id: string) => id, get: () => ({ fetch: async () => new Response(null) }) };
  const engine = new Engine({ DB, MACHINE } as never, store, hooks as never, { forTask: () => {} } as never, {} as never);
  store.saveGoal({ id: "g", name: "Maple Factory", prefix: "MF", summary: "", lead: "andrea", repos: [REPO], repo: REPO, archived: false } as never);
  const reset = () => store.saveTask({
    id: "MF-1", goal: "g", title: "Draw the flow", state: "planning", owner: "andrea", brief: "", createdAt: 1, updatedAt: 1,
    plan: [], planVersion: 0, doneWhen: [], approvals: [], approvalsNeeded: 1, reviews: [], reviewsNeeded: 1, comments: [], changes: [], events: [],
    mockups: [], diagrams: store.task("MF-1")?.diagrams ?? [], tickets: [], artifacts: [], shareable: false, agent: "claude", machine: "droplet", repo: REPO,
    branch: "agent/mf-1", after: [], followUps: [], requires: null,
    worker: { role: "planner", agent: "claude", machine: "droplet", session: SESSION, startedAt: 1 },
  } as never);
  reset();
  store.savePrivate("MF-1", { worktree: "~/.worktrees/factory/mf-1", repoDir: "~/factory", base: "main", finishing: false, restarts: 0 } as never);
  store.addSession({ id: SESSION, task: "MF-1", role: "planner", machine: "droplet", agent: "claude", started: 1, ended: null, cause: null, kind: "personal" });
  const submit = async (diagrams?: unknown) => (await engine.fromRunner("droplet", { type: "mcp.request", reqId: "r", session: SESSION, tool: "submit_plan", args: {
    summary: "Draw it.",
    steps: [{ text: "Draw", file: "server/src/x.ts" }],
    doneWhen: [{ text: "Tests pass", proof: "tests" }],
    risk: { level: "medium", reasons: ["x"] },
    footprint: { files: 1, lines: 10 },
    ...(diagrams !== undefined ? { diagrams } : {}),
  } } as never)) as { result?: { summary: string }; error?: string };
  return { store, broadcasts, submit, reset, t: () => store.task("MF-1")! };
}

test("submit_plan stores diagrams as D1… on the task and broadcasts them", async () => {
  const f = planning();
  const reply = await f.submit([{ title: "Release flow", source: `  ${FLOW}\r\n`, notes: ["Runner is the hop that changes."] }, { title: "States", source: "stateDiagram-v2\n  [*] --> Planning" }]);
  assert.equal(reply.error, undefined);
  assert.deepEqual(f.t().diagrams, [
    { id: "D1", title: "Release flow", source: FLOW, notes: ["Runner is the hop that changes."] },
    { id: "D2", title: "States", source: "stateDiagram-v2\n  [*] --> Planning", notes: [] },
  ]);
  assert.ok(JSON.stringify(f.broadcasts).includes("Release flow"), "the task update carries the diagrams");
});

test("a re-plan replaces the diagrams, and one without any clears them", async () => {
  const f = planning();
  await f.submit([{ title: "Old", source: FLOW }]);
  f.reset();
  await f.submit([{ title: "New", source: "sequenceDiagram\n  A->>B: hi" }]);
  assert.deepEqual(f.t().diagrams.map((d) => [d.id, d.title]), [["D1", "New"]]);
  f.reset();
  await f.submit();
  assert.deepEqual(f.t().diagrams, []);
});

test("empty, missing or oversized source and too many diagrams are refused, leaving the plan open", async () => {
  const f = planning();
  assert.match(String((await f.submit([{ title: "Blank", source: "   " }])).error), /diagrams\[0\]\.source: required/);
  assert.match(String((await f.submit([{ title: "None" }])).error), /diagrams\[0\]\.source: required/);
  assert.match(String((await f.submit([{ title: "Big", source: "flowchart LR\n" + "A-->B\n".repeat(MAX_DIAGRAM_SOURCE / 6) }])).error), /at most 20000/);
  assert.match(String((await f.submit([{ source: FLOW }])).error), /diagrams\[0\]\.title: required/);
  assert.match(String((await f.submit(Array.from({ length: 7 }, (_, i) => ({ title: `D${i}`, source: FLOW })))).error), /at most 6/);
  assert.match(String((await f.submit("flowchart")).error), /a list of/);
  assert.equal(f.t().state, "planning");
  assert.equal(f.t().planVersion, 0);
  assert.deepEqual(f.t().diagrams, []);
});

test("parseDiagrams caps titles and notes", () => {
  const fail = (m: string): never => { throw new Error(m); };
  const [d] = parseDiagrams([{ title: "x".repeat(200), source: FLOW, notes: Array.from({ length: 20 }, (_, i) => `n${i}`) }], fail);
  assert.equal(d.title.length, 120);
  assert.equal(d.notes.length, 12);
  assert.deepEqual(parseDiagrams(undefined, fail), []);
});

test("the planner prompt offers diagrams", () => {
  const f = planning();
  assert.match(plannerPrompt(f.t(), null), /diagrams \(optional\): up to 6 Mermaid diagrams/);
  assert.match(plannerPrompt(f.t(), null), /Quote any label that contains \/, #, parentheses, brackets or \|, e\.g\. EMB\["\/app\/docs\/embed\.html"\]/);
});

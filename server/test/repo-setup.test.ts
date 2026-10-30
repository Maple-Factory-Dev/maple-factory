// A repo's setup: its prompt additions in the agents' prompts, saved with repos.scripts.set (admins
// only), through the maple MCP's get_repo_setup / save_repo_setup from a session that isn't a
// factory task's, and suggested by a Set up with AI run. Through the engine on a node:sqlite store
// (as scout.test.ts does) with a fake machine hub.
import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { Engine } from "../src/factory/engine.ts";
import { builderPrompt, plannerPrompt, reviewerPrompt } from "../src/factory/prompts.ts";
import { parseSetup } from "../src/factory/repo-setup.ts";
import { Store } from "../src/factory/store.ts";
import type { ServerToClient, ServerToRunner, Task } from "../src/wire.ts";

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
    id, goal: "g", title: id, state: "planning", owner: "boss", brief: `About ${id}`, createdAt: 1, updatedAt: 1, plan: [], planVersion: 1, doneWhen: [],
    approvals: [], approvalsNeeded: 1, reviews: [], reviewsNeeded: 1, comments: [], changes: [], events: [], mockups: [], tickets: [],
    shareable: false, agent: "claude", after: [], followUps: [], ...f,
  } as Task;
}

const REPO = "acme/web";
const PERSONAL = "11111111-1111-4111-8111-111111111111";
const FACTORY = "22222222-2222-4222-8222-222222222222";

/** An engine with one repo, an admin (boss) and a member (pat), each with a machine running a personal session. */
function factory() {
  const store = new Store(sqlStorage());
  const sent: { machine: string; command: ServerToRunner }[] = [];
  const broadcast: ServerToClient[] = [];
  const audits: { actor: string; action: string; detail: unknown }[] = [];
  const env = {
    DB: { prepare: () => ({ bind: (_at: number, actor: string, action: string, _target: string, detail: string) => ({ run: async () => void audits.push({ actor, action, detail: JSON.parse(detail) }) }) }) },
    MACHINE: { idFromName: (n: string) => n, get: (id: string) => ({ fetch: async (_: string, init: { body: string }) => (sent.push({ machine: id, command: JSON.parse(init.body) }), new Response("ok")) }) },
  };
  const live = (id: string, taskId: string | null = null) => ({ session: { id, agent: "claude", cwd: "/tmp", pid: 1, startedAt: 1, taskId } });
  const machines = [
    { id: "boss-mbp", name: "boss-mbp", owner: "boss", online: true, health: null, sessions: [live(PERSONAL), live(FACTORY, "W-1")] },
    { id: "pat-mbp", name: "pat-mbp", owner: "pat", online: true, health: null, sessions: [live(PERSONAL)] },
  ];
  const members = [{ login: "boss", role: "admin" }, { login: "pat", role: "member" }];
  const hooks = { broadcast: (m: ServerToClient) => broadcast.push(m), sendTo: () => {}, machines: async () => machines, members: async () => members, machineChanged: async () => {}, waitUntil: () => {}, wakeIn: () => {} };
  const engine = new Engine(env as never, store, hooks as never, {} as never, {} as never);
  store.saveRepos([{ name: REPO, defaultBranch: "trunk", isPrivate: true, source: "github" }]);
  const as = (login: string, role: "admin" | "member") => ({ member: { login, role } }) as never;
  const mcp = (machine: string, session: string, tool: string, args: Record<string, unknown> = {}) =>
    engine.fromRunner(machine, { type: "mcp.request", reqId: "r", session, tool, args } as never) as Promise<{ result?: { summary: string; data: Record<string, unknown> }; error?: string }>;
  return { store, engine, sent, broadcast, audits, as, mcp };
}

test("prompts: Repo instructions sit between the org's and the goal's, for every role", () => {
  const org = { planner: "ORG-P", builder: "ORG-B", reviewer: "ORG-R" };
  const repo = { planner: "REPO-P", builder: "REPO-B", reviewer: "REPO-R" };
  const goal = { id: "g", name: "Goal", prefix: "W", summary: "", lead: "boss", repos: [REPO], repo: REPO, archived: false, prompts: { planner: "GOAL-P", builder: "GOAL-B", reviewer: "GOAL-R" } } as never;
  const t = task("W-1");
  const order = (prompt: string, role: string) => {
    const at = ["## Org instructions", `ORG-${role}`, "## Repo instructions", `REPO-${role}`, "## Goal instructions", `GOAL-${role}`].map((s) => prompt.indexOf(s));
    assert.ok(at.every((i) => i >= 0), `all three sections are in the ${role} prompt`);
    assert.deepEqual([...at].sort((a, b) => a - b), at, `org, then repo, then goal in the ${role} prompt`);
  };
  order(plannerPrompt(t, goal, org, [], repo), "P");
  order(builderPrompt(t, goal, null, org, [], repo), "B");
  order(reviewerPrompt(t, goal, "main", org, repo), "R");
  assert.doesNotMatch(plannerPrompt(t, goal, org, [], { planner: " ", builder: "", reviewer: "" }), /## Repo instructions/);
});

test("repos.scripts.set: saves prompts with the scripts for admins, audited, and refuses members", async () => {
  const f = factory();
  await f.engine.command({ type: "repos.scripts.set", repo: "ACME/web", scripts: { setup: " npm ci " }, prompts: { planner: "", builder: "Run npm test.", reviewer: "x".repeat(5000) } }, f.as("boss", "admin"));
  const row = f.store.repoSetup(REPO)!;
  assert.deepEqual(row.scripts, { setup: "npm ci" });
  assert.equal(row.prompts!.builder, "Run npm test.");
  assert.equal(row.prompts!.reviewer.length, 4000);
  assert.equal(row.updatedBy, "boss");
  assert.deepEqual(f.store.repoPrompts(REPO), row.prompts);
  assert.deepEqual((f.audits.at(-1)!.detail as { changed: string[] }).changed, ["setup", "prompts.builder", "prompts.reviewer"]);
  const updated = f.broadcast.filter((m) => m.type === "repos.updated").at(-1) as Extract<ServerToClient, { type: "repos.updated" }>;
  assert.equal(updated.scripts![0].prompts!.builder, "Run npm test.");

  // An older app sends no prompts: they're kept.
  await f.engine.command({ type: "repos.scripts.set", repo: REPO, scripts: { setup: "npm i" } }, f.as("boss", "admin"));
  assert.equal(f.store.repoPrompts(REPO)!.builder, "Run npm test.");

  await assert.rejects(
    f.engine.command({ type: "repos.scripts.set", repo: REPO, scripts: {}, prompts: { planner: "mine", builder: "", reviewer: "" } }, f.as("pat", "member")),
    /Only admins/,
  );
  assert.equal(f.store.repoPrompts(REPO)!.planner, "");

  // Prompts alone keep the row; the runner still gets no scripts.
  await f.engine.command({ type: "repos.scripts.set", repo: REPO, scripts: {}, prompts: { planner: "Plan small.", builder: "", reviewer: "" } }, f.as("boss", "admin"));
  assert.equal(f.store.scriptsFor(REPO), null);
  assert.equal(f.store.repoPrompts(REPO)!.planner, "Plan small.");
});

test("a task's session prompt carries its repo's instructions", async () => {
  const f = factory();
  await f.engine.command({ type: "repos.scripts.set", repo: REPO, scripts: {}, prompts: { planner: "Read docs/ARCH.md first.", builder: "", reviewer: "" } }, f.as("boss", "admin"));
  const goal = { id: "g", name: "Goal", prefix: "W", summary: "", lead: "boss", repos: [REPO], repo: REPO, archived: false };
  f.store.saveGoal(goal as never);
  assert.match(plannerPrompt(task("W-2"), goal as never, null, [], f.store.repoPrompts(REPO)), /## Repo instructions\nRead docs\/ARCH.md first./);
});

test("maple MCP: personal sessions get get_repo_setup and save_repo_setup; factory sessions don't", async () => {
  const f = factory();
  const names = async (machine: string, session: string) => ((await f.mcp(machine, session, "tools/list")).result!.data.tools as { name: string }[]).map((t) => t.name);
  assert.deepEqual(await names("boss-mbp", PERSONAL), ["get_repo_setup", "save_repo_setup"]);
  assert.deepEqual(await names("pat-mbp", PERSONAL), ["get_repo_setup", "save_repo_setup"]);
  // A factory task's session (the machine says it has a task), with or without a session record.
  assert.deepEqual(await names("boss-mbp", FACTORY), []);
  assert.match((await f.mcp("boss-mbp", FACTORY, "save_repo_setup", { repo: REPO, prompts: { builder: "x" } })).error!, /isn't working on a factory task/);
  f.store.addSession({ id: FACTORY, task: "W-1", role: "builder", machine: "boss-mbp", agent: "claude", started: 1, ended: null, cause: null, kind: "personal" });
  assert.ok(!(await names("boss-mbp", FACTORY)).includes("save_repo_setup"));
  assert.match((await f.mcp("boss-mbp", FACTORY, "save_repo_setup", { repo: REPO })).error!, /isn't one of the builder's tools/);
  assert.equal(f.store.repoSetup(REPO), null);
});

test("save_repo_setup: an admin's machine saves (audited via MCP); a member's is refused", async () => {
  const f = factory();
  const before = await f.mcp("pat-mbp", PERSONAL, "get_repo_setup", { repo: REPO });
  assert.equal(before.result!.data.updatedBy, null);
  assert.ok((before.result!.data.variables as Record<string, string>).MAPLE_WORKTREE);

  const refused = await f.mcp("pat-mbp", PERSONAL, "save_repo_setup", { repo: REPO, scripts: { setup: "npm ci" } });
  assert.equal(refused.error, "Only admins' sessions can save a repo's setup.");
  assert.equal(f.store.repoSetup(REPO), null);

  assert.match((await f.mcp("boss-mbp", PERSONAL, "save_repo_setup", { repo: "acme/elsewhere" })).error!, /isn't one of the org's repos/);
  assert.match((await f.mcp("boss-mbp", PERSONAL, "save_repo_setup", { repo: REPO, scripts: { timeoutSecs: 0 } })).error!, /1–3600/);

  const saved = await f.mcp("boss-mbp", PERSONAL, "save_repo_setup", { repo: REPO, scripts: { setup: "bin/setup" }, prompts: { builder: "Prove with npm test." } });
  assert.equal(saved.error, undefined);
  assert.equal(saved.result!.summary, `Saved ${REPO}'s setup.`);
  // Only what's passed changes.
  await f.mcp("boss-mbp", PERSONAL, "save_repo_setup", { repo: REPO, prompts: { planner: "Plan it." } });
  const after = (await f.mcp("pat-mbp", PERSONAL, "get_repo_setup", { repo: REPO })).result!.data;
  assert.deepEqual(after.scripts, { setup: "bin/setup" });
  assert.deepEqual(after.prompts, { planner: "Plan it.", builder: "Prove with npm test.", reviewer: "" });
  assert.equal(after.updatedBy, "boss");
  assert.deepEqual(f.audits.at(-1), { actor: "boss", action: "repo.scripts", detail: { repo: REPO, changed: ["prompts.planner"], via: "via MCP from boss-mbp" } });
});

test("parseSetup: takes the last JSON, caps prompts and notes, and rejects oversized scripts and bad timeouts", () => {
  const ok = parseSetup(`I read it.\n\`\`\`json\n${JSON.stringify({ scripts: { setup: " npm ci ", teardown: "", timeoutSecs: 900, other: "x" }, prompts: { builder: "b".repeat(4500), planner: 3 }, notes: ["Uses npm.", "", 4, "n".repeat(400)] })}\n\`\`\``);
  assert.ok("suggestion" in ok);
  assert.deepEqual(ok.suggestion.scripts, { setup: "npm ci", timeoutSecs: 900 });
  assert.equal(ok.suggestion.prompts.builder.length, 4000);
  assert.equal(ok.suggestion.prompts.planner, "");
  assert.deepEqual(ok.suggestion.notes.map((n) => n.length), [9, 300]);

  const big = parseSetup(JSON.stringify({ scripts: { setup: "x".repeat(5000) }, prompts: {} }));
  assert.deepEqual(big, { error: "The agent's suggestion can't be used: The setup script is over 4 KB; put it in a file in the repo and run that." });
  for (const timeoutSecs of [0, 3601, 1.5, "600"]) {
    const bad = parseSetup(JSON.stringify({ scripts: { setup: "npm ci", timeoutSecs } }));
    assert.ok("error" in bad && /1–3600/.test(bad.error), `timeout ${timeoutSecs} is refused`);
  }
  assert.ok("error" in parseSetup("No JSON at all."));
});

test("Set up with AI: an admin's run reads the repo on their machine and its reply becomes the suggestion", async () => {
  const f = factory();
  await assert.rejects(f.engine.command({ type: "repo.setup.start", repo: REPO }, f.as("pat", "member")), /Only admins/);
  await f.engine.command({ type: "repo.setup.start", repo: REPO }, f.as("boss", "admin"));
  const { machine, command } = f.sent.find((s) => s.command.type === "draft.run")!;
  const run = command as Extract<ServerToRunner, { type: "draft.run" }>;
  assert.equal(machine, "boss-mbp");
  assert.match(run.id, /^setup-/);
  assert.equal(run.repo, REPO);
  assert.equal(run.base, "trunk");
  assert.match(run.prompt, /README, CLAUDE\.md or AGENTS\.md/);
  await assert.rejects(f.engine.command({ type: "repo.setup.start", repo: REPO }, f.as("boss", "admin")), /already being set up/);

  // Another machine can't report for it.
  await f.engine.fromRunner("pat-mbp", { type: "draft.progress", id: run.id, text: "Reading secrets", kind: "tool" } as never);
  await f.engine.fromRunner("boss-mbp", { type: "draft.progress", id: run.id, text: "Reading package.json", kind: "tool" } as never);
  await f.engine.fromRunner("boss-mbp", { type: "draft.done", id: run.id, output: JSON.stringify({ scripts: { setup: "npm ci" }, prompts: { builder: "Run npm test." }, notes: ["npm workspace"] }), error: null } as never);
  const runs = f.broadcast.filter((m) => m.type === "repo.setup.updated").map((m) => (m as Extract<ServerToClient, { type: "repo.setup.updated" }>).run);
  assert.deepEqual(runs.map((r) => [r.state, r.progress]), [["running", "Starting…"], ["running", "Reading package.json"], ["done", null]]);
  assert.deepEqual(runs.at(-1)!.suggestion, { scripts: { setup: "npm ci" }, prompts: { planner: "", builder: "Run npm test.", reviewer: "" }, notes: ["npm workspace"] });
  assert.deepEqual(f.engine.setupRuns().map((r) => r.state), ["done"]);
  // Nothing is saved until an admin does.
  assert.equal(f.store.repoSetup(REPO), null);
});

test("Set up with AI: a bad reply fails the run", async () => {
  const f = factory();
  await f.engine.command({ type: "repo.setup.start", repo: REPO }, f.as("boss", "admin"));
  const run = f.sent.find((s) => s.command.type === "draft.run")!.command as Extract<ServerToRunner, { type: "draft.run" }>;
  await f.engine.fromRunner("boss-mbp", { type: "draft.done", id: run.id, output: JSON.stringify({ scripts: { setup: "npm ci", timeoutSecs: 99999 } }), error: null } as never);
  const last = f.engine.setupRuns()[0];
  assert.equal(last.state, "failed");
  assert.match(last.error!, /1–3600/);
});

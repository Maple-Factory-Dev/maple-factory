// A repo's checks (Settings › Worktree scripts): tidied and validated on save, sent with task.finish,
// and a finish one of them stopped (task.finished with a failed check) keeps the task building and is
// typed into its builder, until the third in a row raises a hand. Through the engine on a node:sqlite
// store (as factory.test.ts does) with a fake machine hub.
import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { Engine } from "../src/factory/engine.ts";
import { builderPrompt } from "../src/factory/prompts.ts";
import { checkCommands, parseSetup, scriptsProblem, tidyScripts } from "../src/factory/repo-setup.ts";
import { Store } from "../src/factory/store.ts";
import type { CheckRun, Task } from "../src/wire.ts";

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

const REPO = "acme/web";
const SESSION = "22222222-2222-4222-8222-222222222222";
const LINT = "npm run lint";
const FAILED: CheckRun = { command: LINT, code: 1, timedOut: false, ms: 900, output: "src/a.ts:3:1  error  'x' is unused" };

/** MF-1 building on `mac` in acme/web, its builder live in SESSION; what goes to the machine (commands and typing) is in `sent`. */
function factory(checks: string | null = `${LINT}\nlefthook run pre-commit --all-files`) {
  const store = new Store(sqlStorage());
  const sent: Record<string, unknown>[] = [];
  const pending: Promise<unknown>[] = [];
  const hooks = {
    broadcast: () => {},
    sendTo: () => {},
    machines: async () => [{ id: "mac", sessions: [] }],
    members: async () => [],
    machineChanged: async () => {},
    waitUntil: (p: Promise<unknown>) => pending.push(p),
    wakeIn: () => {},
  };
  const MACHINE = {
    idFromName: (id: string) => id,
    get: () => ({ fetch: async (_: string, init: RequestInit) => (sent.push(JSON.parse(String(init.body))), new Response(null)) }),
  };
  const DB = { prepare: () => ({ bind: () => ({ run: async () => {} }) }) };
  const engine = new Engine({ MACHINE, DB } as never, store, hooks as never, { forTask: () => {} } as never, {} as never);
  store.saveRepos([{ name: REPO, defaultBranch: "main", isPrivate: true, source: "github" }]);
  if (checks) store.saveRepoScripts(REPO, { setup: "npm ci", checks }, "boss");
  store.saveTask({
    id: "MF-1", goal: "g", title: "Fix it", state: "building", owner: "me", brief: "", createdAt: 1, updatedAt: 1, plan: [], planVersion: 1, doneWhen: [],
    approvals: [], approvalsNeeded: 1, reviews: [], reviewsNeeded: 1, comments: [], changes: [], events: [], mockups: [], tickets: [],
    shareable: false, agent: "claude", machine: "mac", repo: REPO, branch: "agent/mf-1",
    worker: { role: "builder", agent: "claude", machine: "mac", session: SESSION, startedAt: 1 },
  } as never);
  store.savePrivate("MF-1", { worktree: "~/.worktrees/web/mf-1", repoDir: "~/web", base: "main", finishing: false, restarts: 0 });
  store.addSession({ id: SESSION, task: "MF-1", role: "builder", machine: "mac", agent: "claude", started: 1, ended: null, cause: null, kind: "team" });
  const settle = async () => { while (pending.length) await pending.shift(); };
  const finish = async () => {
    const reply = (await engine.fromRunner("mac", { type: "mcp.request", reqId: "r", session: SESSION, tool: "finish", args: { summary: "Done." } } as never)) as { result?: { summary: string }; error?: string };
    await settle();
    return reply;
  };
  const finished = async (msg: Record<string, unknown>) => {
    await engine.fromRunner("mac", { type: "task.finished", taskId: "MF-1", branch: "agent/mf-1", base: "main", ...msg } as never);
    await settle();
  };
  const task = () => store.task("MF-1")! as Task;
  const typed = () => sent.filter((m) => "text" in m && !("type" in m)).map((m) => m.text as string);
  return { store, engine, sent, finish, finished, task, typed, settle };
}

test("checks are tidied (trimmed, blank lines dropped) and validated on save", () => {
  const scripts = { checks: "  npm run lint \n\n\t bundle exec rubocop\n \n" };
  assert.equal(scriptsProblem(scripts), null);
  assert.deepEqual(tidyScripts(scripts), { checks: "npm run lint\nbundle exec rubocop" }, "checks alone are something to keep");
  assert.equal(tidyScripts({ checks: " \n " }), null, "blank checks are nothing");
  assert.deepEqual(checkCommands({ checks: "a\n\n b " }), ["a", "b"]);
  assert.deepEqual(checkCommands(null), []);
  const many = Array.from({ length: 21 }, (_, i) => `check-${i}`).join("\n");
  assert.match(scriptsProblem({ checks: many }) ?? "", /at most 20 checks/);
  assert.equal(scriptsProblem({ checks: many.split("\n").slice(0, 20).join("\n") }), null);
  assert.match(scriptsProblem({ checks: `ok\n${"x".repeat(5000)}` }) ?? "", /check is over 4 KB/);
  // Set up with AI's suggestion, as a string or a list.
  const parsed = parseSetup(JSON.stringify({ scripts: { setup: "npm ci", checks: [" npm run lint", "", "lefthook run pre-commit --all-files"] }, prompts: {} }));
  assert.ok("suggestion" in parsed);
  assert.deepEqual(parsed.suggestion.scripts, { setup: "npm ci", checks: "npm run lint\nlefthook run pre-commit --all-files" });
});

test("repos.scripts.set keeps checks, tidied, and refuses more than 20", async () => {
  const f = factory(null);
  await f.engine.command({ type: "repos.scripts.set", repo: REPO, scripts: { checks: " npm run lint\n\n npm test " } }, { member: { login: "boss", role: "admin" } } as never);
  assert.deepEqual(f.store.scriptsFor(REPO), { checks: "npm run lint\nnpm test" });
  await assert.rejects(
    f.engine.command({ type: "repos.scripts.set", repo: REPO, scripts: { checks: Array.from({ length: 21 }, () => "x").join("\n") } }, { member: { login: "boss", role: "admin" } } as never),
    /at most 20 checks/,
  );
});

test("finish sends the repo's checks with task.finish and says it's running them", async () => {
  const f = factory();
  const reply = await f.finish();
  assert.match(reply.result!.summary, /checks run first/);
  const cmd = f.sent.find((m) => m.type === "task.finish")!;
  assert.equal(cmd.checks, `${LINT}\nlefthook run pre-commit --all-files`);
  assert.equal(f.task().liveLog, "Running checks…");

  // A repo with no checks sends none.
  const plain = factory(null);
  await plain.finish();
  assert.equal(plain.sent.find((m) => m.type === "task.finish")!.checks, undefined);
  assert.equal(plain.task().liveLog, "Committing and pushing…");
});

test("a failed check keeps the task building, logs it and types it into the builder", async () => {
  const f = factory();
  await f.finish();
  await f.finished({ ok: false, message: "The check `npm run lint` exited 1, so nothing was committed or pushed.", checks: [{ ...FAILED, command: "echo ok", code: 0 }, FAILED] });
  const t = f.task();
  assert.equal(t.state, "building");
  assert.equal(t.hand ?? null, null, "no hand: the builder fixes it");
  assert.equal(t.pr ?? null, null);
  assert.equal(t.liveLog, null, "Running checks… clears");
  assert.equal(f.store.private("MF-1").finishing, false, "a new finish is taken");
  assert.equal(f.store.private("MF-1").checkFailures, 1);
  assert.ok(t.events.some((e) => e.text === "checks failed: `npm run lint` exited 1"), JSON.stringify(t.events));
  const [said] = f.typed();
  assert.match(said, /The check `npm run lint` exited 1, so nothing was committed or pushed\./);
  assert.match(said, /'x' is unused/);
  assert.match(said, /Fix it, then call finish again\./);
  // And it can finish again.
  assert.ok((await f.finish()).result);
});

test("the third failed check in a row raises a hand instead of typing again", async () => {
  const f = factory();
  for (let i = 0; i < 2; i++) {
    await f.finish();
    await f.finished({ ok: false, checks: [FAILED] });
  }
  assert.equal(f.typed().length, 2);
  assert.equal(f.task().hand ?? null, null);
  await f.finish();
  await f.finished({ ok: false, checks: [{ ...FAILED, command: "git commit (pre-commit hook)" }] });
  const t = f.task();
  assert.equal(f.typed().length, 2, "not typed a third time");
  assert.equal(t.hand?.reason, "needsInput");
  assert.match(t.hand!.summary, /3 times in a row: `git commit \(pre-commit hook\)` exited 1/);
  assert.equal(t.state, "building");
});

test("a failed check with no builder session raises a hand straight away", async () => {
  const f = factory();
  await f.finish();
  f.store.saveTask({ ...f.task(), worker: null } as never);
  await f.finished({ ok: false, checks: [{ ...FAILED, code: null, timedOut: true }] });
  assert.equal(f.typed().length, 0);
  assert.equal(f.task().hand?.reason, "needsInput");
  assert.match(f.task().hand!.summary, /builder isn't running: `npm run lint` timed out/);
});

test("a push after a fix resets the count; a push failure that isn't a check still raises a hand", async () => {
  const f = factory();
  for (let i = 0; i < 2; i++) {
    await f.finish();
    await f.finished({ ok: false, checks: [FAILED] });
  }
  assert.equal(f.store.private("MF-1").checkFailures, 2);
  await f.finish();
  // Not settled: the builder's session closes 8 seconds after the push.
  await f.engine.fromRunner("mac", { type: "task.finished", taskId: "MF-1", branch: "agent/mf-1", base: "main", ok: true, pushed: "fallback", commit: "c".repeat(40), checks: [{ ...FAILED, code: 0 }] } as never);
  assert.equal(f.store.private("MF-1").checkFailures, 0);
  assert.equal(f.task().state, "reviewing");

  const other = factory();
  await other.finish();
  await other.finished({ ok: false, message: "Couldn't push agent/mf-1 to origin: denied" });
  assert.equal(other.task().hand?.reason, "needsInput");
  assert.match(other.task().hand!.summary, /Pushing failed/);
  assert.equal(other.typed().length, 0);
});

test("the builder's prompt lists the repo's checks", () => {
  const t = factory().task();
  const p = builderPrompt(t, null, null, null, [], null, [LINT, "lefthook run pre-commit --all-files"]);
  assert.match(p, /## Checks\nThese must exit 0 in the worktree before `finish` is accepted; run them yourself first/);
  assert.match(p, /- `npm run lint`\n- `lefthook run pre-commit --all-files`/);
  assert.doesNotMatch(builderPrompt(t, null, null), /## Checks/);
});

test("a finish whose branch doesn't merge into its base types the runner's message, names the files, and counts as a try", async () => {
  const f = factory();
  const MERGE: CheckRun = {
    command: "git merge-tree origin/<base> (does it merge?)", code: 1, timedOut: false, ms: 0,
    output: "Conflicts with origin/main in:\n  hello.txt\n  src/a.ts\n\nFetch origin/main, merge it into the branch, resolve every conflict, keep the tests passing, then call finish again.",
  };
  const message = "The branch doesn't merge into main (conflicts in hello.txt, src/a.ts), so nothing was pushed.";
  await f.finish();
  await f.finished({ ok: false, message, checks: [MERGE] });
  const t = f.task();
  assert.equal(t.state, "building");
  assert.equal(t.hand ?? null, null);
  const [told] = f.typed();
  assert.ok(told.startsWith(message), told);
  assert.match(told, /hello\.txt/);
  assert.doesNotMatch(told, /nothing was committed/);
  assert.equal(told.match(/call finish again/g)?.length, 1);
  assert.ok(t.events.some((e) => e.text === "doesn't merge into main: hello.txt, src/a.ts"), JSON.stringify(t.events.map((e) => e.text)));
  for (let i = 0; i < 2; i++) {
    await f.finish();
    await f.finished({ ok: false, message, checks: [MERGE] });
  }
  assert.equal(f.task().hand?.reason, "needsInput");
  assert.match(f.task().hand!.summary, /3 times in a row: its branch doesn't merge into main: hello\.txt, src\/a\.ts/);
});

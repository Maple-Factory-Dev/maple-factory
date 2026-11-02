// Apple checks hand-off (MF-336): a finish on a Linux box skips the repo's `[xcode,macos]` checks
// (MF-335); once it's pushed, the factory sends just those to a Mac with the tags as a proof job
// (`task.prove_checks`, no agent session), keeps the answer (`task.checks_proved`) for that head only,
// and merge waits for them to pass. Through the engine on a node:sqlite store with a fake machine hub,
// as factory-checks.test.ts does.
import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { Engine } from "../src/factory/engine.ts";
import { DEFAULT_SETTINGS, Store } from "../src/factory/store.ts";
import type { CheckRun, Machine, Task } from "../src/wire.ts";

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

const REPO = "acme/app";
const ME = { member: { login: "me", role: "admin" } } as never;
const SESSION = "33333333-3333-4333-8333-333333333333";
const XCODE = "xcodebuild -scheme App test";
const HEAD = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678";
const HEAD2 = "ffeeddccbbaa99887766554433221100ffeeddcc";

const machine = (id: string, owner: string, tags: string[], online = true): Machine =>
  ({ id, name: id, owner, online, sessions: [], usage: [], tags, health: { cores: 8, load1: 0.1 } }) as unknown as Machine;

/** MF-1 building on the Linux box `linux` (owner `me`), its builder live; machines as given. */
function factory(machines: Machine[], opts: { shareable?: boolean } = {}) {
  const store = new Store(sqlStorage());
  const sent: (Record<string, unknown> & { to: string })[] = [];
  const pending: Promise<unknown>[] = [];
  const hooks = {
    broadcast: () => {},
    sendTo: () => {},
    machines: async () => machines,
    members: async () => [],
    machineChanged: async () => {},
    waitUntil: (p: Promise<unknown>) => pending.push(p),
    wakeIn: () => {},
  };
  const MACHINE = {
    idFromName: (id: string) => id,
    get: (to: string) => ({ fetch: async (_: string, init: RequestInit) => (sent.push({ to, ...JSON.parse(String(init.body)) }), new Response(null)) }),
  };
  const DB = { prepare: () => ({ bind: () => ({ run: async () => {} }) }) };
  const engine = new Engine({ MACHINE, DB } as never, store, hooks as never, { forTask: () => {} } as never, {} as never);
  store.saveRepos([{ name: REPO, defaultBranch: "main", isPrivate: true, source: "github" }]);
  store.saveRepoScripts(REPO, { checks: `npm run lint\n[xcode,macos] ${XCODE}` }, "boss");
  store.saveTask({
    id: "MF-1", goal: "g", title: "Fix it", state: "building", owner: "me", brief: "", createdAt: 1, updatedAt: 1, plan: [], planVersion: 1, doneWhen: [],
    approvals: [], approvalsNeeded: 0, reviews: [], reviewsNeeded: 0, comments: [], changes: [], events: [], mockups: [], tickets: [],
    shareable: opts.shareable ?? false, agent: "claude", machine: "linux", repo: REPO, branch: "agent/mf-1",
    worker: { role: "builder", agent: "claude", machine: "linux", session: SESSION, startedAt: 1 },
  } as never);
  store.savePrivate("MF-1", { worktree: "~/.worktrees/app/mf-1", repoDir: "~/app", base: "main", finishing: false, restarts: 0 });
  store.addSession({ id: SESSION, task: "MF-1", role: "builder", machine: "linux", agent: "claude", started: 1, ended: null, cause: null, kind: "personal" });
  const settle = async () => { while (pending.length) await pending.shift(); };
  const task = () => store.task("MF-1")! as Task;
  /** Finish on the Linux box, then its push of `head` comes back. */
  const buildAndPush = async (head = HEAD) => {
    await engine.fromRunner("linux", { type: "mcp.request", reqId: "r", session: SESSION, tool: "finish", args: { summary: "Done." } } as never);
    await settle();
    // Its builder already gone: no wait for the session to close (CLOSE_AFTER_MS).
    const t = store.task("MF-1")!;
    t.worker = null;
    store.saveTask(t);
    await engine.fromRunner("linux", { type: "task.finished", taskId: "MF-1", ok: true, pushed: "fallback", branch: "agent/mf-1", base: "main", commit: head } as never);
    await settle();
    await engine.pump();
    await settle();
  };
  const jobs = () => sent.filter((m) => m.type === "task.prove_checks");
  const proved = async (from: string, job: Record<string, unknown>, checks: CheckRun[], over: Record<string, unknown> = {}) => {
    await engine.fromRunner(from, { type: "task.checks_proved", taskId: "MF-1", jobId: job.jobId, head: job.head, ok: checks.every((c) => c.code === 0), checks, ...over } as never);
    await settle();
  };
  /** Passed review, no approvals needed, CI green: only the Apple checks can hold it. */
  const reviewed = () => {
    const t = task();
    t.autoReview!.rounds.at(-1)!.verdict = "passed";
    store.saveTask(t);
  };
  const mergeReady = () => (engine as unknown as { mergeReady(t: Task): boolean }).mergeReady(task());
  return { store, engine, sent, settle, task, buildAndPush, jobs, proved, reviewed, mergeReady };
}

const PASS: CheckRun = { command: XCODE, code: 0, timedOut: false, ms: 41000, output: "** TEST SUCCEEDED **" };
const FAIL: CheckRun = { command: XCODE, code: 65, timedOut: false, ms: 38000, output: "** TEST FAILED **" };

test("a Linux finish sends only the checks it can run, and hands the [xcode,macos] one to the owner's Mac for the pushed head", async () => {
  const f = factory([machine("linux", "me", ["linux", "x86_64"]), machine("mbp-14", "me", ["macos", "xcode", "arm64"])]);
  await f.buildAndPush();
  const finish = f.sent.find((m) => m.type === "task.finish")!;
  assert.equal(finish.to, "linux");
  assert.equal(finish.checks, "npm run lint");
  const [job, ...more] = f.jobs();
  assert.equal(more.length, 0);
  assert.equal(job!.to, "mbp-14");
  assert.deepEqual({ head: job!.head, branch: job!.branch, checks: job!.checks, repo: job!.repo }, { head: HEAD, branch: "agent/mf-1", checks: XCODE, repo: REPO });
  // No agent session: nothing opened anywhere for it.
  assert.equal(f.sent.filter((m) => m.type === "session.open").length, 0);
  const a = f.task().appleChecks!;
  assert.deepEqual({ state: a.state, head: a.head, machine: a.machine, needs: a.needs, commands: a.commands }, { state: "running", head: HEAD, machine: "mbp-14", needs: ["macos", "xcode"], commands: [XCODE] });
});

test("a passing answer unblocks merge; until then merge waits and says why", async () => {
  const f = factory([machine("linux", "me", ["linux"]), machine("mbp-14", "me", ["macos", "xcode"])]);
  await f.buildAndPush();
  f.reviewed();
  assert.equal(f.mergeReady(), false);
  await assert.rejects(f.engine.command({ type: "task.merge", id: "MF-1" } as never, ME), /Apple checks are still running on mbp-14/);
  // MF-335 lists it as not run on the Linux box until it runs elsewhere (or is waived).
  assert.deepEqual(f.task().checksNotRun!.map((n) => [n.command, n.status]), [[XCODE, "open"]]);
  await f.proved("mbp-14", f.jobs()[0]!, [PASS]);
  assert.equal(f.task().appleChecks!.state, "passed");
  assert.deepEqual(f.task().appleChecks!.checks, [PASS]);
  assert.deepEqual(f.task().checksNotRun, []);
  assert.equal(f.mergeReady(), true);
});

test("a failing answer keeps merge blocked and leaves a comment with its output", async () => {
  const f = factory([machine("linux", "me", ["linux"]), machine("mbp-14", "me", ["macos", "xcode"])]);
  await f.buildAndPush();
  f.reviewed();
  await f.proved("mbp-14", f.jobs()[0]!, [FAIL]);
  assert.equal(f.task().appleChecks!.state, "failed");
  assert.equal(f.mergeReady(), false);
  await assert.rejects(f.engine.command({ type: "task.merge", id: "MF-1" } as never, ME), /Apple checks failed on a1b2c3d/);
  const c = f.task().comments.at(-1)!;
  assert.match(c.text, /exited 65/);
  assert.match(c.text, /TEST FAILED/);
});

test("a new head throws the old results away and sends a new job for it", async () => {
  const f = factory([machine("linux", "me", ["linux"]), machine("mbp-14", "me", ["macos", "xcode"])]);
  await f.buildAndPush();
  await f.proved("mbp-14", f.jobs()[0]!, [PASS]);
  // CI recheck / a push from elsewhere moves the head.
  const t = f.task();
  t.pr!.head = HEAD2;
  f.store.saveTask(t);
  await f.engine.pump();
  await f.settle();
  const a = f.task().appleChecks!;
  assert.deepEqual({ state: a.state, head: a.head, checks: a.checks }, { state: "running", head: HEAD2, checks: [] });
  assert.equal(f.jobs().length, 2);
  assert.equal(f.jobs()[1]!.head, HEAD2);
  f.reviewed();
  assert.equal(f.mergeReady(), false);
});

test("a stale job id or head is ignored", async () => {
  const f = factory([machine("linux", "me", ["linux"]), machine("mbp-14", "me", ["macos", "xcode"])]);
  await f.buildAndPush();
  const job = f.jobs()[0]!;
  await f.proved("mbp-14", { ...job, jobId: "old-job" }, [PASS]);
  assert.equal(f.task().appleChecks!.state, "running");
  await f.proved("mbp-14", { ...job, head: HEAD2 }, [PASS]);
  assert.equal(f.task().appleChecks!.state, "running");
  // From another machine than the job went to.
  await f.proved("linux", job, [PASS]);
  assert.equal(f.task().appleChecks!.state, "running");
  await f.proved("mbp-14", job, [PASS]);
  assert.equal(f.task().appleChecks!.state, "passed");
});

test("with no Mac online it waits with a clear reason, then goes once one comes online", async () => {
  const machines = [machine("linux", "me", ["linux"]), machine("mbp-14", "me", ["macos", "xcode"], false)];
  const f = factory(machines);
  await f.buildAndPush();
  const a = f.task().appleChecks!;
  assert.equal(a.state, "waiting");
  assert.equal(a.reason, "Waiting for mbp-14 (macos, xcode) to come online.");
  assert.equal(f.jobs().length, 0);
  f.reviewed();
  await assert.rejects(f.engine.command({ type: "task.merge", id: "MF-1" } as never, ME), /waiting: Waiting for mbp-14/);
  machines[1]!.online = true;
  await f.engine.pump();
  await f.settle();
  assert.equal(f.jobs()[0]!.to, "mbp-14");
  assert.equal(f.task().appleChecks!.state, "running");
});

test("a job on a Mac that drops before answering is sent again", async () => {
  const machines = [machine("linux", "me", ["linux"]), machine("mbp-14", "me", ["macos", "xcode"]), machine("mini", "me", ["macos", "xcode"])];
  const f = factory(machines);
  await f.buildAndPush();
  const first = f.jobs()[0]!;
  machines.find((m) => m.id === first.to)!.online = false;
  await f.engine.pump();
  await f.settle();
  const second = f.jobs()[1]!;
  assert.notEqual(second.to, first.to);
  assert.notEqual(second.jobId, first.jobId);
  await f.proved(first.to, first, [PASS]); // the dropped one's late answer
  assert.equal(f.task().appleChecks!.state, "running");
});

test("a teammate's Mac runs them only for a shareable task and only within what it lends", async () => {
  const theirs = machine("their-mac", "pat", ["macos", "xcode"]);
  // Not shareable: never a teammate's machine.
  let f = factory([machine("linux", "me", ["linux"]), theirs]);
  await f.buildAndPush();
  assert.equal(f.jobs().length, 0);
  assert.match(f.task().appleChecks!.reason!, /None of me's machines has macos, xcode/);
  // Shareable, but it lends nothing (teamSlots 0).
  f = factory([machine("linux", "me", ["linux"]), theirs], { shareable: true });
  await f.buildAndPush();
  assert.equal(f.jobs().length, 0);
  assert.match(f.task().appleChecks!.reason!, /team machine with macos, xcode that lends a slot/);
  // It lends a slot: used.
  f.store.saveSettings("their-mac", { ...DEFAULT_SETTINGS, teamSlots: 1 });
  await f.engine.pump();
  await f.settle();
  assert.equal(f.jobs()[0]!.to, "their-mac");
  // Over its load cap: not used.
  const busy = factory([machine("linux", "me", ["linux"]), { ...theirs, health: { cores: 8, load1: 8 } } as Machine], { shareable: true });
  busy.store.saveSettings("their-mac", { ...DEFAULT_SETTINGS, teamSlots: 1 });
  await busy.buildAndPush();
  assert.equal(busy.jobs().length, 0);
});

test("a finish on a Mac that ran everything leaves no hand-off", async () => {
  const f = factory([machine("linux", "me", ["linux", "macos", "xcode"])]);
  await f.buildAndPush();
  assert.equal(f.sent.find((m) => m.type === "task.finish")!.checks, `npm run lint\n${XCODE}`);
  assert.equal(f.task().appleChecks ?? null, null);
  assert.equal(f.jobs().length, 0);
});

test("a person waiving the check lets it merge without the Mac", async () => {
  const f = factory([machine("linux", "me", ["linux"]), machine("mbp-14", "me", ["macos", "xcode"], false)]);
  await f.buildAndPush();
  f.reviewed();
  assert.equal(f.mergeReady(), false);
  await f.engine.command({ type: "task.waiveCheck", id: "MF-1", command: XCODE, note: "UI-only change, ran it locally" } as never, ME);
  assert.equal(f.mergeReady(), true);
});

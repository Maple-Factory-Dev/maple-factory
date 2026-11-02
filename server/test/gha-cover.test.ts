// GitHub Actions covering a check a machine couldn't run (MF-337): `[macos] xcodebuild … → gha:mac-build`
// is never run as shell, isn't handed to a Mac, and its not-run item settles from the named check run
// on the PR's head: passed → covered (with the run's link) and merge goes ahead; failed → failed and
// merge waits; queued, missing or skipped → still open and waivable.
import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { Engine } from "../src/factory/engine.ts";
import { checksFor, parseCheck, scriptsProblem, stripCover } from "../src/factory/repo-setup.ts";
import type { Check } from "../src/github.ts";
import { Store } from "../src/factory/store.ts";

const REPO = "acme/factory";
const SESSION = "55555555-5555-4555-8555-555555555555";
const ANDREA = { member: { login: "andrea", role: "member" } } as never;
const CHECKS = "npm test\n[macos] xcodebuild test -scheme MapleFactory → gha:mac-build\n[macos] swift test --filter MapleKitTests -> gha:mac-test";
const SWIFT = "swift test --filter MapleKitTests";
const XCODE = "xcodebuild test -scheme MapleFactory";
const HEAD = "a".repeat(40);

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


type M = { id: string; name: string; owner: string; online: boolean; sessions: never[]; tags: string[] | null };

/** Andrea's droplet (listed first, so a pick that ignored tags would land there) and Mac, and Sam's Linux box lending every idle slot. */
function machines(): M[] {
  return [
    { id: "droplet", name: "droplet", owner: "andrea", online: true, sessions: [], tags: ["linux", "x86_64"] },
    { id: "mac", name: "Andrea's MacBook", owner: "andrea", online: true, sessions: [], tags: ["arm64", "macos", "xcode"] },
    { id: "sam-linux", name: "sam's box", owner: "sam", online: true, sessions: [], tags: ["linux"] },
  ];
}

function factory(task: Record<string, unknown> = {}, env: Record<string, string> = {}) {
  const store = new Store(sqlStorage());
  const pending: Promise<unknown>[] = [];
  const sent: { to: string; body: Record<string, unknown> }[] = [];
  const list = machines();
  const hooks = {
    broadcast: () => {},
    sendTo: () => {},
    machines: async () => list,
    members: async () => [],
    machineChanged: async () => {},
    waitUntil: (p: Promise<unknown>) => pending.push(p),
    wakeIn: () => {},
  };
  const DB = { prepare: () => ({ bind: () => ({ run: async () => {} }) }) };
  const MACHINE = {
    idFromName: (id: string) => id,
    get: (to: string) => ({ fetch: async (_: string, init: RequestInit) => (sent.push({ to, body: JSON.parse(String(init.body)) }), new Response(null)) }),
  };
  const engine = new Engine({ DB, MACHINE, ...env } as never, store, hooks as never, { forTask: () => {} } as never, {} as never);
  store.saveGoal({ id: "g", name: "Maple Factory", prefix: "MF", summary: "", lead: "andrea", repos: [REPO], repo: REPO, archived: false } as never);
  store.saveRepoScripts(REPO, { checks: CHECKS, requirePaths: "apps/mac/** macos\napps/ios/** macos,xcode" }, "andrea");
  // Sam lends every idle slot to the team.
  store.saveSettings("sam-linux", { ...store.settings("sam-linux"), lendIdle: true });
  store.saveTask({
    id: "MF-1", goal: "g", title: "Mac app: a new button", state: "building", owner: "andrea", brief: "", createdAt: 1, updatedAt: 1,
    plan: [{ text: "Add the button", file: "apps/mac/Sources/MapleFactory/Button.swift", progress: "pending" }], planVersion: 1, doneWhen: [],
    approvals: ["andrea"], approvalsNeeded: 1, reviews: [], reviewsNeeded: 1, comments: [], changes: [], events: [], mockups: [], tickets: [], artifacts: [],
    shareable: false, agent: "claude", machine: null, repo: REPO, branch: "agent/mf-1", after: [], followUps: [], requires: ["macos"],
    ...task,
  } as never);
  const settle = async () => { while (pending.length) await pending.shift(); };
  const t = () => store.task("MF-1")!;
  const pump = async () => { await engine.pump(); await settle(); };
  const opened = () => sent.filter((s) => s.body.type === "session.open");
  const at = (id: string) => list.find((m) => m.id === id)!;
  return { store, engine, sent, list, t, pump, opened, at, settle };
}


/** MF-1 building on the droplet, its builder live, nothing left to prove. */
function finishing(machine = "droplet") {
  const f = factory({ machine, requires: null, worker: { role: "builder", agent: "claude", machine, session: SESSION, startedAt: 1 } });
  f.store.savePrivate("MF-1", { worktree: "~/.worktrees/factory/mf-1", repoDir: "~/factory", base: "main", finishing: false, restarts: 0 } as never);
  f.store.addSession({ id: SESSION, task: "MF-1", role: "builder", machine, agent: "claude", started: 1, ended: null, cause: null, kind: "personal" });
  const finish = async () => (await f.engine.fromRunner(machine, { type: "mcp.request", reqId: "r", session: SESSION, tool: "finish", args: { summary: "Done." } } as never)) as { result?: { summary: string }; error?: string };
  const finished = async (extra: Record<string, unknown>) => {
    await f.engine.fromRunner(machine, { type: "task.finished", taskId: "MF-1", ok: true, pushed: "fallback", branch: "agent/mf-1", base: "main", commit: HEAD, ...extra } as never);
    await f.settle();
  };
  return { ...f, finish, finished };
}

const RUN = "https://github.com/acme/factory/actions/runs/9/job/11";
const run = (name: string, status: Check["status"], extra: Partial<Check> = {}): Check => ({ name, status, duration: null, suite: 1, run: 9, id: 11, job: 11, url: RUN, ...extra });

test("parseCheck reads → gha:<name> and -> gha:<name>, strips it from the command, and refuses a malformed one", () => {
  assert.deepEqual(parseCheck("[macos] xcodebuild test → gha:mac-build"), { command: "xcodebuild test", requires: ["macos"], covers: "mac-build" });
  assert.deepEqual(parseCheck("[macos] swift test -> gha:mac-test"), { command: "swift test", requires: ["macos"], covers: "mac-test" });
  assert.deepEqual(parseCheck("make lint →  gha:Build (macos-15)"), { command: "make lint", requires: [], covers: "Build (macos-15)" });
  assert.deepEqual(parseCheck("[macos] xcodebuild test"), { command: "xcodebuild test", requires: ["macos"] });
  assert.match(String((parseCheck("[macos] xcodebuild test → mac-build") as { error: string }).error), /not a GitHub check/);
  assert.match(String((parseCheck("[macos] xcodebuild test → gha:") as { error: string }).error), /empty GitHub check/);
  assert.match(String(scriptsProblem({ checks: "npm test\n[macos] xcodebuild -> gha:" })), /empty GitHub check/);
  assert.equal(scriptsProblem({ checks: CHECKS }), null);
  assert.equal(stripCover("[macos] xcodebuild test → gha:mac-build"), "[macos] xcodebuild test");
  assert.equal(stripCover("echo a -> b"), "echo a -> b", "an arrow that isn't a gha: cover stays");
  // What a machine runs or skips: bare commands.
  assert.deepEqual(checksFor({ checks: CHECKS }, ["linux"]), { run: ["npm test"], skipped: [{ command: "xcodebuild test -scheme MapleFactory", missing: ["macos"] }, { command: SWIFT, missing: ["macos"] }] });
  assert.deepEqual(checksFor({ checks: CHECKS }, ["macos"]).run, ["npm test", "xcodebuild test -scheme MapleFactory", SWIFT]);
});

test("the suffix never reaches the runner, and covered checks aren't handed to a Mac", async () => {
  const f = finishing();
  await f.finish();
  await f.settle();
  const sent = f.sent.find((s) => s.body.type === "task.finish")!.body;
  assert.equal(sent.checks, "npm test");
  assert.equal(sent.checkLines, `npm test\n[macos] ${XCODE}\n[macos] ${SWIFT}`);
  assert.doesNotMatch(String(sent.checkLines), /gha:|→|->/);
  await f.finished({ checks: [{ command: "npm test", code: 0, timedOut: false, ms: 900, output: "ok" }], notRun: [{ command: XCODE, reason: "needs macos", kind: "requirement" }, { command: SWIFT, reason: "needs macos", kind: "requirement" }] });
  const t = f.t();
  assert.equal(t.state, "reviewing");
  assert.equal(t.appleChecks ?? null, null, "nothing for a Mac: GitHub Actions covers both");
  assert.deepEqual(t.checksNotRun?.map((n) => [n.command, n.status, n.cover, n.reason]), [[XCODE, "open", "mac-build", "waiting for gha:mac-build"], [SWIFT, "open", "mac-test", "waiting for gha:mac-test"]]);
});

test("an uncovered [macos] check is still handed to a Mac next to a covered one", async () => {
  const f = finishing();
  f.store.saveRepoScripts(REPO, { checks: `npm test\n[macos] ${XCODE} → gha:mac-build\n[macos] make mac` }, "andrea");
  await f.finish();
  await f.settle();
  await f.finished({});
  assert.deepEqual(f.t().appleChecks?.commands, ["make mac"]);
  assert.deepEqual(f.t().checksNotRun?.map((n) => [n.command, n.cover]), [[XCODE, "mac-build"], ["make mac", null]]);
});

/** MF-1 reviewed, green, low risk (it would auto-merge), with xcodebuild covered by gha:mac-build. */
function ready() {
  const f = factory({
    state: "reviewing", machine: "droplet", requires: null, reviewsNeeded: 0, risk: { level: "low", reasons: [], areas: [], factors: [] },
    autoReview: { maxRounds: 3, rounds: [{ number: 1, verdict: "passed", found: 0, at: 1, fix: null }], summary: "", ask: [], proofs: [], findings: [] },
    pr: { number: 7, url: null, state: "open", head: HEAD, branch: "agent/mf-1", base: "main", checks: [{ name: "ci", status: "passed" }] },
    checksNotRun: [{ command: XCODE, reason: "waiting for gha:mac-build", kind: "requirement", status: "open", machine: "droplet", at: 1, note: null, by: null, resolvedAt: null, cover: "mac-build", url: null }],
  }, { MERGE_GRACE_MS: "60000" });
  f.store.savePrivate("MF-1", { worktree: "~/.worktrees/mf-1", repoDir: "~/factory", base: "main", finishing: false, restarts: 0, merging: false, mergeChecked: HEAD } as never);
  const policyChanged = () => (f.engine as unknown as { policyChanged(): Promise<void> }).policyChanged();
  const cover = async (found: Check[]) => {
    const t = f.t();
    const changed = f.engine.coverNotRun(t, found);
    f.store.saveTask(t);
    await policyChanged();
    return changed;
  };
  return { ...f, policyChanged, cover };
}

test("a passing mac-build run proves the item with its link, and auto-merge goes ahead", async () => {
  const f = ready();
  await f.policyChanged();
  assert.equal(f.t().mergeAt ?? null, null, "waits while it's open");
  assert.equal(await f.cover([run("ci", "passed"), run("mac-build", "passed")]), true);
  const item = f.t().checksNotRun![0]!;
  assert.deepEqual([item.status, item.url, item.cover], ["covered", RUN, "mac-build"]);
  assert.ok(item.resolvedAt);
  assert.ok(f.t().events.some((e) => e.text === "`xcodebuild test -scheme MapleFactory` proved by GitHub Actions mac-build on aaaaaaa"));
  assert.equal(f.t().waiting ?? null, null);
  assert.ok(f.t().mergeAt != null, "the countdown starts");
  await assert.rejects(f.engine.command({ type: "task.waiveCheck", id: "MF-1", command: XCODE, note: "x" } as never, ANDREA), /already proved/);
  assert.equal(await f.cover([run("ci", "passed"), run("mac-build", "passed")]), false, "the same result again changes nothing");
});

test("a failing mac-build run fails the item with its link and blocks the merge", async () => {
  const f = ready();
  await f.cover([run("mac-build", "failed")]);
  const item = f.t().checksNotRun![0]!;
  assert.deepEqual([item.status, item.url], ["failed", RUN]);
  assert.equal(f.t().mergeAt ?? null, null);
  assert.equal(f.t().waiting, "gha:mac-build failed on aaaaaaa");
  assert.ok(f.t().comments.some((c) => c.author === "factory" && c.text.includes(RUN) && c.text.includes("mac-build")));
  await assert.rejects(f.engine.command({ type: "task.waiveCheck", id: "MF-1", command: XCODE, note: "x" } as never, ANDREA), /failed on this head/);
  // A re-run that passes clears it.
  await f.cover([run("mac-build", "passed", { url: RUN + "0" })]);
  assert.deepEqual([f.t().checksNotRun![0]!.status, f.t().checksNotRun![0]!.url], ["covered", RUN + "0"]);
  assert.ok(f.t().mergeAt != null);
});

for (const [what, found] of [
  ["queued", [run("mac-build", "queued")]],
  ["running", [run("mac-build", "running")]],
  ["missing", [run("ci", "passed")]],
  ["skipped", [run("mac-build", "passed", { skipped: true })]],
] as const) {
  test(`a ${what} mac-build run leaves the item open and waivable`, async () => {
    const f = ready();
    await f.cover([...found]);
    const item = f.t().checksNotRun![0]!;
    assert.deepEqual([item.status, item.url, item.reason], ["open", null, "waiting for gha:mac-build"]);
    assert.equal(f.t().mergeAt ?? null, null);
    assert.equal(f.t().waiting, "waiting on 1 check not run here: waiting for gha:mac-build");
    await f.engine.command({ type: "task.waiveCheck", id: "MF-1", command: XCODE, note: "Ran it by hand." } as never, ANDREA);
    assert.equal(f.t().checksNotRun![0]!.status, "waived");
    assert.ok(f.t().mergeAt != null);
    // A waived item isn't settled by a later run.
    assert.equal(f.engine.coverNotRun(f.t(), [run("mac-build", "failed")]), false);
  });
}

test("a new head's finish starts a covered item open again", async () => {
  const f = finishing();
  await f.finish();
  await f.settle();
  await f.finished({});
  const t = f.t();
  t.pr = { ...t.pr!, head: HEAD };
  f.engine.coverNotRun(t, [run("mac-build", "passed"), run("mac-test", "failed")]);
  f.store.saveTask(t);
  assert.deepEqual(f.t().checksNotRun?.map((n) => n.status), ["covered", "failed"]);
  f.store.saveTask({ ...f.t(), state: "building", worker: { role: "builder", agent: "claude", machine: "droplet", session: SESSION, startedAt: 2 } } as never);
  await f.finish();
  await f.settle();
  await f.finished({ commit: "b".repeat(40) });
  assert.deepEqual(f.t().checksNotRun?.map((n) => [n.status, n.url, n.cover]), [["open", null, "mac-build"], ["open", null, "mac-test"]]);
});

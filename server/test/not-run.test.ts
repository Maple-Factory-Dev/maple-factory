// Checks a machine can't run (MF-335): a Linux finish of a repo with a `[macos] ` check records it as
// "not run here: needs macos" instead of failing, still goes to review, and auto-merge waits until a
// person waives it with a note. An older runner's plain-string `notRun` is still read. Through the
// engine on a node:sqlite store (as routing.test.ts does).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { Engine, normalizeNotRun } from "../src/factory/engine.ts";
import { Store } from "../src/factory/store.ts";
import { reviewerPrompt } from "../src/factory/prompts.ts";

const REPO = "acme/factory";
const SESSION = "55555555-5555-4555-8555-555555555555";
const ANDREA = { member: { login: "andrea", role: "member" } } as never;
const CHECKS = "npm test\n[macos] xcodebuild test -scheme MapleFactory";
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

test("a Linux finish sends the tagged lines, records the [macos] check as not run (needs macos) and still goes to review", async () => {
  const f = finishing();
  const reply = await f.finish();
  await f.settle();
  const sent = f.sent.find((s) => s.body.type === "task.finish")!.body;
  assert.equal(sent.checks, "npm test", "older runners still get only what they can run");
  assert.equal(sent.checkLines, CHECKS, "newer runners get the tags, to skip with a reason");
  assert.match(String(reply.result?.summary), /needs macos/);
  await f.finished({
    checks: [{ command: "npm test", code: 0, timedOut: false, ms: 900, output: "ok" }],
    notRun: [{ command: XCODE, reason: "needs macos", kind: "requirement" }],
  });
  const t = f.t();
  assert.equal(t.state, "reviewing");
  assert.equal(t.autoReview?.rounds.at(-1)?.verdict, "inProgress", "the review starts: the skipped check didn't fail the finish");
  assert.deepEqual(t.checksNotRun?.map((n) => [n.command, n.reason, n.kind, n.status, n.machine]), [[XCODE, "needs macos", "requirement", "open", "droplet"]]);
  assert.ok(t.events.some((e) => e.text === "1 check not run here: needs macos"), JSON.stringify(t.events.map((e) => e.text)));
  // The reviewer hears about it in its own section, not as a failure.
  const prompt = reviewerPrompt(t, f.store.goal("g")!, "main", null as never, [], null as never, null);
  assert.match(prompt, /## Checks not run on its machine\n- `xcodebuild test -scheme MapleFactory`: not run here \(needs macos\)/);
  assert.match(prompt, /don't treat them as failures/);
});

test("an older runner that says nothing about it: the factory's own skip (needs macos) is still recorded", async () => {
  const f = finishing();
  await f.finish();
  await f.settle();
  await f.finished({ checks: [{ command: "npm test", code: 0, timedOut: false, ms: 900, output: "ok" }] });
  assert.equal(f.t().state, "reviewing");
  assert.deepEqual(f.t().checksNotRun?.map((n) => [n.command, n.reason, n.status]), [[XCODE, "needs macos", "open"]]);
});

test("an older runner's plain-string notRun is accepted, read as skipped after an earlier failure", async () => {
  const f = finishing();
  await f.finish();
  await f.settle();
  await f.finished({ notRun: ["npm run lint"] });
  assert.equal(f.t().state, "reviewing");
  // Only the requirement skip is an open item; a plain string never is.
  assert.deepEqual(f.t().checksNotRun?.map((n) => n.command), [XCODE]);
  assert.deepEqual(normalizeNotRun(["npm run lint"]), [{ command: "npm run lint", reason: "skipped after an earlier failure", kind: "afterFailure" }]);
  // The shared protocol fixture reads the same way here.
  const fx = JSON.parse(readFileSync(new URL("../../protocol/fixtures/not-run/legacy-strings.json", import.meta.url), "utf8"));
  assert.deepEqual(normalizeNotRun(fx.wire.notRun), fx.notRun);
});

/** MF-1 reviewed, proven, green and low risk (so it would auto-merge), with `xcodebuild` not run on the droplet. */
function ready() {
  const f = factory({
    state: "reviewing", machine: "droplet", requires: null, reviewsNeeded: 0, risk: { level: "low", reasons: [], areas: [], factors: [] },
    autoReview: { maxRounds: 3, rounds: [{ number: 1, verdict: "passed", found: 0, at: 1, fix: null }], summary: "", ask: [], proofs: [], findings: [] },
    pr: { number: 7, url: null, state: "open", head: HEAD, branch: "agent/mf-1", base: "main", checks: [{ name: "ci", status: "passed" }] },
    checksNotRun: [{ command: XCODE, reason: "needs macos", kind: "requirement", status: "open", machine: "droplet", at: 1, note: null, by: null, resolvedAt: null }],
  }, { MERGE_GRACE_MS: "60000" });
  f.store.savePrivate("MF-1", { worktree: "~/.worktrees/mf-1", repoDir: "~/factory", base: "main", finishing: false, restarts: 0, merging: false, mergeChecked: HEAD } as never);
  const policyChanged = () => (f.engine as unknown as { policyChanged(): Promise<void> }).policyChanged();
  return { ...f, policyChanged };
}

test("auto-merge waits on an open not-run check, saying why, and starts once a person waives it with a note", async () => {
  const f = ready();
  await f.policyChanged();
  assert.equal(f.t().mergeAt ?? null, null, "no countdown while it's open");
  assert.equal(f.t().waiting, "waiting on 1 check not run here: needs macos");

  // An agent can't waive it, and a person can't without a note.
  await assert.rejects(f.engine.command({ type: "task.waiveCheck", id: "MF-1", command: XCODE, note: "CI runs it" } as never, { member: { login: "builder", role: "member" } } as never), /Only a person/);
  await assert.rejects(f.engine.command({ type: "task.waiveCheck", id: "MF-1", command: XCODE, note: "  " } as never, ANDREA), /a note is needed/);
  await assert.rejects(f.engine.command({ type: "task.waiveCheck", id: "MF-1", command: "nope", note: "x" } as never, ANDREA), /isn't waiting/);
  assert.equal(f.t().checksNotRun?.[0]?.status, "open");

  await f.engine.command({ type: "task.waiveCheck", id: "MF-1", command: XCODE, note: "The Mac CI job runs xcodebuild on every PR." } as never, ANDREA);
  const item = f.t().checksNotRun![0]!;
  assert.deepEqual([item.status, item.by, item.note], ["waived", "andrea", "The Mac CI job runs xcodebuild on every PR."]);
  assert.ok(f.t().events.some((e) => e.who === "andrea" && e.text.startsWith("waived the check `xcodebuild test -scheme MapleFactory` (needs macos)")));
  assert.equal(f.t().waiting ?? null, null);
  assert.ok(f.t().mergeAt != null, "the countdown starts once nothing's open");
  await assert.rejects(f.engine.command({ type: "task.waiveCheck", id: "MF-1", command: XCODE, note: "again" } as never, ANDREA), /already waived/);
});

test("a waived check stays waived when the next push skips it again", async () => {
  const f = finishing();
  await f.finish();
  await f.settle();
  await f.finished({});
  await f.engine.command({ type: "task.waiveCheck", id: "MF-1", command: XCODE, note: "CI covers it" } as never, ANDREA);
  // Back to building for a fix, then a second push from the droplet.
  f.store.saveTask({ ...f.t(), state: "building", worker: { role: "builder", agent: "claude", machine: "droplet", session: SESSION, startedAt: 2 } } as never);
  await f.finish();
  await f.settle();
  await f.finished({ notRun: [{ command: XCODE, reason: "needs macos", kind: "requirement" }] });
  assert.deepEqual(f.t().checksNotRun?.map((n) => [n.status, n.note]), [["waived", "CI covers it"]]);
});

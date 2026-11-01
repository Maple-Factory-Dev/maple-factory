// A merge hold on a repo (an incident freeze across every goal): the engine starts no merges into it,
// a person's Merge is refused with the reason, other repos merge as before, and lifting the hold
// starts the waiting tasks' countdowns again. Through the engine on a node:sqlite store.
import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { Engine } from "../src/factory/engine.ts";
import { Store } from "../src/factory/store.ts";

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

const HEAD = "a".repeat(40);
const ME = { member: { login: "oncall", role: "member" } } as never;

/** MF-1 on acme/app and MF-2 on acme/web, both reviewed, proven and green: ready to auto-merge. */
function factory() {
  const store = new Store(sqlStorage());
  const sent: Record<string, unknown>[] = [];
  const broadcasts: Record<string, unknown>[] = [];
  const audits: unknown[][] = [];
  const DB = { prepare: () => ({ bind: (...a: unknown[]) => ({ run: async () => { audits.push(a); } }) }) };
  const hooks = {
    broadcast: (m: Record<string, unknown>) => broadcasts.push(m),
    sendTo: () => {},
    machines: async () => [{ id: "mac", sessions: [] }],
    members: async () => [],
    machineChanged: async () => {},
    waitUntil: () => {},
    wakeIn: () => {},
  };
  const MACHINE = {
    idFromName: (id: string) => id,
    get: () => ({ fetch: async (_: string, init: RequestInit) => (sent.push(JSON.parse(String(init.body))), new Response(null)) }),
  };
  const engine = new Engine({ MACHINE, DB, MERGE_GRACE_MS: "60000" } as never, store, hooks as never, { forTask: () => {} } as never, {} as never);
  store.saveRepos([
    { name: "acme/app", defaultBranch: "main", isPrivate: true, source: "github" },
    { name: "acme/web", defaultBranch: "main", isPrivate: true, source: "github" },
  ]);
  for (const [id, repo] of [["MF-1", "acme/app"], ["MF-2", "acme/web"]]) {
    store.saveTask({
      id, goal: "g", repo, title: "Fix it", state: "reviewing", owner: "me", brief: "", createdAt: 1, updatedAt: 1, plan: [], planVersion: 1,
      doneWhen: [], approvals: [], approvalsNeeded: 1, reviews: [], reviewsNeeded: 0, comments: [], changes: [], events: [], mockups: [], tickets: [],
      shareable: false, agent: "claude", machine: "mac", risk: { level: "low", reasons: [], areas: [], factors: [] },
      autoReview: { rounds: [{ verdict: "passed" }] },
      pr: { number: 7, url: null, state: "open", head: HEAD, branch: `agent/${id.toLowerCase()}`, base: "main", checks: [{ name: "ci", status: "passed" }] },
    } as never);
    store.savePrivate(id, { worktree: `~/.worktrees/${id}`, repoDir: "~/app", base: "main", finishing: false, restarts: 0, merging: false, mergeChecked: HEAD });
  }
  const task = (id: string) => store.task(id)!;
  const merges = () => sent.filter((m) => m.type === "task.merge").map((m) => m.taskId);
  /** Every countdown runs out now. */
  const due = async () => {
    for (const id of ["MF-1", "MF-2"]) if (task(id).mergeAt != null) store.saveTask({ ...task(id), mergeAt: Date.now() - 1 });
    await engine.mergeDue();
  };
  return { store, engine, task, merges, due, broadcasts, audits };
}

test("a hold clears a running countdown, and nothing merges into the repo until it's lifted", async () => {
  const f = factory();
  await (f.engine as unknown as { policyChanged(): Promise<void> }).policyChanged(); // starts both countdowns
  assert.ok(f.task("MF-1").mergeAt != null);
  assert.ok(f.task("MF-2").mergeAt != null);

  await f.engine.command({ type: "repos.holdMerges", repo: "ACME/app", reason: "incident #42: bad deploy" } as never, ME);
  assert.equal(f.task("MF-1").mergeAt, null, "its countdown stopped");
  assert.ok(f.task("MF-2").mergeAt != null, "another repo's keeps going");
  assert.ok(f.task("MF-1").events.some((e) => e.text === "merges into acme/app are on hold: incident #42: bad deploy"));
  assert.deepEqual(f.store.mergeHolds().map((h) => [h.repo, h.reason, h.by]), [["acme/app", "incident #42: bad deploy", "oncall"]]);

  // Audited and broadcast to every app.
  assert.ok(f.audits.some((a) => a[2] === "repo.merges_held"));
  const updated = f.broadcasts.find((m) => m.type === "mergeHolds.updated") as { holds: { repo: string }[] };
  assert.deepEqual(updated.holds.map((h) => h.repo), ["acme/app"]);
  assert.ok(f.broadcasts.some((m) => m.type === "toast" && String(m.text).includes("on hold")));

  // Its countdown doesn't come back, and only the other repo's task merges.
  await f.due();
  await f.due();
  assert.equal(f.task("MF-1").mergeAt, null);
  assert.deepEqual(f.merges(), ["MF-2"]);

  // A person's Merge is refused with the reason.
  await assert.rejects(
    f.engine.command({ type: "task.merge", id: "MF-1" } as never, ME),
    /Merges into acme\/app are on hold: incident #42: bad deploy \(held by oncall\)\./,
  );
  assert.deepEqual(f.merges(), ["MF-2"]);

  // Lifting it starts the waiting task's countdown again, and it merges.
  await f.engine.command({ type: "repos.releaseMerges", repo: "acme/app" } as never, ME);
  assert.deepEqual(f.store.mergeHolds(), []);
  assert.ok(f.audits.some((a) => a[2] === "repo.merges_released"));
  assert.ok(f.task("MF-1").mergeAt != null, "counting down again");
  await f.due();
  assert.deepEqual(f.merges(), ["MF-2", "MF-1"]);
});

test("a person's Merge on another repo still goes through during a hold", async () => {
  const f = factory();
  await f.engine.command({ type: "repos.holdMerges", repo: "acme/app", reason: "freeze" } as never, ME);
  await f.engine.command({ type: "task.merge", id: "MF-2" } as never, ME);
  assert.deepEqual(f.merges(), ["MF-2"]);
});

test("a hold needs one of the factory's repos and a reason", async () => {
  const f = factory();
  await assert.rejects(f.engine.command({ type: "repos.holdMerges", repo: "acme/nope", reason: "x" } as never, ME), /isn't one of the factory's repos/);
  await assert.rejects(f.engine.command({ type: "repos.holdMerges", repo: "not a repo", reason: "x" } as never, ME), /isn't one of the factory's repos/);
  await assert.rejects(f.engine.command({ type: "repos.holdMerges", repo: "acme/app", reason: "   " } as never, ME), /Say why/);
  await assert.rejects(f.engine.command({ type: "repos.holdMerges", repo: "acme/app", reason: "x".repeat(201) } as never, ME), /200 characters/);
  await assert.rejects(f.engine.command({ type: "repos.releaseMerges", repo: "acme/app" } as never, ME), /aren't on hold/);
  assert.deepEqual(f.store.mergeHolds(), []);

  // Holding again replaces the reason rather than adding a second hold.
  await f.engine.command({ type: "repos.holdMerges", repo: "acme/app", reason: "one" } as never, ME);
  await f.engine.command({ type: "repos.holdMerges", repo: "Acme/App", reason: "two" } as never, ME);
  assert.deepEqual(f.store.mergeHolds().map((h) => h.reason), ["two"]);
});

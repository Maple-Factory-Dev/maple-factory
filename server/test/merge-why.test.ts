// Why a merge wasn't the factory's own, through the engine on a node:sqlite store (the harness factory.test.ts
// uses): task.merged records `why` and `level` on the merged stats row, and a person's review request is a row too.
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
const BRANCH = "agent/mf-1";

/** The engine with MF-1 reviewing on `mac`, merged by the factory; what it sends the runner is in `sent`. */
function factory(env: Record<string, unknown> = {}, priv: Record<string, unknown> = {}, task: Record<string, unknown> = {}) {
  const store = new Store(sqlStorage());
  const sent: Record<string, unknown>[] = [];
  const pending: Promise<unknown>[] = [];
  const wakes: number[] = [];
  const hooks = {
    broadcast: () => {},
    sendTo: () => {},
    machines: async () => [{ id: "mac", sessions: [] }],
    members: async () => [],
    machineChanged: async () => {},
    waitUntil: (p: Promise<unknown>) => pending.push(p),
    wakeIn: (ms: number) => wakes.push(ms),
  };
  const MACHINE = {
    idFromName: (id: string) => id,
    get: () => ({ fetch: async (_: string, init: RequestInit) => (sent.push(JSON.parse(String(init.body))), new Response(null)) }),
  };
  const engine = new Engine({ MACHINE, ...env } as never, store, hooks as never, { forTask: () => {} } as never, {} as never);
  store.saveTask({
    id: "MF-1", goal: "g", title: "Fix it", state: "reviewing", owner: "me", brief: "", createdAt: 1, updatedAt: 1, plan: [], planVersion: 1, doneWhen: [],
    approvals: [], approvalsNeeded: 1, reviews: [], reviewsNeeded: 1, comments: [], changes: [], events: [], mockups: [], tickets: [],
    shareable: false, agent: "claude", machine: "mac",
    pr: { number: 7, url: env.GITHUB_APP_ID ? "https://github.com/acme/app/pull/7" : null, state: "open", head: HEAD, branch: BRANCH, base: "main", checks: [] },
    ...task,
  } as never);
  store.savePrivate("MF-1", { worktree: "~/.worktrees/app/mf-1", repoDir: "~/app", base: "main", finishing: false, restarts: 0, mergeBy: "factory", merging: true, ...priv });
  const merged = async (branch?: string) => {
    await engine.fromRunner("mac", { type: "task.merged", taskId: "MF-1", ok: true, commit: "b".repeat(40), message: null, ...(branch ? { branch } : {}) });
    while (pending.length) await pending.shift();
  };
  const events = () => store.task("MF-1")!.events.map((e) => e.text);
  const settle = async () => { while (pending.length) await pending.shift(); };
  return { store, sent, merged, events, engine, wakes, pending, settle };
}

const mergedRow = (store: Store) => store.statEvents().find((e) => e.kind === "merged")!;

test("a medium-risk task a person merges reads risk/medium", async () => {
  const { store, merged } = factory({}, { mergeBy: "ann" }, { risk: { level: "medium", reasons: [], areas: [] } });
  await merged();
  const row = mergedRow(store);
  assert.equal(row.actor, "ann");
  assert.equal(row.detail.auto, false);
  assert.equal(row.detail.why, "risk");
  assert.equal(row.detail.level, "medium");
});

test("a held low-risk task reads held, with who held it", async () => {
  const { store, merged } = factory({}, { mergeBy: "ann", mergeHeld: HEAD }, {
    risk: { level: "low", reasons: [], areas: [] },
    events: [{ at: 2, who: "bob", text: "held the auto-merge; a person merges it" }],
  });
  await merged();
  const row = mergedRow(store);
  assert.equal(row.detail.why, "held");
  assert.equal(row.detail.heldBy, "bob");
});

test("the factory's own merge has no why; a low-risk one merged on GitHub reads github", async () => {
  const own = factory({}, {}, { risk: { level: "low", reasons: [], areas: [] } });
  await own.merged();
  assert.equal(mergedRow(own.store).detail.auto, true);
  assert.equal(mergedRow(own.store).detail.why, undefined);
  const gh = factory({}, { mergeBy: null }, { risk: { level: "low", reasons: [], areas: [] } });
  await gh.merged();
  assert.equal(mergedRow(gh.store).detail.why, "github");
});

test("with auto-merge off org-wide, a person's merge reads autoMergeOff", async () => {
  const { store, merged } = factory({}, { mergeBy: "ann" }, { risk: { level: "low", reasons: [], areas: [] } });
  store.savePolicy({ ...store.policy(), autoMerges: false });
  await merged();
  assert.equal(mergedRow(store).detail.why, "autoMergeOff");
});

// A merged task's branch on origin, through the engine on a node:sqlite store (as queue.test.ts does):
// the runner's note on task.merged lands on the task's timeline, and a delete that failed gets one more
// try at cleanup, through the GitHub App (a stubbed GitHub) or by the runner (task.cleanup's deleteRemote).
import { test } from "node:test";
import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
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
function factory(env: Record<string, unknown> = {}, priv: Record<string, unknown> = {}) {
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
  const engine = new Engine({ MACHINE, ...env } as never, store, hooks as never, { forTask: () => {} } as never, {} as never);
  store.saveTask({
    id: "MF-1", goal: "g", title: "Fix it", state: "reviewing", owner: "me", brief: "", createdAt: 1, updatedAt: 1, plan: [], planVersion: 1, doneWhen: [],
    approvals: [], approvalsNeeded: 1, reviews: [], reviewsNeeded: 1, comments: [], changes: [], events: [], mockups: [], tickets: [],
    shareable: false, agent: "claude", machine: "mac",
    pr: { number: 7, url: env.GITHUB_APP_ID ? "https://github.com/acme/app/pull/7" : null, state: "open", head: HEAD, branch: BRANCH, base: "main", checks: [] },
  } as never);
  store.savePrivate("MF-1", { worktree: "~/.worktrees/app/mf-1", repoDir: "~/app", base: "main", finishing: false, restarts: 0, mergeBy: "factory", merging: true, ...priv });
  const merged = async (branch?: string) => {
    await engine.fromRunner("mac", { type: "task.merged", taskId: "MF-1", ok: true, commit: "b".repeat(40), message: null, ...(branch ? { branch } : {}) });
    while (pending.length) await pending.shift();
  };
  const events = () => store.task("MF-1")!.events.map((e) => e.text);
  return { store, sent, merged, events };
}

test("the runner's branch note is on the merged task's timeline, and a settled one isn't tried again", async () => {
  for (const [note, line, settled] of [
    ["deleted", `deleted branch ${BRANCH} on origin`, "deleted"],
    ["gone", `branch ${BRANCH} was already gone on origin`, "deleted"],
    ["moved", `kept branch ${BRANCH} on origin (it moved after the merge)`, "kept"],
  ]) {
    const { store, sent, merged, events } = factory();
    await merged(note);
    assert.equal(store.task("MF-1")!.state, "merged");
    assert.deepEqual(events(), ["merged into main (bbbbbbb)", line]);
    assert.equal(store.private("MF-1").remoteBranch, settled);
    assert.equal(sent.length, 1);
    assert.equal(sent[0].type, "task.cleanup");
    assert.equal(sent[0].deleteRemote, false, note);
  }
});

test("runner path: a failed delete, or no word of one, asks the runner's cleanup to delete it on origin", async () => {
  const { store, sent, merged, events } = factory();
  await merged("failed: Could not read from remote repository.");
  assert.deepEqual(events(), ["merged into main (bbbbbbb)", `couldn't delete branch ${BRANCH} on origin: Could not read from remote repository.`]);
  assert.equal(store.private("MF-1").remoteBranch, "failed");
  assert.equal(sent.length, 1);
  assert.equal(sent[0].type, "task.cleanup");
  assert.equal(sent[0].deleteRemote, true);
  assert.equal(sent[0].merged, true);
  assert.deepEqual(sent[0].heads, [HEAD, "b".repeat(40)]);

  // An older runner says nothing about the branch.
  const older = factory();
  await older.merged();
  assert.deepEqual(older.events(), ["merged into main (bbbbbbb)"]);
  assert.equal(older.sent[0].deleteRemote, true);

  // Merged by a person on GitHub, not by the factory: its branch is theirs.
  const theirs = factory({}, { mergeBy: null });
  await theirs.merged();
  assert.equal(theirs.sent[0].deleteRemote, false);
});

test("app path: a failed delete on GitHub gets one more try before the cleanup", async () => {
  const { privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
  const env = { GITHUB_APP_ID: "1", GITHUB_APP_PRIVATE_KEY: privateKey.export({ type: "pkcs8", format: "pem" }), GITHUB_API_URL: "http://localhost:1" };
  const calls: string[] = [];
  let failing = true;
  const realFetch = globalThis.fetch;
  globalThis.fetch = (async (url: string, init: RequestInit = {}) => {
    const path = new URL(url).pathname;
    const method = init.method ?? "GET";
    calls.push(`${method} ${path}`);
    if (path === "/repos/acme/app/installation") return Response.json({ id: 9 });
    if (path === "/app/installations/9/access_tokens") return Response.json({ token: "t", expires_at: "" });
    if (path === `/repos/acme/app/git/ref/heads/${BRANCH}`) {
      return failing ? Response.json({ message: "Server Error" }, { status: 502 }) : Response.json({ object: { sha: HEAD } });
    }
    if (method === "DELETE" && path === `/repos/acme/app/git/refs/heads/${BRANCH}`) return new Response(null, { status: 204 });
    return Response.json({ message: "Not Found" }, { status: 404 });
  }) as typeof fetch;
  try {
    // The merge's own delete failed: GitHub was down.
    const { store, sent, merged, events } = factory(env, { gh: { owner: "acme", repo: "app" }, remoteBranch: "failed" });
    failing = false;
    await merged();
    assert.equal(store.private("MF-1").remoteBranch, "deleted");
    assert.deepEqual(events(), ["merged into main (bbbbbbb)", `deleted branch ${BRANCH} on GitHub`]);
    assert.equal(calls.filter((c) => c.startsWith("DELETE")).length, 1);
    // Then the cleanup, with nothing left for the runner to do on origin.
    assert.equal(sent.length, 1);
    assert.equal(sent[0].deleteRemote, false);

    // One try only: when it fails again, it's said and left.
    calls.length = 0;
    failing = true;
    const again = factory(env, { gh: { owner: "acme", repo: "app" }, remoteBranch: "failed" });
    await again.merged();
    assert.equal(again.store.private("MF-1").remoteBranch, "failed");
    assert.equal(calls.filter((c) => c.endsWith(`/git/ref/heads/${BRANCH}`)).length, 1);
    assert.match(again.events()[1], new RegExp(`^couldn't delete branch ${BRANCH} on GitHub: `));
    assert.equal(again.sent.length, 1);
  } finally {
    globalThis.fetch = realFetch;
  }
});

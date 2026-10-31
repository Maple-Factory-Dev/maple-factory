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

// A merge that never answers (GitHub's call cut off, a runner gone quiet) is found by the hub's alarm
// (mergeDue): it lands when GitHub says the pull request merged, and otherwise goes to a person.

const DB = { prepare: () => ({ bind: () => ({ run: async () => {} }) }) };
const READY = { autoReview: { rounds: [{ verdict: "passed" }], maxRounds: 3 }, reviews: ["me"], liveLog: null };
const ME = { member: { login: "me", role: "member" } } as never;

/** A stubbed GitHub whose merge call never answers; `pr` is what reading the pull request says. */
function stuckGitHub(pr: () => Record<string, unknown> | null) {
  const { privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
  const env = { DB, GITHUB_APP_ID: "1", GITHUB_APP_PRIVATE_KEY: privateKey.export({ type: "pkcs8", format: "pem" }), GITHUB_API_URL: "http://localhost:1" };
  const calls: string[] = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = (async (url: string, init: RequestInit = {}) => {
    const path = new URL(url).pathname;
    const method = init.method ?? "GET";
    calls.push(`${method} ${path}`);
    if (path === "/repos/acme/app/installation") return Response.json({ id: 9 });
    if (path === "/app/installations/9/access_tokens") return Response.json({ token: "t", expires_at: "" });
    if (method === "PUT" && path === "/repos/acme/app/pulls/7/merge") return new Promise<Response>(() => {});
    if (method === "GET" && path === "/repos/acme/app/pulls/7") {
      const j = pr();
      return j ? Response.json(j) : Response.json({ message: "Server Error" }, { status: 502 });
    }
    if (path === `/repos/acme/app/git/ref/heads/${BRANCH}`) return Response.json({ object: { sha: HEAD } });
    if (method === "DELETE" && path === `/repos/acme/app/git/refs/heads/${BRANCH}`) return new Response(null, { status: 204 });
    return Response.json({ message: "Not Found" }, { status: 404 });
  }) as typeof fetch;
  return { env, calls, restore: () => { globalThis.fetch = realFetch; } };
}

/** Moves the clock on by `ms` for the rest of a test. */
function later(ms: number) {
  const real = Date.now;
  const at = real() + ms;
  Date.now = () => at;
  return () => { Date.now = real; };
}

test("a GitHub merge that never answers lands on the next alarm once GitHub says it merged", async () => {
  const gh = stuckGitHub(() => ({ state: "closed", merged: true, merge_commit_sha: "c".repeat(40) }));
  try {
    const f = factory(gh.env, { gh: { owner: "acme", repo: "app" }, merging: false, mergeBy: null }, READY);
    await f.engine.command({ type: "task.merge", id: "MF-1" }, ME);
    assert.equal(f.store.private("MF-1").merging, true);
    assert.equal(f.store.task("MF-1")!.liveLog, "Merging…");
    assert.equal(typeof f.store.private("MF-1").mergeStartedAt, "number");
    assert.ok(f.wakes.includes(3 * 60_000), "the hub wakes to check on it");
    f.pending.length = 0; // the merge call that never answers
    // Wait for that call to reach GitHub (after its token and the merge-queue rules): one still on its way
    // when this test ends would land in the next test's stubbed GitHub.
    for (const until = Date.now() + 5_000; !gh.calls.includes("PUT /repos/acme/app/pulls/7/merge") && Date.now() < until; ) await new Promise((r) => setTimeout(r, 5));

    // Not quiet long enough: nothing changes, and the hub wakes again for it.
    await f.engine.mergeDue();
    assert.equal(f.store.private("MF-1").merging, true);
    assert.ok(!gh.calls.includes("GET /repos/acme/app/pulls/7"));

    const back = later(3 * 60_000 + 1);
    try {
      await f.engine.mergeDue();
      await f.settle();
    } finally {
      back();
    }
    const task = f.store.task("MF-1")!;
    assert.equal(task.state, "merged");
    assert.equal(task.pr!.state, "merged");
    assert.equal(task.liveLog, null);
    assert.equal(task.hand ?? null, null);
    assert.equal(f.store.private("MF-1").mergedAs, "c".repeat(40));
    assert.ok(f.events().includes("didn't hear back from the merge; GitHub says it merged"));
    assert.ok(f.events().includes("merged into main (ccccccc)"));
  } finally {
    gh.restore();
  }
});

test("a GitHub merge that never answers with its pull request still open stops Merging… and asks a person; Try the merge again merges afresh", async () => {
  const gh = stuckGitHub(() => ({ state: "open", merged: false }));
  try {
    const f = factory(gh.env, { gh: { owner: "acme", repo: "app" }, merging: false, mergeBy: null }, READY);
    await f.engine.command({ type: "task.merge", id: "MF-1" }, ME);
    f.pending.length = 0;
    const back = later(4 * 60_000);
    try {
      await f.engine.mergeDue();
    } finally {
      back();
    }
    let task = f.store.task("MF-1")!;
    assert.equal(task.state, "reviewing");
    assert.equal(f.store.private("MF-1").merging, false);
    assert.equal(task.liveLog, null);
    assert.equal(task.hand?.reason, "mergeFailed");
    assert.match(task.hand!.summary, /didn't answer after 4 min; its pull request is still open on GitHub/);
    assert.deepEqual(task.hand!.options.map((o) => [o.title, o.recommended]), [["Try the merge again", true], ["Send it back to fix", false], ["Cancel it", false]]);
    assert.ok(f.events().includes("didn't hear back from the merge after 4 min"));
    // Not a merge-fix try, and not sent back to its builder.
    assert.equal(f.store.private("MF-1").mergeFixes ?? 0, 0);

    // Each merge call comes after its token is made, so it can land any time after the command: wait for
    // the count to reach what's expected rather than a fixed time, which a busy test run can outlast.
    const merges = () => gh.calls.filter((c) => c === "PUT /repos/acme/app/pulls/7/merge").length;
    const mergesReach = async (n: number) => {
      for (const until = Date.now() + 5_000; merges() < n && Date.now() < until; ) await new Promise((r) => setTimeout(r, 5));
    };
    // The first merge's call, which never answers.
    await mergesReach(1);
    assert.equal(merges(), 1);

    // Try the merge again: a fresh merge, with a fresh start time.
    await f.engine.command({ type: "task.resolveHand", id: "MF-1", option: "Try the merge again", note: "" } as never, ME);
    task = f.store.task("MF-1")!;
    assert.equal(task.hand ?? null, null);
    assert.equal(task.liveLog, "Merging…");
    assert.equal(f.store.private("MF-1").merging, true);
    await mergesReach(2);
    assert.equal(merges(), 2);
  } finally {
    gh.restore();
  }
});

test("GitHub unreadable, or a pull request closed meanwhile, ends the wait too", async () => {
  let pr: Record<string, unknown> | null = null;
  const gh = stuckGitHub(() => pr);
  try {
    const started = Date.now() - 5 * 60_000;
    const f = factory(gh.env, { gh: { owner: "acme", repo: "app" }, mergeStartedAt: started }, { liveLog: "Merging…" });
    await f.engine.mergeDue();
    assert.equal(f.store.task("MF-1")!.hand?.reason, "mergeFailed");
    assert.match(f.store.task("MF-1")!.hand!.summary, /GitHub couldn't be asked whether it merged/);

    pr = { state: "closed", merged: false };
    const g = factory(gh.env, { gh: { owner: "acme", repo: "app" }, mergeStartedAt: started }, { liveLog: "Merging…" });
    await g.engine.mergeDue();
    const task = g.store.task("MF-1")!;
    assert.equal(task.pr!.state, "closed");
    assert.equal(task.liveLog, null);
    assert.equal(task.hand ?? null, null);
    assert.equal(g.store.private("MF-1").merging, false);
    assert.ok(g.events().includes("pull request #7 was closed on GitHub"));
  } finally {
    gh.restore();
  }
});

test("a runner merge that never answers raises a hand after its longer wait", async () => {
  const f = factory({ DB }, { merging: false, mergeBy: null }, READY);
  await f.engine.command({ type: "task.merge", id: "MF-1" }, ME);
  assert.equal(f.sent.at(-1)!.type, "task.merge");
  assert.ok(f.wakes.includes(10 * 60_000));
  let back = later(5 * 60_000);
  try {
    await f.engine.mergeDue(); // a runner's merge may run hooks: 5 min isn't stuck yet
  } finally {
    back();
  }
  assert.equal(f.store.private("MF-1").merging, true);
  assert.equal(f.store.task("MF-1")!.hand ?? null, null);
  back = later(11 * 60_000);
  try {
    await f.engine.mergeDue();
  } finally {
    back();
  }
  const task = f.store.task("MF-1")!;
  assert.equal(f.store.private("MF-1").merging, false);
  assert.equal(task.liveLog, null);
  assert.equal(task.hand?.reason, "mergeFailed");
  assert.match(task.hand!.summary, /it may or may not have merged on its machine/);
  assert.equal(task.hand!.options[0].title, "Try the merge again");
});

test("a merge stuck from before start times were kept is swept on the first alarm", async () => {
  // As MF-89 was: merging, no start time, "Merging…" for hours.
  const f = factory({ DB }, {}, { liveLog: "Merging…" });
  assert.equal(f.store.private("MF-1").mergeStartedAt, undefined);
  await f.engine.mergeDue();
  const task = f.store.task("MF-1")!;
  assert.equal(f.store.private("MF-1").merging, false);
  assert.equal(task.liveLog, null);
  assert.equal(task.hand?.reason, "mergeFailed");
  assert.ok(f.events().includes("didn't hear back from the merge"));
});

test("a Merging… label with no merge or countdown behind it is cleared", async () => {
  const f = factory({ DB }, { merging: false }, { liveLog: "Merging…" });
  await f.engine.mergeDue();
  assert.equal(f.store.task("MF-1")!.liveLog, null);
  assert.equal(f.store.task("MF-1")!.hand ?? null, null);

  // And on any save, without waiting for the alarm.
  const g = factory({ DB }, { merging: false }, { liveLog: "Merging…" });
  await g.engine.command({ type: "task.comment", id: "MF-1", text: "still merging?" } as never, ME);
  assert.equal(g.store.task("MF-1")!.liveLog, null);

  // One still counting down (its due "Merging…" while the dry run checks) keeps it.
  const h = factory({ DB }, { merging: false }, { liveLog: "Merging…", mergeAt: Date.now() - 1 });
  h.store.saveTask({ ...h.store.task("MF-1")!, liveLog: "Merging…" });
  assert.equal(h.store.task("MF-1")!.liveLog, "Merging…");
});

test("a late answer that it merged wins over the watchdog's hand; a late failure doesn't undo it", async () => {
  const f = factory({ DB }, {}, { liveLog: "Merging…" });
  await f.engine.mergeDue();
  assert.equal(f.store.task("MF-1")!.hand?.reason, "mergeFailed");

  // A late failure for that merge changes nothing: the hand is already up.
  await f.engine.fromRunner("mac", { type: "task.merged", taskId: "MF-1", ok: false, commit: null, message: "timed out" } as never);
  assert.equal(f.store.task("MF-1")!.state, "reviewing");
  assert.equal(f.store.private("MF-1").mergeFixes ?? 0, 0);

  await f.merged();
  const task = f.store.task("MF-1")!;
  assert.equal(task.state, "merged");
  assert.equal(task.hand ?? null, null);

  // A duplicate answer after it's merged stays a no-op.
  const n = task.events.length;
  await f.merged();
  assert.equal(f.store.task("MF-1")!.events.length, n);
});

// GitHub's merge queue: a base branch that requires one gets the pull request added to the queue
// (GraphQL enqueuePullRequest, pinned to the reviewed head) instead of a squash-merge, and the task waits
// "In merge queue…" for the pull_request webhook, or the longer queue timeout's look-up.

/** A stubbed GitHub whose main requires a merge queue (`rules`), or refuses a direct merge for one (`refuse`). */
function queuedGitHub(pr: () => Record<string, unknown>, { rules = true, refuse = true } = {}) {
  const { privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
  const env = { DB, GITHUB_APP_ID: "1", GITHUB_APP_PRIVATE_KEY: privateKey.export({ type: "pkcs8", format: "pem" }), GITHUB_API_URL: "http://localhost:1" };
  const calls: string[] = [];
  const graphql: Record<string, unknown>[] = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = (async (url: string, init: RequestInit = {}) => {
    const path = new URL(url).pathname;
    const method = init.method ?? "GET";
    calls.push(`${method} ${path}`);
    if (path === "/repos/acme/app/installation") return Response.json({ id: 9 });
    if (path === "/app/installations/9/access_tokens") return Response.json({ token: "t", expires_at: "" });
    if (path === "/repos/acme/app/rules/branches/main") return rules ? Response.json([{ type: "pull_request" }, { type: "merge_queue", parameters: {} }]) : Response.json({ message: "Not Found" }, { status: 404 });
    if (method === "PUT" && path === "/repos/acme/app/pulls/7/merge") {
      return refuse ? Response.json({ message: "Repository rule violations found\n\nChanges must be made through the merge queue" }, { status: 405 }) : Response.json({ merged: true, sha: "d".repeat(40) });
    }
    if (method === "POST" && path === "/graphql") {
      const body = JSON.parse(String(init.body));
      graphql.push(body);
      if (/enqueuePullRequest/.test(body.query)) return Response.json({ data: { enqueuePullRequest: { mergeQueueEntry: { position: 2, state: "QUEUED" } } } });
      return Response.json({ data: { repository: { pullRequest: { id: "PR_7" } } } });
    }
    if (method === "GET" && path === "/repos/acme/app/pulls/7") return Response.json(pr());
    if (path === `/repos/acme/app/git/ref/heads/${BRANCH}`) return Response.json({ object: { sha: HEAD } });
    if (method === "DELETE" && path === `/repos/acme/app/git/refs/heads/${BRANCH}`) return new Response(null, { status: 204 });
    return Response.json({ message: "Not Found" }, { status: 404 });
  }) as typeof fetch;
  return { env, calls, graphql, restore: () => { globalThis.fetch = realFetch; } };
}

test("a base branch that requires a merge queue gets the pull request enqueued at its head, not merged; it waits In merge queue… until GitHub merges it", async () => {
  const gh = queuedGitHub(() => ({ state: "open", merged: false }));
  try {
    const f = factory(gh.env, { gh: { owner: "acme", repo: "app" }, merging: false, mergeBy: null }, READY);
    await f.engine.command({ type: "task.merge", id: "MF-1" }, ME);
    await f.settle();
    assert.ok(gh.calls.includes("GET /repos/acme/app/rules/branches/main"));
    assert.ok(!gh.calls.includes("PUT /repos/acme/app/pulls/7/merge"), "no squash-merge");
    const enqueue = gh.graphql.find((g) => /enqueuePullRequest/.test(String(g.query)))!;
    assert.deepEqual(enqueue.variables, { id: "PR_7", head: HEAD });
    let task = f.store.task("MF-1")!;
    assert.equal(task.state, "reviewing");
    assert.equal(task.liveLog, "In merge queue…");
    assert.equal(f.store.private("MF-1").merging, true);
    assert.equal(f.store.private("MF-1").queued, true);
    assert.ok(f.events().includes("added pull request #7 to GitHub's merge queue (position 2)"));
    assert.ok(f.wakes.includes(60 * 60_000), "the hub wakes after the queue's longer timeout");

    // A Merge click while it's queued changes nothing; nor does a save.
    await f.engine.command({ type: "task.merge", id: "MF-1" }, ME);
    await f.engine.command({ type: "task.comment", id: "MF-1", text: "queued?" } as never, ME);
    assert.equal(gh.graphql.filter((g) => /enqueuePullRequest/.test(String(g.query))).length, 1);
    assert.equal(f.store.task("MF-1")!.liveLog, "In merge queue…");

    // A merge call's timeout isn't the queue's: 4 min in, it's still waiting and GitHub isn't asked.
    const back = later(4 * 60_000);
    try {
      await f.engine.mergeDue();
    } finally {
      back();
    }
    assert.equal(f.store.private("MF-1").merging, true);
    assert.ok(!gh.calls.includes("GET /repos/acme/app/pulls/7"));

    // The enqueued webhook for its own enqueue adds nothing; the closed one lands it.
    await f.engine.fromGitHub({ owner: "acme", repo: "app", number: 7, enqueued: true });
    await f.engine.fromGitHub({ owner: "acme", repo: "app", number: 7, closed: true, merged: true });
    await f.settle();
    task = f.store.task("MF-1")!;
    assert.equal(task.state, "merged");
    assert.equal(task.liveLog, null);
    assert.equal(f.store.private("MF-1").queued, false);
    assert.ok(!f.events().some((e) => e === "pull request #7 was added to GitHub's merge queue"));
    assert.ok(f.events().includes("merged into main"));
  } finally {
    gh.restore();
  }
});

test("a queued merge with no answer is looked up after the queue timeout: merged lands it, still open asks a person", async () => {
  let pr: Record<string, unknown> = { state: "open", merged: false };
  const gh = queuedGitHub(() => pr);
  try {
    const f = factory(gh.env, { gh: { owner: "acme", repo: "app" }, merging: false, mergeBy: null }, READY);
    await f.engine.command({ type: "task.merge", id: "MF-1" }, ME);
    await f.settle();
    assert.equal(f.store.private("MF-1").queued, true);
    let back = later(61 * 60_000);
    try {
      await f.engine.mergeDue();
    } finally {
      back();
    }
    assert.ok(gh.calls.includes("GET /repos/acme/app/pulls/7"));
    let task = f.store.task("MF-1")!;
    assert.equal(task.state, "reviewing");
    assert.equal(task.liveLog, null);
    assert.equal(f.store.private("MF-1").merging, false);
    assert.equal(f.store.private("MF-1").queued, false);
    assert.equal(task.hand?.reason, "mergeFailed");
    assert.equal(task.hand!.summary, "It's been in GitHub's merge queue for 61 min and hasn't merged; its pull request is still open.");
    assert.deepEqual(task.hand!.options.map((o) => [o.title, o.recommended]), [["Try the merge again", true], ["Send it back to fix", false], ["Cancel it", false]]);
    assert.ok(f.events().includes("has been in GitHub's merge queue for 61 min without merging"));

    // Try the merge again queues it afresh; this time GitHub says it merged when looked up.
    await f.engine.command({ type: "task.resolveHand", id: "MF-1", option: "Try the merge again", note: "" } as never, ME);
    await f.settle();
    assert.equal(f.store.task("MF-1")!.liveLog, "In merge queue…");
    assert.equal(gh.graphql.filter((g) => /enqueuePullRequest/.test(String(g.query))).length, 2);
    pr = { state: "closed", merged: true, merge_commit_sha: "e".repeat(40) };
    back = later(62 * 60_000);
    try {
      await f.engine.mergeDue();
      await f.settle();
    } finally {
      back();
    }
    task = f.store.task("MF-1")!;
    assert.equal(task.state, "merged");
    assert.equal(task.hand ?? null, null);
    assert.ok(f.events().includes("merged into main (eeeeeee)"));
  } finally {
    gh.restore();
  }
});

test("GitHub taking a queued pull request out of the queue raises the didn't-merge hand with its reason; leaving because it merged doesn't", async () => {
  const gh = queuedGitHub(() => ({ state: "open", merged: false }));
  try {
    const f = factory(gh.env, { gh: { owner: "acme", repo: "app" }, merging: false, mergeBy: null }, READY);
    await f.engine.command({ type: "task.merge", id: "MF-1" }, ME);
    await f.settle();
    await f.engine.fromGitHub({ owner: "acme", repo: "app", number: 7, dequeued: true, reason: "MERGE" });
    assert.equal(f.store.task("MF-1")!.liveLog, "In merge queue…");
    assert.equal(f.store.task("MF-1")!.hand ?? null, null);

    await f.engine.fromGitHub({ owner: "acme", repo: "app", number: 7, dequeued: true, reason: "CI_FAILURE" });
    const task = f.store.task("MF-1")!;
    assert.equal(task.state, "reviewing");
    assert.equal(task.liveLog, null);
    assert.equal(f.store.private("MF-1").merging, false);
    assert.equal(f.store.private("MF-1").queued, false);
    assert.equal(task.hand?.reason, "mergeFailed");
    assert.equal(task.hand!.summary, "GitHub took it out of the merge queue: the checks on its merge group failed.");
    assert.deepEqual(task.hand!.options.map((o) => [o.title, o.recommended]), [["Send it back to fix", true], ["Try the merge again", false], ["Cancel it", false]]);
    assert.ok(f.events().includes("GitHub took pull request #7 out of the merge queue: the checks on its merge group failed"));
    // Not a merge-fix try, and not sent back to a builder on its own.
    assert.equal(f.store.private("MF-1").mergeFixes ?? 0, 0);
    assert.equal(task.worker ?? null, null);
  } finally {
    gh.restore();
  }
});

test("a direct merge GitHub refuses for its merge queue (rules unreadable) is enqueued instead; a repo without one squash-merges", async () => {
  const gh = queuedGitHub(() => ({ state: "open", merged: false }), { rules: false });
  try {
    const f = factory(gh.env, { gh: { owner: "acme", repo: "app" }, merging: false, mergeBy: null }, READY);
    await f.engine.command({ type: "task.merge", id: "MF-1" }, ME);
    await f.settle();
    // Refused once, with no retries: the queue's refusal won't change.
    assert.equal(gh.calls.filter((c) => c === "PUT /repos/acme/app/pulls/7/merge").length, 1);
    assert.equal(f.store.task("MF-1")!.liveLog, "In merge queue…");
    assert.equal(f.store.private("MF-1").queued, true);
  } finally {
    gh.restore();
  }
  const plain = queuedGitHub(() => ({ state: "open", merged: false }), { rules: false, refuse: false });
  try {
    const f = factory(plain.env, { gh: { owner: "acme", repo: "app" }, merging: false, mergeBy: null }, READY);
    await f.engine.command({ type: "task.merge", id: "MF-1" }, ME);
    await f.settle();
    assert.equal(f.store.task("MF-1")!.state, "merged");
    assert.equal(plain.graphql.length, 0);
    assert.ok(f.events().includes("merged into main (ddddddd)"));
    assert.ok(!f.events().some((e) => /merge queue/.test(e)));
  } finally {
    plain.restore();
  }
});

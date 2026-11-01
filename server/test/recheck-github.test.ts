// Recheck on GitHub (task.recheckGitHub): for a webhook that never came, the engine reads the pull
// request again (a merge, a close, a new head) and then its CI. Through the engine on a node:sqlite
// store with a stubbed GitHub, as factory.test.ts does.
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

const OLD = "a".repeat(40);
const NEW = "d".repeat(40);
const ME = { member: { login: "me", role: "member" } } as never;
const DB = { prepare: () => ({ bind: () => ({ run: async () => {} }) }) };
const { privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
const APP_ENV = { DB, GITHUB_APP_ID: "1", GITHUB_APP_PRIVATE_KEY: privateKey.export({ type: "pkcs8", format: "pem" }), GITHUB_API_URL: "http://localhost:1" };

/** A stubbed GitHub: `pr` is what reading pull request #7 says, `runs` the check runs per commit. */
async function withGitHub(pr: Record<string, unknown>, runs: Record<string, unknown[]>, body: (calls: string[]) => Promise<void>) {
  const calls: string[] = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = (async (url: string, init: RequestInit = {}) => {
    const path = new URL(url).pathname;
    calls.push(`${init.method ?? "GET"} ${path}`);
    if (path === "/repos/acme/app/installation") return Response.json({ id: 9 });
    if (path === "/app/installations/9/access_tokens") return Response.json({ token: "t", expires_at: "" });
    if (path === "/repos/acme/app/pulls/7") return Response.json(pr);
    const m = /^\/repos\/acme\/app\/commits\/(\w+)\/(check-runs|status)$/.exec(path);
    if (m) return m[2] === "status" ? Response.json({ statuses: [] }) : Response.json({ check_runs: runs[m[1]] ?? [] });
    return Response.json({ message: "Not Found" }, { status: 404 });
  }) as typeof fetch;
  try {
    await body(calls);
  } finally {
    globalThis.fetch = realFetch;
  }
}

function factory(env: Record<string, unknown> = APP_ENV, pr: Record<string, unknown> | null = {}) {
  const store = new Store(sqlStorage());
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
  const MACHINE = { idFromName: (id: string) => id, get: () => ({ fetch: async () => new Response(null) }) };
  const engine = new Engine({ MACHINE, ...env } as never, store, hooks as never, { forTask: () => {} } as never, {} as never);
  store.saveTask({
    id: "MF-1", goal: "g", title: "Fix it", state: "reviewing", owner: "me", brief: "", createdAt: 1, updatedAt: 1, plan: [], planVersion: 1, doneWhen: [],
    approvals: [], approvalsNeeded: 1, reviews: [], reviewsNeeded: 1, comments: [], changes: [], events: [], mockups: [], tickets: [],
    shareable: false, agent: "claude", machine: "mac",
    pr: pr && { number: 7, url: "https://github.com/acme/app/pull/7", state: "open", head: OLD, branch: "agent/mf-1", base: "main", checks: [], ...pr },
  } as never);
  store.savePrivate("MF-1", { worktree: "~/w", repoDir: "~/app", base: "main", finishing: false, restarts: 0, gh: { owner: "acme", repo: "app" } });
  const recheck = () => engine.command({ type: "task.recheckGitHub", id: "MF-1" } as never, ME);
  const events = () => store.task("MF-1")!.events.map((e) => e.text);
  const settle = async () => { while (pending.length) await pending.shift(); };
  return { store, engine, recheck, events, wakes, settle };
}

const run = (name: string, status: string, conclusion: string | null = null) => ({ name, status, conclusion, started_at: null, completed_at: null, html_url: `https://github.com/acme/app/runs/${name}` });

test("a stale head is updated and the new head's checks are read", async () => {
  await withGitHub({ state: "open", merged: false, head: { sha: NEW } }, { [NEW]: [run("test", "in_progress")] }, async (calls) => {
    const f = factory();
    await f.recheck();
    const pr = f.store.task("MF-1")!.pr!;
    assert.equal(pr.head, NEW);
    assert.deepEqual(pr.checks.map((c) => `${c.name}:${c.status}`), ["test:running"]);
    assert.ok(calls.includes(`GET /repos/acme/app/commits/${NEW}/check-runs`));
    assert.ok(!calls.some((c) => c.includes(OLD)), "the old head isn't read");
    assert.ok(f.events().includes("rechecked CI on GitHub (new head ddddddd)"));
    assert.ok(f.wakes.includes(30_000), "the CI poll wakes");
  });
});

test("a pull request GitHub says merged lands the task", async () => {
  await withGitHub({ state: "closed", merged: true, merge_commit_sha: "c".repeat(40), head: { sha: OLD } }, {}, async () => {
    const f = factory();
    await f.recheck();
    await f.settle();
    const task = f.store.task("MF-1")!;
    assert.equal(task.state, "merged");
    assert.equal(task.pr!.state, "merged");
    assert.ok(f.events().includes("rechecked GitHub: pull request #7 merged"));
    assert.ok(f.events().includes("merged into main (ccccccc)"));
  });
});

test("a pull request closed on GitHub is marked closed", async () => {
  await withGitHub({ state: "closed", merged: false, head: { sha: OLD } }, {}, async () => {
    const f = factory();
    await f.recheck();
    assert.equal(f.store.task("MF-1")!.pr!.state, "closed");
    assert.deepEqual(f.events(), ["pull request #7 was closed on GitHub"]);
  });
});

test("no GitHub App, or no pull request, fails with a plain message", async () => {
  await assert.rejects(factory({ DB }).recheck(), /isn't on GitHub/);
  await assert.rejects(factory(APP_ENV, null).recheck(), /isn't on GitHub/);
});

test("nothing changed on GitHub adds no event", async () => {
  const checks = [{ name: "test", status: "passed", duration: null, required: true, url: "https://github.com/acme/app/runs/test" }];
  await withGitHub({ state: "open", merged: false, head: { sha: OLD } }, { [OLD]: [run("test", "completed", "success")] }, async () => {
    const f = factory(APP_ENV, { checks });
    await f.recheck();
    assert.equal(f.store.task("MF-1")!.pr!.head, OLD);
    assert.deepEqual(f.events(), []);
  });
});

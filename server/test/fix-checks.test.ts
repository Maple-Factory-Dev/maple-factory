// Failed CI on a task in review (MF-423): the factory sends it back to its builder with one CI change
// request (autoFixChecks, twice at most, once per head), and task.fixChecks does it on a person's ask.
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

const H2 = "e".repeat(40);
const H3 = "f".repeat(40);
const LOG = ["Run npm test", "ok 1 - parses", "not ok 2 - adds", "##[error]Process completed with exit code 1."].join("\n");

/** A stubbed GitHub: `runs` are the check runs per commit; every job's log is LOG. */
async function withGitHub(runs: Record<string, unknown[]>, body: (calls: string[]) => Promise<void>) {
  const calls: string[] = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = (async (url: string, init: RequestInit = {}) => {
    const path = new URL(url).pathname;
    calls.push(`${init.method ?? "GET"} ${path}`);
    if (path === "/repos/acme/app/installation") return Response.json({ id: 9 });
    if (path === "/app/installations/9/access_tokens") return Response.json({ token: "t", expires_at: "" });
    if (/^\/repos\/acme\/app\/actions\/jobs\/\d+\/logs$/.test(path)) return new Response(LOG);
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

function factory(env: Record<string, unknown> = APP_ENV, pr: Record<string, unknown> | null = {}, policy: Record<string, unknown> = {}) {
  const store = new Store(sqlStorage());
  const pending: Promise<unknown>[] = [];
  const wakes: number[] = [];
  const hooks = {
    broadcast: (m: { type: string; text?: string }) => { if (m.type === "toast") toasts.push(m.text!); },
    sendTo: () => {},
    machines: async () => [{ id: "mac", sessions: [] }],
    members: async () => [],
    machineChanged: async () => {},
    waitUntil: (p: Promise<unknown>) => pending.push(p),
    wakeIn: (ms: number) => wakes.push(ms),
  };
  const MACHINE = { idFromName: (id: string) => id, get: () => ({ fetch: async () => new Response(null) }) };
  const toasts: string[] = [];
  const engine = new Engine({ MACHINE, ...env } as never, store, hooks as never, { forTask: () => {} } as never, {} as never);
  store.saveTask({
    id: "MF-1", goal: "g", title: "Fix it", state: "reviewing", owner: "me", brief: "", createdAt: 1, updatedAt: 1, plan: [], planVersion: 1, doneWhen: [],
    approvals: [], approvalsNeeded: 1, reviews: [], reviewsNeeded: 1, comments: [], changes: [], events: [], mockups: [], tickets: [],
    shareable: false, agent: "claude", machine: "mac",
    pr: pr && { number: 7, url: "https://github.com/acme/app/pull/7", state: "open", head: OLD, branch: "agent/mf-1", base: "main", checks: [], ...pr },
  } as never);
  store.savePrivate("MF-1", { worktree: "~/w", repoDir: "~/app", base: "main", finishing: false, restarts: 0, gh: { owner: "acme", repo: "app" } });
  if (Object.keys(policy).length) store.savePolicy({ ...store.policy(), ...policy } as never);
  const fix = () => engine.command({ type: "task.fixChecks", id: "MF-1" } as never, ME);
  const toReview = () => { const t = store.task("MF-1")!; t.state = "reviewing"; store.saveTask(t); };
  const recheck = () => engine.command({ type: "task.recheckGitHub", id: "MF-1" } as never, ME);
  const events = () => store.task("MF-1")!.events.map((e) => e.text);
  const settle = async () => { while (pending.length) await pending.shift(); };
  return { store, engine, recheck, fix, toReview, events, wakes, settle, toasts };
}

let ids = 50;
const run = (name: string, status: string, conclusion: string | null = null) => ({ id: ids++, app: { slug: "github-actions" }, name, status, conclusion, started_at: null, completed_at: null, html_url: `https://github.com/acme/app/runs/${name}` });
const runs = {
  [OLD]: [run("test", "completed", "failure"), run("lint", "completed", "success")],
  [H2]: [run("test", "completed", "failure")],
  [H3]: [run("test", "completed", "failure")],
};
const ciChanges = (f: ReturnType<typeof factory>) => f.store.task("MF-1")!.changes.filter((c) => c.anchor === "CI");
const pushed = (f: ReturnType<typeof factory>, head: string) => {
  const t = f.store.task("MF-1")!;
  t.state = "reviewing";
  t.pr = { ...t.pr!, head, checks: [] };
  f.store.saveTask(t);
};

test("failed CI on a task in review sends it back with one CI change request", async () => {
  await withGitHub(runs, async () => {
    const f = factory();
    await f.engine.refreshChecks("MF-1");
    await f.settle();
    const task = f.store.task("MF-1")!;
    assert.equal(task.state, "building");
    const cr = ciChanges(f);
    assert.equal(cr.length, 1);
    assert.equal(cr[0].author, "factory");
    assert.match(cr[0].text, /- test \(failed step: Process completed with exit code 1\.\)/);
    assert.match(cr[0].text, /not ok 2 - adds/);
    assert.match(cr[0].text, /Reproduce each failure locally, fix it, keep the tests passing and push\./);
    assert.doesNotMatch(cr[0].text, /lint/);
    assert.ok(f.events().some((e) => e.includes("sent it back to fix test (try 1 of 2)")));
    assert.ok(f.toasts.some((t) => t.includes("CI failed; a builder is fixing it (try 1 of 2)")));

    // The same failing head read again: not sent twice.
    f.toReview();
    await f.engine.refreshChecks("MF-1");
    const again = f.store.task("MF-1")!;
    again.pr!.checks = [];
    f.store.saveTask(again);
    await f.engine.refreshChecks("MF-1");
    await f.settle();
    assert.equal(f.store.task("MF-1")!.state, "reviewing");
    assert.equal(ciChanges(f).length, 1);
  });
});

test("after 2 tries a third failure is left for a person", async () => {
  await withGitHub(runs, async () => {
    const f = factory();
    await f.engine.refreshChecks("MF-1");
    pushed(f, H2);
    await f.engine.refreshChecks("MF-1");
    assert.equal(ciChanges(f).length, 2);
    pushed(f, H3);
    await f.engine.refreshChecks("MF-1");
    await f.settle();
    assert.equal(f.store.task("MF-1")!.state, "reviewing");
    assert.equal(ciChanges(f).length, 2);
    assert.ok(f.events().includes("CI failed again after 2 fixes; left for a person"));
    assert.ok(f.toasts.some((t) => t.includes("CI failed again after 2 fixes")));
  });
});

test("with autoFixChecks off nothing is sent; task.fixChecks still sends it back", async () => {
  await withGitHub(runs, async () => {
    const f = factory(APP_ENV, {}, { autoFixChecks: false });
    await f.engine.refreshChecks("MF-1");
    await f.settle();
    assert.equal(f.store.task("MF-1")!.state, "reviewing");
    assert.equal(ciChanges(f).length, 0);
    await f.fix();
    await f.settle();
    assert.equal(f.store.task("MF-1")!.state, "building");
    const cr = ciChanges(f);
    assert.equal(cr.length, 1);
    assert.equal(cr[0].author, "me");
    assert.match(cr[0].text, /- test/);
  });
});

test("task.fixChecks is rejected when no check failed, or the checks aren't on GitHub", async () => {
  const green = { [OLD]: [run("test", "completed", "success")] };
  await withGitHub(green, async () => {
    const f = factory();
    await f.engine.refreshChecks("MF-1");
    await assert.rejects(f.fix(), /No checks have failed/);
  });
  await assert.rejects(factory({ DB }).fix(), /aren't on GitHub/);
});

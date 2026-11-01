// Workflows: write, against test/fake-github.mjs: the push and pull request tokens ask for it, so a task that changes
// .github/workflows can be pushed and merged as the app; an install that hasn't approved it yet (--no-workflows)
// still gets a token, just without it.

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { generateKeyPairSync } from "node:crypto";
import { mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createPullRequest, PERMISSIONS, repoToken, type GitHubApp } from "../src/github.ts";
import { revokeMember, saveUserToken, userToken } from "../src/auth.ts";
import { Engine } from "../src/factory/engine.ts";
import { Store } from "../src/factory/store.ts";

const { privateKey, publicKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });

async function freePort(): Promise<number> {
  return new Promise((resolve) => {
    const s = createServer().listen(0, "127.0.0.1", () => {
      const port = (s.address() as { port: number }).port;
      s.close(() => resolve(port));
    });
  });
}

/** A fake GitHub with the app installed on acme/widgets, and the app that talks to it. */
async function fakeGitHub(...flags: string[]): Promise<{ app: GitHubApp; tokens: () => Promise<{ permissions: Record<string, string>; status: number }[]>; stop: () => void }> {
  const dir = mkdtempSync(join(tmpdir(), "mf-workflows-"));
  writeFileSync(join(dir, "app.pub.pem"), publicKey.export({ type: "spki", format: "pem" }));
  const port = await freePort();
  const child: ChildProcess = spawn(process.execPath, [new URL("./fake-github.mjs", import.meta.url).pathname, "--port", String(port), "--public-key", join(dir, "app.pub.pem"),
    "--installed", "acme/widgets", "--remotes", join(dir, "{owner}/{repo}.git"), ...flags], { stdio: ["ignore", "pipe", "inherit"] });
  await new Promise<void>((resolve, reject) => {
    child.stdout!.on("data", (d) => String(d).includes("fake GitHub on") && resolve());
    child.on("exit", (c) => reject(new Error(`fake GitHub exited (${c})`)));
  });
  const api = `http://localhost:${port}`;
  return {
    app: { issuer: "12345", privateKey: privateKey.export({ type: "pkcs1", format: "pem" }) as string, api },
    tokens: async () => ((await (await fetch(`${api}/_log`)).json()) as { tokens: { permissions: Record<string, string>; status: number }[] }).tokens,
    stop: () => { child.kill(); rmSync(dir, { recursive: true, force: true }); },
  };
}

test("push and pull request tokens ask for workflows: write", async () => {
  assert.equal(PERMISSIONS.push.workflows, "write");
  assert.equal(PERMISSIONS.pulls.workflows, "write");
  assert.equal("workflows" in PERMISSIONS.fetch, false);
  const gh = await fakeGitHub();
  try {
    assert.ok((await repoToken(gh.app, "acme", "widgets", PERMISSIONS.push)).token.startsWith("ghs_"));
    assert.ok((await repoToken(gh.app, "acme", "widgets", PERMISSIONS.pulls)).token.startsWith("ghs_"));
    assert.deepEqual(await gh.tokens(), [
      { installation: 1000, repositories: ["widgets"], permissions: { contents: "write", workflows: "write" }, status: 201 },
      { installation: 1000, repositories: ["widgets"], permissions: { contents: "write", pull_requests: "write", workflows: "write" }, status: 201 },
    ]);
  } finally {
    gh.stop();
  }
});

test("an install that hasn't approved workflows still gets a token, without it", async () => {
  const gh = await fakeGitHub("--no-workflows");
  try {
    assert.ok((await repoToken(gh.app, "acme", "widgets", PERMISSIONS.push)).token.startsWith("ghs_"));
    assert.ok((await repoToken(gh.app, "acme", "widgets", PERMISSIONS.pulls)).token.startsWith("ghs_"));
    // A fetch never asked for it, so it goes through the first time.
    assert.ok((await repoToken(gh.app, "acme", "widgets", PERMISSIONS.fetch)).token.startsWith("ghs_"));
    const asked = (await gh.tokens()).map((t) => [t.permissions, t.status]);
    assert.deepEqual(asked, [
      [{ contents: "write", workflows: "write" }, 422],
      [{ contents: "write" }, 201],
      [{ contents: "write", pull_requests: "write", workflows: "write" }, 422],
      [{ contents: "write", pull_requests: "write" }, 201],
      [{ contents: "read" }, 201],
    ]);
  } finally {
    gh.stop();
  }
});

// ---- MF-229: the task's owner on its pull request, and approving on GitHub as the person who approves here ----

/** D1 on node:sqlite, with the server's migrations applied. */
function d1() {
  const db = new DatabaseSync(":memory:");
  const dir = new URL("../migrations/", import.meta.url).pathname;
  for (const f of readdirSync(dir).filter((f) => f.endsWith(".sql")).sort()) db.exec(readFileSync(join(dir, f), "utf8"));
  const DB = {
    prepare(sql: string) {
      let args: unknown[] = [];
      const st = {
        bind: (...a: unknown[]) => ((args = a), st),
        first: async () => (db.prepare(sql).get(...(args as never[])) ?? null),
        run: async () => ({ meta: { changes: Number(db.prepare(sql).run(...(args as never[])).changes) } }),
        all: async () => ({ results: db.prepare(sql).all(...(args as never[])) }),
      };
      return st;
    },
  };
  return { db, DB };
}

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
const ME = { member: { login: "me", role: "member" } } as never;

/** The engine against the fake GitHub, with MF-1 (owned by `me`) on acme/widgets, and members' tokens in a D1. */
function engineOn(gh: { app: GitHubApp }, task: Record<string, unknown> = {}) {
  const { db, DB } = d1();
  const env = {
    DB, SECRETS_KEY: "mfk_test-key", GITHUB_APP_ID: gh.app.issuer, GITHUB_APP_PRIVATE_KEY: gh.app.privateKey, GITHUB_API_URL: gh.app.api,
    GITHUB_CLIENT_ID: "Iv1.test", GITHUB_CLIENT_SECRET: "shh",
    MACHINE: { idFromName: (id: string) => id, get: () => ({ fetch: async () => new Response(null) }) },
    ORG: { idFromName: (id: string) => id, get: () => ({ fetch: async () => new Response(null) }) },
  };
  const store = new Store(sqlStorage());
  const pending: Promise<unknown>[] = [];
  const hooks = {
    broadcast: () => {}, sendTo: () => {}, machines: async () => [{ id: "mac", sessions: [] }], members: async () => [], machineChanged: async () => {},
    waitUntil: (p: Promise<unknown>) => pending.push(p), wakeIn: () => {},
    userToken: (login: string) => userToken(env as never, login),
  };
  const engine = new Engine(env as never, store, hooks as never, { forTask: () => {} } as never, {} as never);
  store.saveTask({
    id: "MF-1", goal: "g", title: "Fix it", state: "reviewing", owner: "me", brief: "", createdAt: 1, updatedAt: 1, plan: [], planVersion: 1, doneWhen: [],
    approvals: [], approvalsNeeded: 1, reviews: [], reviewsNeeded: 2, comments: [], changes: [], events: [], mockups: [], tickets: [],
    shareable: false, agent: "claude", machine: "mac", autoReview: { rounds: [{ verdict: "passed" }], maxRounds: 3 }, liveLog: null,
    pr: { number: 0, url: null, state: "open", head: HEAD, branch: "agent/mf-1", base: "main", checks: [] },
    ...task,
  } as never);
  store.savePrivate("MF-1", { worktree: "~/w", repoDir: "~/r", base: "main", finishing: false, restarts: 0 });
  const settle = async () => { while (pending.length) await pending.shift(); };
  const events = () => store.task("MF-1")!.events.map((e) => e.text);
  return { env, db, store, engine, settle, events };
}

const pullsOf = async (api: string) => ((await (await fetch(`${api}/_log`)).json()) as { pulls: any[] }).pulls;
const open = (f: ReturnType<typeof engineOn>) => (f.engine as unknown as { openPull(id: string, o: string, r: string): Promise<void> }).openPull("MF-1", "acme", "widgets");

test("an opened pull request gets the task's owner as assignee, and no review request when the rules don't ask for one", async () => {
  const gh = await fakeGitHub();
  try {
    const f = engineOn(gh);
    await open(f);
    const [pr] = await pullsOf(gh.app.api);
    assert.deepEqual(pr.assignees, [{ login: "me" }]);
    assert.deepEqual(pr.requested_reviewers, []);
    assert.ok(f.events().includes(`assigned @me to pull request #${pr.number}`), f.events().join("\n"));
  } finally {
    gh.stop();
  }
});

test("when main's rules require an approving review, the owner is asked for one too", async () => {
  const gh = await fakeGitHub();
  try {
    await fetch(`${gh.app.api}/_reviews`, { method: "POST", body: JSON.stringify({ owner: "acme", repo: "widgets", count: 1 }) });
    const f = engineOn(gh);
    await open(f);
    const [pr] = await pullsOf(gh.app.api);
    assert.deepEqual(pr.assignees, [{ login: "me" }]);
    assert.deepEqual(pr.requested_reviewers, [{ login: "me" }]);
    assert.ok(f.events().includes(`asked @me to review pull request #${pr.number} (main requires 1 approving review)`), f.events().join("\n"));
  } finally {
    gh.stop();
  }
});

/** MF-1 with its pull request open on the fake GitHub. */
async function withPull(gh: { app: GitHubApp }) {
  const pr = await createPullRequest(gh.app, "acme", "widgets", { title: "MF-1: Fix it", head: "agent/mf-1", base: "main", body: "" });
  const f = engineOn(gh, { pr: { number: pr.number, url: pr.url, state: "open", head: HEAD, branch: "agent/mf-1", base: "main", checks: [] } });
  f.store.savePrivate("MF-1", { ...f.store.private("MF-1"), gh: { owner: "acme", repo: "widgets" } });
  return { f, number: pr.number };
}

test("approving the changes approves the pull request on GitHub with the approver's own token, pinned to the reviewed head", async () => {
  const gh = await fakeGitHub();
  try {
    const { f, number } = await withPull(gh);
    await saveUserToken(f.env as never, "me", { access_token: "ghu_fake_me" });
    await f.engine.command({ type: "task.approveChanges", id: "MF-1" }, ME);
    await f.settle();
    const [pr] = await pullsOf(gh.app.api);
    // The fake refuses an approval made with the app's token, so this one was made with me's.
    assert.deepEqual(pr.reviews.map((r: any) => [r.user.login, r.state, r.commit_id, r.body]), [["me", "APPROVED", HEAD, "Approved on Maple Factory (MF-1)."]]);
    assert.deepEqual(f.store.task("MF-1")!.reviews, ["me"]);
    assert.ok(f.events().includes(`approved pull request #${number} on GitHub`), f.events().join("\n"));
  } finally {
    gh.stop();
  }
});

test("an approver with no stored token, or one GitHub refuses, still approves here and is told to sign in again", async () => {
  const gh = await fakeGitHub();
  try {
    for (const token of [null, "ghu_revoked"]) {
      const { f, number } = await withPull(gh);
      if (token) await saveUserToken(f.env as never, "me", { access_token: token });
      await f.engine.command({ type: "task.approveChanges", id: "MF-1" }, ME);
      assert.deepEqual(f.store.task("MF-1")!.reviews, ["me"]);
      const note = f.events().find((e) => e.startsWith(`couldn't approve pull request #${number} on GitHub as @me`));
      assert.ok(note, f.events().join("\n"));
      assert.match(note!, /sign in again to approve on GitHub/);
      if (token) assert.match(note!, /401/);
    }
    assert.ok((await pullsOf(gh.app.api)).every((p) => p.reviews.length === 0));
  } finally {
    gh.stop();
  }
});

test("a merge GitHub refuses for want of approving reviews goes to a person, saying so plainly", async () => {
  const gh = await fakeGitHub();
  try {
    await fetch(`${gh.app.api}/_reviews`, { method: "POST", body: JSON.stringify({ owner: "acme", repo: "widgets", count: 1 }) });
    const { f, number } = await withPull(gh);
    f.store.savePrivate("MF-1", { ...f.store.private("MF-1"), merging: true });
    const task = f.store.task("MF-1")!;
    await (f.engine as unknown as { mergeOnGitHub(...a: unknown[]): Promise<void> }).mergeOnGitHub("MF-1", gh.app, { owner: "acme", repo: "widgets" }, task.pr);
    const hand = f.store.task("MF-1")!.hand!;
    assert.equal(hand.reason, "mergeFailed");
    assert.match(hand.summary, /^GitHub wants an approving review before it merges into main/);
    assert.match(hand.summary, new RegExp(`Approve pull request #${number} on GitHub, or sign in to the factory again`));
    assert.equal(hand.options.find((o) => o.recommended)?.title, "Try the merge again");
    assert.equal(f.store.private("MF-1").mergeFixes ?? 0, 0, "not sent back to a builder");
  } finally {
    gh.stop();
  }
});

test("members' GitHub tokens are stored sealed, refreshed once expired, and deleted when the member is revoked", async () => {
  const gh = await fakeGitHub();
  try {
    const { env, db } = engineOn(gh);
    await saveUserToken(env as never, "me", { access_token: "ghu_fake_me", refresh_token: "ghr_fake_me", expires_in: 28800 });
    const row = db.prepare("SELECT * FROM member_github_tokens WHERE login = 'me'").get() as Record<string, unknown>;
    assert.ok(!JSON.stringify(row).includes("ghu_fake_me") && !JSON.stringify(row).includes("ghr_fake_me"), "no raw token in the row");
    assert.ok(Number(row.expires_at) > Date.now());
    assert.equal(await userToken(env as never, "me"), "ghu_fake_me");
    // A row copied onto someone else won't open.
    db.prepare("INSERT INTO member_github_tokens (login, access_token, refresh_token, expires_at, updated_at) VALUES ('you', ?, NULL, NULL, 0)").run(row.access_token as string);
    assert.equal(await userToken(env as never, "you"), null);

    // Expired: refreshed with the refresh token, and the new pair kept.
    await saveUserToken(env as never, "me", { access_token: "ghu_stale", refresh_token: "ghr_fake_me", expires_in: 1 });
    db.prepare("UPDATE member_github_tokens SET expires_at = ? WHERE login = 'me'").run(Date.now() - 1000);
    const before = db.prepare("SELECT access_token FROM member_github_tokens WHERE login = 'me'").get() as { access_token: string };
    assert.equal(await userToken(env as never, "me"), "ghu_fake_me");
    const after = db.prepare("SELECT access_token, expires_at FROM member_github_tokens WHERE login = 'me'").get() as { access_token: string; expires_at: number };
    assert.notEqual(after.access_token, before.access_token);
    assert.ok(after.expires_at > Date.now());
    assert.equal(await userToken(env as never, "nobody"), null);

    await revokeMember(env as never, "me", "admin");
    assert.equal(db.prepare("SELECT * FROM member_github_tokens WHERE login = 'me'").get(), undefined);
    assert.equal(await userToken(env as never, "me"), null);
  } finally {
    gh.stop();
  }
});

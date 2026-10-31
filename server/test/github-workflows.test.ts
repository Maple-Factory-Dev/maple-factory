// Workflows: write, against test/fake-github.mjs: the push and pull request tokens ask for it, so a task that changes
// .github/workflows can be pushed and merged as the app; an install that hasn't approved it yet (--no-workflows)
// still gets a token, just without it.

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { generateKeyPairSync } from "node:crypto";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PERMISSIONS, repoToken, type GitHubApp } from "../src/github.ts";

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

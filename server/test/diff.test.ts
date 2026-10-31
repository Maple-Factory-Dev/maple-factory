// The Changes tab's routes on a real OrgHub (`cloudflare:workers` stubbed, node:sqlite storage): a
// `task.diff` with commits lists them at /commits and serves each one's patch at /diff?commit=, a later
// one without a commit drops it, and one from an older runner (no `commits`) keeps the whole diff working.
import { test } from "node:test";
import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { DatabaseSync } from "node:sqlite";
import type { DiffCommit } from "../src/wire.ts";

registerHooks({
  resolve(specifier, context, next) {
    if (specifier === "cloudflare:workers") return { url: "stub:cloudflare-workers", shortCircuit: true };
    return next(specifier, context);
  },
  load(url, context, next) {
    if (url === "stub:cloudflare-workers") {
      return { format: "module", shortCircuit: true, source: "export class DurableObject { constructor(ctx, env) { this.ctx = ctx; this.env = env } }" };
    }
    // The Worker imports package.json as wrangler bundles it, without `with { type: "json" }`.
    if (url.endsWith(".json")) return next(url, { ...context, importAttributes: { type: "json" } });
    return next(url, context);
  },
});
const { OrgHub } = await import("../src/org-hub.ts");

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
  };
}

/** An OrgHub with MF-1 on `mac`; `diff` sends it a `task.diff` as the runner would. */
function hub() {
  const ctx = {
    storage: { sql: sqlStorage(), list: async () => new Map(), get: async () => undefined, put: async () => {}, getAlarm: async () => null, setAlarm: async () => {} },
    blockConcurrencyWhile: (fn: () => Promise<void>) => fn(),
    waitUntil: () => {},
    getWebSockets: () => [],
  };
  const env = { DB: { prepare: () => ({ all: async () => ({ results: [] }) }) } };
  const org = new OrgHub(ctx as never, env as never);
  const inner = org as unknown as { store: { saveTask(t: unknown): void }; engine: { fromRunner(machine: string, msg: unknown): Promise<unknown> } };
  inner.store.saveTask({
    id: "MF-1", goal: "g", title: "Fix it", state: "building", owner: "me", brief: "", createdAt: 1, updatedAt: 1, plan: [], planVersion: 1, doneWhen: [],
    approvals: [], approvalsNeeded: 1, reviews: [], reviewsNeeded: 1, comments: [], changes: [], events: [], mockups: [], tickets: [],
    shareable: false, agent: "claude", machine: "mac",
  });
  const diff = (commits?: DiffCommit[]) =>
    inner.engine.fromRunner("mac", {
      type: "task.diff", taskId: "MF-1", ok: true, files: [{ path: "a.txt", added: 2, removed: 0 }], patch: "whole patch", truncated: false, message: null,
      ...(commits ? { commits } : {}),
    });
  const get = (path: string) => org.fetch(new Request(`https://org${path}`));
  return { diff, get };
}

const commit = (sha: string, subject: string): DiffCommit => ({
  sha: sha.repeat(40), subject, author: "T", at: 1_700_000_000_000, added: 1, removed: 0, files: [{ path: "a.txt", added: 1, removed: 0 }], patch: `patch of ${subject}`, truncated: false,
});

test("a task.diff's commits are listed and each serves its own patch", async () => {
  const { diff, get } = hub();
  await diff([commit("1", "First"), commit("2", "Second")]);
  const list = (await (await get("/commits?task=MF-1")).json()) as DiffCommit[];
  assert.deepEqual(list.map((c) => [c.sha, c.subject, c.patch]), [["1".repeat(40), "First", ""], ["2".repeat(40), "Second", ""]]);
  assert.deepEqual(list[0].files, [{ path: "a.txt", added: 1, removed: 0 }]);
  assert.equal(await (await get(`/diff?task=MF-1&commit=${"2".repeat(40)}`)).text(), "patch of Second");
  assert.equal(await (await get("/diff?task=MF-1")).text(), "whole patch");
  assert.equal((await get(`/diff?task=MF-1&commit=${"9".repeat(40)}`)).status, 404);
});

test("a later task.diff without a commit (a rebase or amend) drops it", async () => {
  const { diff, get } = hub();
  await diff([commit("1", "First"), commit("2", "Second")]);
  await diff([commit("1", "First"), commit("3", "Amended")]);
  const list = (await (await get("/commits?task=MF-1")).json()) as DiffCommit[];
  assert.deepEqual(list.map((c) => c.subject), ["First", "Amended"]);
  assert.equal((await get(`/diff?task=MF-1&commit=${"2".repeat(40)}`)).status, 404);
  assert.equal(await (await get(`/diff?task=MF-1&commit=${"3".repeat(40)}`)).text(), "patch of Amended");
});

test("a task.diff from an older runner, with no commits, still works", async () => {
  const { diff, get } = hub();
  await diff();
  assert.deepEqual(await (await get("/commits?task=MF-1")).json(), []);
  assert.equal(await (await get("/diff?task=MF-1")).text(), "whole patch");
  assert.equal((await get("/commits?task=MF-2")).status, 200);
});

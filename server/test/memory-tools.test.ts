// MF-392: agents' memory tools (recall, remember, forget) through the engine on a node:sqlite store, the way a
// runner's mcp.request reaches them: listed per role and for personal sessions, the scope key filled in by the
// server, near-duplicates and the per-session cap, provenance, archive-not-delete, and the task's timeline.
import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { Engine } from "../src/factory/engine.ts";
import { Store } from "../src/factory/store.ts";
import { toolsFor, personalTools, MEMORY_TOOL_NAMES } from "../src/factory/tools.ts";
import { MAX_WRITES, normalizeText, repoFromCwd, similarity } from "../src/factory/memory-tools.ts";
import type { Memory } from "../src/wire.ts";

function sqlStorage() {
  const db = new DatabaseSync(":memory:");
  return {
    exec(query: string, ...bindings: unknown[]) {
      const statements = query.split(";").map((s) => s.trim()).filter(Boolean);
      // Triggers hold a `;` of their own, so anything with several statements goes through exec whole.
      if (statements.length > 1) {
        db.exec(query);
        return { toArray: () => [], one: () => undefined };
      }
      const rows = db.prepare(query).all(...(bindings as never[]));
      return { toArray: () => rows, one: () => rows[0] };
    },
  } as unknown as SqlStorage;
}

const BUILDER = "33333333-3333-4333-8333-333333333333";
const REVIEWER = "55555555-5555-4555-8555-555555555555";
const OTHER_TASK = "66666666-6666-4666-8666-666666666666";
const PERSONAL = "44444444-4444-4444-8444-444444444444";
const ELSEWHERE = "77777777-7777-4777-8777-777777777777";
const ASK = "88888888-8888-4888-8888-888888888888";

type Out = { result?: { summary: string; data: any }; error?: string };

function factory() {
  const store = new Store(sqlStorage());
  const broadcasts: { type: string; memory?: Memory }[] = [];
  const audits: unknown[][] = [];
  const live = (id: string, cwd: string) => ({ session: { id, agent: "codex", cwd, pid: 1, startedAt: 1, taskId: null } });
  const hooks = {
    broadcast: (m: any) => broadcasts.push(m),
    sendTo: () => {},
    machines: async () => [{
      id: "mac", name: "studio", owner: "owner",
      sessions: [live(PERSONAL, "/Users/owner/code/acme/.worktrees/mac/fix-login"), live(ELSEWHERE, "/Users/owner/Desktop/notes")],
    }],
    members: async () => [{ login: "owner" }],
    machineChanged: async () => {},
    waitUntil: () => {},
    wakeIn: () => {},
  };
  const DB = { prepare: () => ({ bind: (...args: unknown[]) => ({ run: async () => { audits.push(args); } }) }) };
  const engine = new Engine({ DB } as never, store, hooks as never, { forTask: () => {} } as never, {} as never);
  store.saveRepos([{ name: "acme/mac", isPrivate: true, source: "manual" }, { name: "acme/web", isPrivate: true, source: "manual" }] as never);
  store.saveGoal({ id: "g", name: "Apps", prefix: "MF", summary: "", lead: "owner", repos: [], repo: "acme/mac", archived: false } as never);
  store.saveGoal({ id: "g2", name: "Web", prefix: "WB", summary: "", lead: "owner", repos: [], repo: "acme/web", archived: false } as never);
  const task = (id: string, goal: string, session: string, role: string, repo: string | null) => {
    store.saveTask({
      id, goal, title: "Tidy", state: role === "reviewer" ? "reviewing" : "building", owner: "owner", brief: "", createdAt: 1, updatedAt: 1, plan: [], planVersion: 1, doneWhen: [],
      approvals: [], approvalsNeeded: 1, reviews: [], reviewsNeeded: 1, comments: [], changes: [], events: [], mockups: [], tickets: [],
      shareable: true, agent: "claude", model: "x", effort: "high", machine: "mac", repo, branch: `agent/${id.toLowerCase()}`,
      worker: { role, agent: "claude", machine: "mac", session, startedAt: 1 },
    } as never);
    store.addSession({ id: session, task: id, role: role as never, machine: "mac", agent: "claude", started: 1, ended: null, cause: null, kind: "team" });
  };
  task("MF-1", "g", BUILDER, "builder", "acme/mac");
  task("MF-2", "g", REVIEWER, "reviewer", null); // no repo of its own: its goal's
  task("WB-1", "g2", OTHER_TASK, "builder", null);
  const call = async (tool: string, args: Record<string, unknown> = {}, session = BUILDER) =>
    (await engine.fromRunner("mac", { type: "mcp.request", reqId: "r", session, tool, args } as never)) as Out;
  const remember = async (text: string, scope = "repo", session = BUILDER, more: Record<string, unknown> = {}) => {
    const out = await call("remember", { text, kind: "gotcha", scope, ...more }, session);
    assert.equal(out.error, undefined, out.error);
    return out.result!.data as { id: string; already: boolean };
  };
  return { store, engine, call, remember, broadcasts, audits };
}

// Ten notes with no words in common, so none is a near-duplicate of another.
const NOTES = ["alpha bravo", "charlie delta", "echo foxtrot", "golf hotel", "india juliet", "kilo lima", "mike november", "oscar papa", "quebec romeo", "sierra tango", "uniform victor"];

test("recall, remember and forget are listed for every role and for a personal session, not for a doc ask", async () => {
  assert.deepEqual(MEMORY_TOOL_NAMES, ["recall", "remember", "forget"]);
  for (const role of ["planner", "builder", "reviewer"] as const) for (const n of MEMORY_TOOL_NAMES) assert.ok(toolsFor(role).some((t) => t.name === n), `${role} ${n}`);
  for (const n of MEMORY_TOOL_NAMES) assert.ok(personalTools().some((t) => t.name === n), n);
  const { call, store } = factory();
  const names = async (session: string) => ((await call("tools/list", {}, session)).result!.data.tools as { name: string }[]).map((t) => t.name);
  for (const session of [BUILDER, REVIEWER, PERSONAL]) for (const n of MEMORY_TOOL_NAMES) assert.ok((await names(session)).includes(n), `${session} ${n}`);
  const schema = toolsFor("builder").find((t) => t.name === "remember")!;
  assert.deepEqual((schema.inputSchema as any).required, ["text", "kind", "scope"]);
  assert.match(schema.description, /600 characters/);
  assert.deepEqual((toolsFor("builder").find((t) => t.name === "forget")!.inputSchema as any).required, ["id", "reason"]);
  // A session asked from a doc gets the doc tools only.
  store.set(`docask:${ASK}`, JSON.stringify({ session: ASK, by: "owner", doc: "d", thread: "t", agent: "claude", machine: "mac" }));
  const asked = await names(ASK);
  assert.ok(asked.includes("read_doc"));
  for (const n of MEMORY_TOOL_NAMES) assert.ok(!asked.includes(n), n);
  assert.match((await call("remember", { text: "x", kind: "fact", scope: "org" }, ASK)).error!, /isn't available to an agent asked from a doc/);
});

test("remember fills in the scope key from the task's repo and goal, and stamps provenance", async () => {
  const { store, remember, broadcasts } = factory();
  const repo = store.memory((await remember("Run the Mac tests with the scheme MapleTests, not Maple.")).id)!;
  assert.deepEqual(repo.scope, { kind: "repo", key: "acme/mac" });
  assert.equal(repo.status, "active");
  assert.equal(repo.kind, "gotcha");
  assert.deepEqual(repo.source, { by: "owner", task: "MF-1", role: "builder", agent: "MF-1 builder", machine: "studio", decision: null });
  assert.deepEqual(store.memory((await remember("Releases are cut on Thursdays.", "goal")).id)!.scope, { kind: "goal", key: "g" });
  assert.deepEqual(store.memory((await remember("Everyone writes British English in docs.", "org", BUILDER, { tags: ["Docs", "style"] })).id)!.scope, { kind: "org", key: null });
  // A task with no repo of its own takes its goal's.
  const fromGoal = store.memory((await remember("The reviewer checks screenshots at 2x.", "repo", REVIEWER)).id)!;
  assert.deepEqual(fromGoal.scope, { kind: "repo", key: "acme/mac" });
  assert.equal(fromGoal.source.role, "reviewer");
  assert.equal(fromGoal.source.agent, "MF-2 reviewer");
  assert.equal(broadcasts.filter((b) => b.type === "memory.updated").length, 4);
});

test("remember refuses what isn't a memory", async () => {
  const { call } = factory();
  assert.match((await call("remember", { text: "x", kind: "status", scope: "repo" })).error!, /kind is/);
  assert.match((await call("remember", { text: "x", kind: "fact", scope: "acme/mac" })).error!, /scope is "org", "repo" or "goal"/);
  assert.match((await call("remember", { text: "", kind: "fact", scope: "repo" })).error!, /text is required/);
  assert.match((await call("remember", { text: "y".repeat(601), kind: "fact", scope: "repo" })).error!, /at most 600 characters/);
});

test("a personal session's repo comes from its cwd; outside a repo only the org scope works", async () => {
  const { store, call, remember } = factory();
  const m = store.memory((await remember("The login screen needs a signed build to test.", "repo", PERSONAL)).id)!;
  assert.deepEqual(m.scope, { kind: "repo", key: "acme/mac" });
  assert.deepEqual(m.source, { by: "owner", task: null, role: null, agent: "codex on studio", machine: "studio", decision: null });
  assert.match((await call("remember", { text: "x", kind: "fact", scope: "goal" }, PERSONAL)).error!, /has no goal/);
  // A folder that isn't a checkout of an org repo.
  assert.match((await call("remember", { text: "x", kind: "fact", scope: "repo" }, ELSEWHERE)).error!, /This folder isn't one of the org's repos/);
  await remember("Standups are async, in the #factory channel.", "org", ELSEWHERE);
  const seen = (await call("recall", {}, ELSEWHERE)).result!.data;
  assert.deepEqual(seen.map((x: any) => x.scope), ["org"]);
  // The task on that repo sees what the personal session remembered.
  assert.ok((await call("recall", { q: "signed build" })).result!.data.some((x: any) => x.id === m.id));
});

test("recall respects scope and limit, and counts each use", async () => {
  const { store, call, remember } = factory();
  const mac = await remember("The Mac app's tests need Xcode 27.");
  const goal = await remember("This goal ships behind the flag newComposer.", "goal");
  const org = await remember("Commits are prefixed with the task id.", "org");
  const web = await remember("The web build needs Node 26.", "repo", OTHER_TASK);
  const all = (await call("recall")).result!.data;
  assert.deepEqual(all.map((m: any) => m.id).sort(), [mac.id, goal.id, org.id].sort());
  assert.deepEqual(Object.keys(all[0]).sort(), ["id", "kind", "scope", "tags", "text"]);
  assert.ok(!all.some((m: any) => m.id === web.id), "another repo's memories stay out");
  assert.deepEqual((await call("recall", { scope: "repo" })).result!.data.map((m: any) => m.id), [mac.id]);
  assert.deepEqual((await call("recall", { scope: "goal" })).result!.data.map((m: any) => m.id), [goal.id]);
  assert.equal((await call("recall", { limit: 2 })).result!.data.length, 2);
  assert.deepEqual((await call("recall", { q: "xcode tests" })).result!.data.map((m: any) => m.id), [mac.id]);
  assert.deepEqual((await call("recall", { q: "kubernetes" })).result!.data, []);
  // mac came back from: all, scope repo, and q (limit 2 returns the two newest: org and goal).
  const used = store.memory(mac.id)!;
  assert.equal(used.uses, 3);
  assert.ok(used.lastUsedAt! > 0);
  assert.equal(store.memory(web.id)!.uses, 0);
  assert.equal(store.memoryLog(mac.id).length, 1, "a recall isn't an edit");
});

test("a near-duplicate returns the existing memory and writes nothing", async () => {
  const { store, remember } = factory();
  const first = await remember("Always run `npm run gen` after changing protocol/schema.ts, or the Swift build breaks.");
  const same = await remember("always run npm run gen after changing protocol/schema.ts or the swift build breaks");
  assert.deepEqual(same, { id: first.id, already: true });
  const near = await remember("Always run `npm run gen` after changing protocol/schema.ts, or the Swift build then breaks!");
  assert.equal(near.id, first.id);
  assert.equal(store.memories().length, 1);
  assert.equal(store.memoryWrites(BUILDER).n, 1, "a duplicate doesn't count toward the cap");
  // The same words in another scope are their own memory.
  assert.equal((await remember("Always run `npm run gen` after changing protocol/schema.ts, or the Swift build breaks.", "org")).already, false);
  assert.equal(similarity(normalizeText("Hello, World!"), normalizeText("hello   world")), 1);
  assert.ok(similarity(normalizeText("the web build needs node"), normalizeText("the mac build needs xcode")) < 0.85);
});

test("the 11th write in a session is refused; another session still writes", async () => {
  const { store, call, remember } = factory();
  for (const note of NOTES.slice(0, MAX_WRITES)) await remember(note);
  const refused = await call("remember", { text: NOTES[10], kind: "fact", scope: "repo" });
  assert.match(refused.error!, /already made 10 memory writes.*Keep only what matters/);
  assert.equal(store.memories().length, 10);
  // forget counts toward the same cap.
  assert.match((await call("forget", { id: store.memories()[0].id, reason: "wrong" })).error!, /already made 10 memory writes/);
  assert.equal(store.memories()[0].status, "active");
  assert.equal((await remember(NOTES[10], "repo", REVIEWER)).already, false);
  // The count is in the store, so a new engine on it (the Durable Object waking) still refuses.
  assert.deepEqual(store.memoryWrites(BUILDER), { n: 10, remembered: 10 });
  assert.equal((await call("recall", { limit: 50 })).result!.data.length, 11, "reading isn't capped");
});

test("supersedes archives the old memory; one outside the session's scopes is refused", async () => {
  const { store, call, remember } = factory();
  const old = await remember("The Mac tests need Xcode 26.");
  const next = await remember("The Mac tests need Xcode 27 since the SwiftUI update.", "repo", BUILDER, { supersedes: old.id });
  assert.equal(store.memory(next.id)!.supersedes, old.id);
  assert.equal(store.memory(old.id)!.status, "archived");
  assert.deepEqual((await call("recall", { scope: "repo" })).result!.data.map((m: any) => m.id), [next.id]);
  const web = await remember("The web build needs Node 26.", "repo", OTHER_TASK);
  assert.match((await call("remember", { text: "The web build needs Node 28.", kind: "fact", scope: "repo", supersedes: web.id })).error!, /no memory .* in this session's scopes/);
});

test("forget archives and never deletes, needs a reason, and stays inside the session's scopes", async () => {
  const { store, call, remember, broadcasts, audits } = factory();
  const m = await remember("CI runs on the self-hosted Mac mini.");
  assert.match((await call("forget", { id: m.id })).error!, /reason is required/);
  assert.match((await call("forget", { id: m.id, reason: "  " })).error!, /reason is required/);
  const out = await call("forget", { id: m.id, reason: "CI moved to hosted runners" });
  assert.equal(out.error, undefined, out.error);
  assert.deepEqual(out.result!.data, { id: m.id, status: "archived" });
  const kept = store.memory(m.id)!;
  assert.equal(kept.status, "archived");
  assert.equal(kept.text, "CI runs on the self-hosted Mac mini.");
  assert.deepEqual(store.memoryLog(m.id).map((e) => e.action), ["created", "status"]);
  assert.equal(store.memoryLog(m.id)[1].state.status, "archived");
  assert.ok(!broadcasts.some((b) => b.type === "memory.removed"));
  assert.equal(broadcasts.filter((b) => b.type === "memory.updated").at(-1)!.memory!.status, "archived");
  assert.deepEqual((await call("recall")).result!.data, []);
  // The reason is in the audit log.
  const audited = audits.find((a) => a[2] === "memory.archived")!;
  assert.equal(audited[3], m.id);
  assert.deepEqual(JSON.parse(audited[4] as string), { reason: "CI moved to hosted runners", task: "MF-1", agent: "MF-1 builder" });
  // Another repo's memory can't be forgotten from here.
  const web = await remember("The web build needs Node 26.", "repo", OTHER_TASK);
  assert.match((await call("forget", { id: web.id, reason: "not true" })).error!, /no memory .* in this session's scopes/);
  assert.equal(store.memory(web.id)!.status, "active");
  assert.match((await call("forget", { id: "nope", reason: "x" })).error!, /no memory nope/);
});

test("a task whose agent remembers three things has one 'remembered 3 things' event", async () => {
  const { store, call, remember } = factory();
  const said = () => store.task("MF-1")!.events.map((e) => `${e.who}: ${e.text}`);
  const first = await remember(NOTES[0]);
  assert.deepEqual(said(), ["builder: remembered 1 thing"]);
  await remember(NOTES[1]);
  await remember(NOTES[0]); // a duplicate: nothing written, nothing counted
  await call("recall");
  await remember(NOTES[2], "org");
  assert.deepEqual(said(), ["builder: remembered 3 things"]);
  assert.equal(store.task("MF-1")!.events.filter((e) => /^remembered /.test(e.text)).length, 1);
  await call("forget", { id: first.id, reason: "it was a guess" });
  assert.deepEqual(said(), ["builder: remembered 3 things", "builder: archived a memory: it was a guess"]);
  // Another task's timeline is its own.
  await remember(NOTES[3], "repo", REVIEWER);
  assert.deepEqual(store.task("MF-2")!.events.map((e) => e.text), ["remembered 1 thing"]);
  assert.deepEqual(said().length, 2);
});

test("repoFromCwd: a checkout, a worktree, a bare folder name, ambiguity and no match", () => {
  const repos = [{ name: "acme/mac" }, { name: "acme/web" }, { name: "Maple-Factory-Dev/maple-factory" }];
  assert.equal(repoFromCwd("/Users/me/code/acme/mac", repos), "acme/mac");
  assert.equal(repoFromCwd("/Users/me/code/acme/mac/Sources/App", repos), "acme/mac");
  assert.equal(repoFromCwd("/Users/me/.local/share/maple/repos/maple-factory-dev/.worktrees/maple-factory/mf-392", repos), "Maple-Factory-Dev/maple-factory");
  assert.equal(repoFromCwd("/Users/me/src/WEB", repos), "acme/web", "the repo's name alone, any case");
  assert.equal(repoFromCwd("/Users/me/src/web/mac", repos), "acme/mac", "the deepest folder wins");
  assert.equal(repoFromCwd("/Users/me/src/tools", [...repos, { name: "acme/tools" }, { name: "other/tools" }]), null, "two repos share that name");
  assert.equal(repoFromCwd("/Users/me/src/other/tools", [...repos, { name: "acme/tools" }, { name: "other/tools" }]), "other/tools");
  assert.equal(repoFromCwd("/Users/me/Desktop", repos), null);
  assert.equal(repoFromCwd("", repos), null);
  assert.equal(repoFromCwd(null, repos), null);
});

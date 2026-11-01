// Routing by requirements (MF-334): a task's `requires` tags pick the machine it runs on, a repo's
// `[macos] ` checks only run where they can, and its path rules add tags from the plan's files. The
// case that matters: one owner with a Mac (macos, xcode) and a Linux droplet, in a repo with a Rust
// runner, a TS server and Swift apps. Through the engine on a node:sqlite store (as propose.test.ts does).
import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { Engine } from "../src/factory/engine.ts";
import { Store } from "../src/factory/store.ts";
import { checksFor, parseCheck, pathRules, requiresFor, scriptsProblem, tidyScripts } from "../src/factory/repo-setup.ts";
import { builderPrompt } from "../src/factory/prompts.ts";

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

const REPO = "acme/factory";
const SESSION = "55555555-5555-4555-8555-555555555555";
const ANDREA = { member: { login: "andrea", role: "member" } } as never;
const CHECKS = "npm test\n[macos] xcodebuild test -scheme MapleFactory";

type M = { id: string; name: string; owner: string; online: boolean; sessions: never[]; tags: string[] | null };

/** Andrea's droplet (listed first, so a pick that ignored tags would land there) and Mac, and Sam's Linux box lending every idle slot. */
function machines(): M[] {
  return [
    { id: "droplet", name: "droplet", owner: "andrea", online: true, sessions: [], tags: ["linux", "x86_64"] },
    { id: "mac", name: "Andrea's MacBook", owner: "andrea", online: true, sessions: [], tags: ["arm64", "macos", "xcode"] },
    { id: "sam-linux", name: "sam's box", owner: "sam", online: true, sessions: [], tags: ["linux"] },
  ];
}

function factory(task: Record<string, unknown> = {}) {
  const store = new Store(sqlStorage());
  const pending: Promise<unknown>[] = [];
  const sent: { to: string; body: Record<string, unknown> }[] = [];
  const list = machines();
  const hooks = {
    broadcast: () => {},
    sendTo: () => {},
    machines: async () => list,
    members: async () => [],
    machineChanged: async () => {},
    waitUntil: (p: Promise<unknown>) => pending.push(p),
    wakeIn: () => {},
  };
  const DB = { prepare: () => ({ bind: () => ({ run: async () => {} }) }) };
  const MACHINE = {
    idFromName: (id: string) => id,
    get: (to: string) => ({ fetch: async (_: string, init: RequestInit) => (sent.push({ to, body: JSON.parse(String(init.body)) }), new Response(null)) }),
  };
  const engine = new Engine({ DB, MACHINE } as never, store, hooks as never, { forTask: () => {} } as never, {} as never);
  store.saveGoal({ id: "g", name: "Maple Factory", prefix: "MF", summary: "", lead: "andrea", repos: [REPO], repo: REPO, archived: false } as never);
  store.saveRepoScripts(REPO, { checks: CHECKS, requirePaths: "apps/mac/** macos\napps/ios/** macos,xcode" }, "andrea");
  // Sam lends every idle slot to the team.
  store.saveSettings("sam-linux", { ...store.settings("sam-linux"), lendIdle: true });
  store.saveTask({
    id: "MF-1", goal: "g", title: "Mac app: a new button", state: "building", owner: "andrea", brief: "", createdAt: 1, updatedAt: 1,
    plan: [{ text: "Add the button", file: "apps/mac/Sources/MapleFactory/Button.swift", progress: "pending" }], planVersion: 1, doneWhen: [],
    approvals: ["andrea"], approvalsNeeded: 1, reviews: [], reviewsNeeded: 1, comments: [], changes: [], events: [], mockups: [], tickets: [], artifacts: [],
    shareable: false, agent: "claude", machine: null, repo: REPO, branch: "agent/mf-1", after: [], followUps: [], requires: ["macos"],
    ...task,
  } as never);
  const settle = async () => { while (pending.length) await pending.shift(); };
  const t = () => store.task("MF-1")!;
  const pump = async () => { await engine.pump(); await settle(); };
  const opened = () => sent.filter((s) => s.body.type === "session.open");
  const at = (id: string) => list.find((m) => m.id === id)!;
  return { store, engine, sent, list, t, pump, opened, at, settle };
}

test("a macos task goes to the Mac, not the droplet listed first", async () => {
  const f = factory();
  await f.pump();
  assert.equal(f.t().worker?.machine, "mac");
  assert.equal(f.opened()[0].to, "mac");
  assert.equal(f.t().waiting ?? null, null);
});

test("with the Mac offline, a macos task waits and names the Mac and macos", async () => {
  const f = factory();
  f.at("mac").online = false;
  await f.pump();
  assert.equal(f.t().worker ?? null, null);
  assert.equal(f.opened().length, 0);
  assert.equal(f.t().waiting, "Waiting for andrea's machine with macos (Andrea's MacBook) to come online.");
  // It comes back: the task starts there.
  f.at("mac").online = true;
  await f.pump();
  assert.equal(f.t().worker?.machine, "mac");
});

test("a task with no requirements runs on either machine", async () => {
  for (const offline of ["mac", "droplet"]) {
    const f = factory({ requires: null });
    f.at(offline).online = false;
    await f.pump();
    assert.equal(f.t().worker?.machine, offline === "mac" ? "droplet" : "mac");
  }
  // Both up: it takes the first free one, as before (no tags asked for, none checked).
  const f = factory({ requires: [] });
  await f.pump();
  assert.equal(f.t().worker?.machine, "droplet");
});

test("a lent teammate machine without the tag is skipped; a plain shareable task still uses it", async () => {
  const plain = factory({ requires: null, shareable: true });
  plain.at("mac").online = false;
  plain.at("droplet").online = false;
  await plain.pump();
  assert.equal(plain.t().worker?.machine, "sam-linux");

  const f = factory({ shareable: true });
  f.at("mac").online = false;
  await f.pump();
  assert.equal(f.t().worker ?? null, null);
  assert.equal(f.t().waiting, "Waiting for andrea's machine with macos (Andrea's MacBook) to come online, or a team machine with macos.");
});

test("an owner with no macos machine is told to add or tag one", async () => {
  const f = factory();
  f.list.splice(f.list.findIndex((m) => m.id === "mac"), 1);
  await f.pump();
  assert.equal(f.t().waiting, "None of andrea's machines has macos: add one under Machines or tag one.");
  // A machine tagged by hand (extraTags shows up in tags) takes it.
  f.at("droplet").tags = ["linux", "macos"];
  await f.pump();
  assert.equal(f.t().worker?.machine, "droplet");
});

test("the online machines are named when an offline one never reported its tags", async () => {
  const f = factory();
  f.at("mac").online = false;
  f.at("mac").tags = null;
  await f.pump();
  assert.equal(f.t().waiting, "None of andrea's online machines (droplet) has macos; waiting for one that does.");
});

function planning(requires?: unknown, file = "apps/mac/Sources/MapleFactory/Button.swift") {
  const f = factory({ state: "planning", plan: [], planVersion: 0, approvals: [], requires: null, machine: "droplet", worker: { role: "planner", agent: "claude", machine: "droplet", session: SESSION, startedAt: 1 } });
  f.store.savePrivate("MF-1", { worktree: "~/.worktrees/factory/mf-1", repoDir: "~/factory", base: "main", finishing: false, restarts: 0 } as never);
  f.store.addSession({ id: SESSION, task: "MF-1", role: "planner", machine: "droplet", agent: "claude", started: 1, ended: null, cause: null, kind: "personal" });
  const submit = async () => (await f.engine.fromRunner("droplet", { type: "mcp.request", reqId: "r", session: SESSION, tool: "submit_plan", args: {
    summary: "Add a button.",
    steps: [{ text: "Add the button", file }, { text: "Test it", file: "server/test/x.test.ts" }],
    doneWhen: [{ text: "Tests pass", proof: "tests" }],
    risk: { level: "medium", reasons: ["UI"] },
    footprint: { files: 2, lines: 40 },
    ...(requires !== undefined ? { requires } : {}),
  } } as never)) as { result?: { summary: string }; error?: string };
  return { ...f, submit };
}

test("submit_plan: a step in apps/mac gives requires=[macos] from the repo's path rule, without the planner listing it", async () => {
  const f = planning();
  const reply = await f.submit();
  assert.equal(reply.error, undefined);
  assert.deepEqual(f.t().requires, ["macos"]);
  // The planner's own tags join the rule's, sorted and once each.
  const both = planning(["xcode", "macos"]);
  await both.submit();
  assert.deepEqual(both.t().requires, ["macos", "xcode"]);
  // A server-only plan needs nothing.
  const plain = planning(undefined, "server/src/x.ts");
  await plain.submit();
  assert.equal(plain.t().requires ?? null, null);
  // A bad tag is refused.
  const bad = planning(["Mac OS"]);
  const refused = await bad.submit();
  assert.match(String(refused.error), /requires: "mac os" isn't a machine tag/);
});

test("approving a plan that needs macos moves its planning worktree off the droplet, and it builds on the Mac", async () => {
  const f = planning();
  // Not drained: closing the planner kills its session after CLOSE_AFTER_MS.
  await f.submit();
  assert.equal(f.t().state, "awaitingApproval");
  await f.engine.command({ type: "task.approvePlan", id: "MF-1" } as never, ANDREA);
  assert.equal(f.t().state, "building");
  assert.ok(f.t().events.some((e) => e.text.includes("moved it off droplet (it lacks macos)")), JSON.stringify(f.t().events.map((e) => e.text)));
  await f.engine.pump();
  assert.equal(f.t().worker?.machine, "mac");
  assert.equal(f.t().worker?.role, "builder");
});

/** MF-1 building on `machine`, its builder live, every item proven. */
function finishing(machine: string) {
  const f = factory({ machine, requires: null, worker: { role: "builder", agent: "claude", machine, session: SESSION, startedAt: 1 } });
  f.store.savePrivate("MF-1", { worktree: "~/.worktrees/factory/mf-1", repoDir: "~/factory", base: "main", finishing: false, restarts: 0 } as never);
  f.store.addSession({ id: SESSION, task: "MF-1", role: "builder", machine, agent: "claude", started: 1, ended: null, cause: null, kind: "personal" });
  const finish = async () => (await f.engine.fromRunner(machine, { type: "mcp.request", reqId: "r", session: SESSION, tool: "finish", args: { summary: "Done." } } as never)) as { result?: { summary: string }; error?: string };
  return { ...f, finish };
}

test("finish on the droplet sends only npm test and says it skipped the macos check; on the Mac both run, prefix stripped", async () => {
  const linux = finishing("droplet");
  const reply = await linux.finish();
  await linux.settle();
  const sentLinux = linux.sent.find((s) => s.body.type === "task.finish")!;
  assert.equal(sentLinux.to, "droplet");
  assert.equal(sentLinux.body.checks, "npm test");
  assert.match(String(reply.result?.summary), /1 check skipped on this machine \(needs macos\)/);

  const mac = finishing("mac");
  const macReply = await mac.finish();
  await mac.settle();
  assert.equal(mac.sent.find((s) => s.body.type === "task.finish")!.body.checks, "npm test\nxcodebuild test -scheme MapleFactory");
  assert.doesNotMatch(String(macReply.result?.summary), /skipped/);
});

test("the builder's prompt on the droplet lists the xcodebuild check as skipped (needs macos)", async () => {
  const f = factory({ requires: null });
  f.at("mac").online = false;
  await f.pump();
  const prompt = String(f.opened()[0].body.prompt);
  assert.match(prompt, /## Checks\nThese must exit 0[^]*- `npm test`/);
  assert.match(prompt, /Skipped on this machine: `xcodebuild test -scheme MapleFactory` \(needs macos\)/);
  assert.doesNotMatch(prompt, /- `\[macos\]/);

  const mac = factory({ requires: null });
  mac.at("droplet").online = false;
  await mac.pump();
  const onMac = String(mac.opened()[0].body.prompt);
  assert.match(onMac, /- `xcodebuild test -scheme MapleFactory`/);
  assert.doesNotMatch(onMac, /Skipped on this machine/);

  // Older callers pass a plain list.
  assert.match(builderPrompt(f.t(), null, null, null, [], null, ["npm test"]), /- `npm test`/);
});

test("parseCheck reads a leading [tag,…] prefix", () => {
  assert.deepEqual(parseCheck("npm test"), { command: "npm test", requires: [] });
  assert.deepEqual(parseCheck("[macos] xcodebuild test"), { command: "xcodebuild test", requires: ["macos"] });
  assert.deepEqual(parseCheck("  [xcode, macos,xcode]   xcodebuild test  "), { command: "xcodebuild test", requires: ["macos", "xcode"] });
  assert.match((parseCheck("[macos xcodebuild test") as { error: string }).error, /never closes it/);
  assert.match((parseCheck("[] npm test") as { error: string }).error, /empty \[ \]/);
  assert.match((parseCheck("[MacOS] xcodebuild") as { error: string }).error, /the tag "MacOS"; a tag is lowercase/);
  assert.match((parseCheck("[macos]") as { error: string }).error, /no command after them/);
});

test("checksFor splits the checks for a machine's tags", () => {
  const s = { checks: CHECKS };
  assert.deepEqual(checksFor(s, ["linux"]), { run: ["npm test"], skipped: [{ command: "xcodebuild test -scheme MapleFactory", missing: ["macos"] }] });
  assert.deepEqual(checksFor(s, ["macos", "xcode"]), { run: ["npm test", "xcodebuild test -scheme MapleFactory"], skipped: [] });
  assert.deepEqual(checksFor(null, ["macos"]), { run: [], skipped: [] });
});

test("scriptsProblem rejects bad prefixes and path rules, with a clear message; tidyScripts keeps them as typed", () => {
  assert.equal(scriptsProblem({ checks: CHECKS, requirePaths: "apps/mac/** macos" }), null);
  assert.match(String(scriptsProblem({ checks: "npm test\n[macos xcodebuild" })), /opens a \[ for its machine tags but never closes it/);
  assert.match(String(scriptsProblem({ checks: "[mac_os] xcodebuild" })), /the tag "mac_os"/);
  assert.match(String(scriptsProblem({ checks: "[ ] xcodebuild" })), /empty \[ \]/);
  assert.match(String(scriptsProblem({ requirePaths: "apps/mac/**" })), /should be a path and its tags/);
  assert.match(String(scriptsProblem({ requirePaths: "../other/** macos" })), /isn't inside the repo/);
  assert.match(String(scriptsProblem({ requirePaths: "apps/mac/** Mac" })), /the tag "Mac"/);
  assert.match(String(scriptsProblem({ requirePaths: Array.from({ length: 21 }, (_, i) => `a${i}/** macos`).join("\n") })), /at most 20 path rules/);
  assert.deepEqual(tidyScripts({ checks: "  [macos] xcodebuild test \n\n", requirePaths: " apps/mac/** macos \n" }), { checks: "[macos] xcodebuild test", requirePaths: "apps/mac/** macos" });
  assert.deepEqual(tidyScripts({ requirePaths: "apps/mac/** macos" }), { requirePaths: "apps/mac/** macos" });
});

test("requiresFor matches globs: **, *, and a bare folder", () => {
  const rules = pathRules({ requirePaths: "apps/mac/** macos\napps/ios macos,xcode\n*.xcodeproj xcode\nrunner/**/*.rs rust" });
  assert.deepEqual(requiresFor(["apps/mac/Sources/A.swift"], rules), ["macos"]);
  assert.deepEqual(requiresFor(["./apps/ios/App/Main.swift"], rules), ["macos", "xcode"]);
  assert.deepEqual(requiresFor(["apps/ios"], rules), ["macos", "xcode"]);
  assert.deepEqual(requiresFor(["apps/iosx/a"], rules), []);
  assert.deepEqual(requiresFor(["Maple.xcodeproj"], rules), ["xcode"]);
  assert.deepEqual(requiresFor(["runner/src/main.rs", "runner/main.rs"], rules), ["rust"]);
  assert.deepEqual(requiresFor(["server/src/x.ts", "apps/macintosh/x"], rules), []);
});

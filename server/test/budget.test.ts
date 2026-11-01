// A task's time and cost budget (policy.taskMinutes, taskCostUsd): budgetUse adds up its sessions' time and
// spend, and checkBudgets, through the engine on a node:sqlite store (as factory.test.ts does), types a nudge
// into a running task past it, then raises an overBudget hand itself if none comes 10 minutes on. Picking
// anything but Cancel on that hand gives the task one more budget's worth, counted from when it was answered.
import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { Engine } from "../src/factory/engine.ts";
import { Store } from "../src/factory/store.ts";
import { DEFAULT_POLICY, budgetUse, validPolicy } from "../src/factory/policy.ts";
import { builderPrompt } from "../src/factory/prompts.ts";
import type { RiskPolicy } from "../src/wire.ts";

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

const MIN = 60_000;
const T0 = 1_800_000_000_000;
const ME = { member: { login: "me", role: "member" } } as never;
const policy = (p: Partial<RiskPolicy> = {}): RiskPolicy => ({ ...structuredClone(DEFAULT_POLICY), ...p });

/** Pins Date.now to `clock.at` for `fn`. */
async function at<T>(clock: { at: number }, fn: () => Promise<T>): Promise<T> {
  const real = Date.now;
  Date.now = () => clock.at;
  try { return await fn(); } finally { Date.now = real; }
}

/** MF-1 building on `mac`, its builder session started `minutes` ago; what's typed into it is in `typed`. */
function factory(minutes: number, p: Partial<RiskPolicy> = {}, task: Record<string, unknown> = {}) {
  const store = new Store(sqlStorage());
  const typed: string[] = [];
  const commands: Record<string, unknown>[] = [];
  const wakes: number[] = [];
  /** Set `runner.down` to make the machine unreachable for commands. */
  const runner = { down: false };
  const hooks = {
    broadcast: () => {},
    sendTo: () => {},
    machines: async () => [{ id: "mac", sessions: [] }],
    members: async () => [],
    machineChanged: async () => {},
    waitUntil: () => {},
    wakeIn: (ms: number) => wakes.push(ms),
  };
  const MACHINE = {
    idFromName: (id: string) => id,
    get: () => ({
      fetch: async (url: string, init: RequestInit) => {
        if (url.endsWith("/input")) typed.push(JSON.parse(String(init.body)).text);
        if (url.endsWith("/command")) {
          if (runner.down) return new Response(null, { status: 503 });
          commands.push(JSON.parse(String(init.body)));
        }
        return new Response(null);
      },
    }),
  };
  const engine = new Engine({ MACHINE } as never, store, hooks as never, { forTask: () => {} } as never, {} as never);
  store.savePolicy(policy(p));
  store.saveGoal({ id: "g", name: "G", prefix: "FU", summary: "", lead: "me", repos: ["acme/app"], repo: "acme/app", archived: false } as never);
  const started = T0 - minutes * MIN;
  store.saveTask({
    id: "MF-1", goal: "g", title: "Prove it", state: "building", owner: "me", brief: "", createdAt: 1, updatedAt: 1, plan: [], planVersion: 1, doneWhen: [],
    approvals: [], approvalsNeeded: 1, reviews: [], reviewsNeeded: 1, comments: [], changes: [], events: [], mockups: [], tickets: [],
    shareable: false, agent: "claude", machine: "mac",
    worker: { role: "builder", agent: "claude", machine: "mac", session: "s1", startedAt: started },
    ...task,
  } as never);
  store.savePrivate("MF-1", { worktree: "~/w", repoDir: "~/app", base: "main", finishing: false, restarts: 0 });
  store.addSession({ id: "s1", task: "MF-1", role: "builder", machine: "mac", agent: "claude", started, ended: null, cause: null, kind: "personal" });
  const clock = { at: T0 };
  const check = () => at(clock, () => engine.checkBudgets());
  const t = () => store.task("MF-1")!;
  return { store, engine, typed, commands, wakes, clock, check, t, runner };
}

test("budgetUse adds up ended and live sessions' time and their costs, and a base moves the limit one budget on", () => {
  const sessions = [
    { started: T0 - 50 * MIN, ended: T0 - 30 * MIN }, // 20 min, ended
    { started: T0 - 25 * MIN, ended: null }, // 25 min, still running
  ];
  const costs = [{ costUsd: 1.5 }, { costUsd: null }, { costUsd: 2 }];
  const use = budgetUse(sessions, costs, policy({ taskMinutes: 60, taskCostUsd: 10 }), null, T0);
  assert.equal(use.minutes, 45);
  assert.equal(use.costUsd, 3.5);
  assert.equal(use.allowMinutes, 60);
  assert.equal(use.allowCostUsd, 10);
  assert.equal(use.over, null);

  assert.equal(budgetUse(sessions, costs, policy({ taskMinutes: 30 }), null, T0).over, "time");
  const base = { minutes: 40, costUsd: 3 };
  assert.equal(budgetUse(sessions, costs, policy({ taskMinutes: 30 }), base, T0).allowMinutes, 70);
  assert.equal(budgetUse(sessions, costs, policy({ taskMinutes: 30 }), base, T0).over, null);
  assert.equal(budgetUse(sessions, costs, policy({ taskCostUsd: 3 }), null, T0).over, "cost");
  assert.equal(budgetUse(sessions, costs, policy({ taskCostUsd: 3 }), base, T0).allowCostUsd, 6);
  assert.equal(budgetUse(sessions, costs, policy({ taskCostUsd: 3 }), base, T0).over, null);
  // None: 60 minutes and no cost limit; 0 minutes turns time off.
  const none = budgetUse(sessions, costs, policy({ taskMinutes: null, taskCostUsd: null }), null, T0);
  assert.equal(none.allowMinutes, 60);
  assert.equal(none.allowCostUsd, null);
  const off = budgetUse([{ started: 0, ended: null }], costs, policy({ taskMinutes: 0 }), null, T0);
  assert.equal(off.allowMinutes, null);
  assert.equal(off.over, null);
});

test("past its budget, a running task gets one nudge, and a factory hand 10 minutes on if it raised none", async () => {
  const f = factory(62);
  await f.check();
  assert.equal(f.typed.length, 1);
  assert.match(f.typed[0], /You've used 1 h 2 min of the 1 h budget for this task\. Stop at a safe point and call raise_hand with reason overBudget/);
  assert.ok(f.t().events.some((e) => e.who === "factory" && /^budget reached: 1 h 2 min of the 1 h budget/.test(e.text)));
  assert.equal(f.store.private("MF-1").budgetAskedAt, T0);
  assert.ok(f.store.statEvents().some((e) => e.kind === "budget.reached" && e.detail.over === "time"));
  assert.ok(f.wakes.includes(10 * MIN));
  assert.equal(f.t().hand ?? null, null);

  // Asked once: 9 minutes on, nothing more.
  f.clock.at = T0 + 9 * MIN;
  await f.check();
  assert.equal(f.typed.length, 1);
  assert.equal(f.t().hand ?? null, null);

  // 10 minutes on with no hand: the factory raises one.
  f.clock.at = T0 + 10 * MIN;
  await f.check();
  assert.equal(f.typed.length, 2);
  assert.match(f.typed[1], /the factory raised an overBudget hand for you\. Stop at a safe point now/);
  const hand = f.t().hand!;
  assert.equal(hand.reason, "overBudget");
  assert.deepEqual(hand.options.map((o) => o.title), ["Give it another hour", "Cancel it"]);
});

test("nothing happens within the budget, with it off, or while a hand or question is open", async () => {
  const within = factory(30);
  await within.check();
  assert.equal(within.typed.length, 0);
  assert.ok(within.wakes.includes(30 * MIN), "wakes when the budget runs out");

  const off = factory(500, { taskMinutes: 0 });
  await off.check();
  assert.equal(off.typed.length, 0);

  const hand = factory(90, {}, { hand: { reason: "needsInput", summary: "Which?", at: T0, assignee: "me", options: [] } });
  await hand.check();
  assert.equal(hand.typed.length, 0);
  assert.equal(hand.t().hand!.reason, "needsInput");

  const question = factory(90, {}, { question: { text: "Which?", options: [], role: "builder", at: T0 } });
  await question.check();
  assert.equal(question.typed.length, 0);

  const idle = factory(90, {}, { worker: null });
  await idle.check();
  assert.equal(idle.typed.length, 0);
});

test("a cost budget counts the sessions' reported spend", async () => {
  const f = factory(5, { taskCostUsd: 2 });
  await f.check();
  assert.equal(f.typed.length, 0);
  await at(f.clock, () => f.engine.fromRunner("mac", { type: "session.cost", cost: { session: "s1", agent: "claude", model: null, costUsd: 2.4, inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0 } } as never));
  assert.equal(f.typed.length, 1);
  assert.match(f.typed[0], /\$2\.40 of the \$2\.00 budget/);
});

test("Give it another hour on an overBudget hand moves the allowance on; the next limit is a budget later", async () => {
  const f = factory(62);
  await f.check();
  f.clock.at = T0 + 10 * MIN;
  await f.check();
  assert.equal(f.t().hand!.reason, "overBudget");
  await at(f.clock, () => f.engine.command({ type: "task.resolveHand", id: "MF-1", option: "Give it another hour", note: "" } as never, ME));
  assert.equal(f.t().hand ?? null, null);
  assert.deepEqual(f.store.private("MF-1").budgetBase, { minutes: 72, costUsd: 0 });
  assert.equal(f.store.private("MF-1").budgetAskedAt, null);
  assert.equal(f.engine.budget(f.t()).allowMinutes, 132);
  const typed = f.typed.length;

  // 72 minutes in: within the 132 it has now.
  await f.check();
  assert.equal(f.typed.length, typed);
  // Past 132: asked again.
  f.clock.at = T0 + 72 * MIN;
  await f.check();
  assert.equal(f.typed.length, typed + 1);
  assert.match(f.typed.at(-1)!, /2 h 14 min of the 2 h 12 min budget/);
});

test("answered after a long wait, the next budget starts from the answer, not from before the wait", async () => {
  const f = factory(62);
  await f.check();
  f.clock.at = T0 + 10 * MIN;
  await f.check();
  assert.equal(f.t().hand!.reason, "overBudget");
  // The owner answers 3 hours later; the session sat waiting the whole time.
  f.clock.at = T0 + 190 * MIN;
  await at(f.clock, () => f.engine.command({ type: "task.resolveHand", id: "MF-1", option: "Give it another hour", note: "" } as never, ME));
  const use = f.engine.budget(f.t());
  assert.equal(use.allowMinutes, 252 + 60);
  assert.equal(use.over, null);
  const typed = f.typed.length;
  await f.check();
  assert.equal(f.typed.length, typed, "no nudge right after the grant");
  assert.equal(f.t().hand ?? null, null);
  // An hour of work later: asked again.
  f.clock.at = T0 + 250 * MIN;
  await f.check();
  assert.equal(f.typed.length, typed + 1);
});

test("the agent's own budget hand after the nudge grants a budget unless it stops; size hands and others don't", async () => {
  const hand = (options: string[]) => ({ hand: { reason: "overBudget", summary: "Still proving it.", at: T0, assignee: "me", options: options.map((title) => ({ title, detail: "", recommended: false })) } });
  const pick = (f: ReturnType<typeof factory>, option: string) => at(f.clock, () => f.engine.command({ type: "task.resolveHand", id: "MF-1", option, note: "" } as never, ME));

  const nudged = factory(62, {}, hand(["Carry on", "Stop here"]));
  nudged.store.savePrivate("MF-1", { ...nudged.store.private("MF-1"), budgetAskedAt: T0 - MIN });
  await pick(nudged, "Carry on");
  assert.deepEqual(nudged.store.private("MF-1").budgetBase, { minutes: 62, costUsd: 0 });

  const stopped = factory(62, {}, hand(["Carry on", "Stop here"]));
  stopped.store.savePrivate("MF-1", { ...stopped.store.private("MF-1"), budgetAskedAt: T0 - MIN });
  await pick(stopped, "Stop here");
  assert.equal(stopped.store.private("MF-1").budgetBase, undefined);

  // A PR size-budget hand (no nudge was sent): picking a way forward gives no more time.
  const size = factory(20, {}, hand(["Split it", "Keep it whole"]));
  await pick(size, "Keep it whole");
  assert.equal(size.store.private("MF-1").budgetBase, undefined);

  const other = factory(62, {}, { hand: { reason: "needsInput", summary: "Which?", at: T0, assignee: "me", options: [{ title: "A", detail: "", recommended: true }] } });
  other.store.savePrivate("MF-1", { ...other.store.private("MF-1"), budgetAskedAt: T0 - MIN });
  await pick(other, "A");
  assert.equal(other.store.private("MF-1").budgetBase, undefined);
});

test("the builder's prompt says what's left of the budget and to ask before going past it", () => {
  const f = factory(20, { taskCostUsd: 5 });
  const p = builderPrompt(f.t(), null, null, null, [], null, [], budgetUse([{ started: T0 - 20 * MIN, ended: null }], [{ costUsd: 1 }], policy({ taskCostUsd: 5 }), null, T0));
  assert.match(p, /## Budget\nThis task has 40 of its 60 minutes of agent time and \$4\.00 of its \$5\.00 left/);
  assert.match(p, /call `raise_hand` with reason `overBudget`/);
  assert.doesNotMatch(builderPrompt(f.t(), null, null, null, [], null, [], budgetUse([], [], policy({ taskMinutes: 0 }), null, T0)), /## Budget/);
});

test("validPolicy takes 0 or 5–1440 minutes and a cost of $0 or more", () => {
  assert.equal(validPolicy(policy({ taskMinutes: 0 })), null);
  assert.equal(validPolicy(policy({ taskMinutes: 5 })), null);
  assert.equal(validPolicy(policy({ taskMinutes: 1440, taskCostUsd: 0 })), null);
  assert.equal(validPolicy(policy({ taskMinutes: null, taskCostUsd: null })), null);
  for (const taskMinutes of [3, 1441, 30.5, -1]) assert.match(validPolicy(policy({ taskMinutes }))!, /5 to 1440 minutes/, String(taskMinutes));
  for (const taskCostUsd of [-1, NaN, Infinity]) assert.match(validPolicy(policy({ taskCostUsd }))!, /below \$0/, String(taskCostUsd));
});

// Over budget with the policy's "handOff" (MF-306): the agent is asked to say where it is, the factory pushes its
// work (`task.handoff`), files a draft follow-up for a person to review, and cancels it with its branch kept.
const HANDOFF_PLAN = {
  brief: "Make the thing faster.",
  plan: [
    { text: "Profile it", file: "a.ts", progress: "done", added: false },
    { text: "Cache the lookups", file: "b.ts", progress: "active", added: false },
  ],
  doneWhen: [{ text: "It's faster", proof: "tests", status: "proven", evidence: { kind: "tests", summary: "bench: 2x" } }],
};
const tick = () => new Promise((r) => setImmediate(r));
const raiseHand = (f: ReturnType<typeof factory>, summary: string) => at(f.clock, () => f.engine.fromRunner("mac", {
  type: "mcp.request", session: "s1", tool: "raise_hand", args: { reason: "overBudget", summary, options: [] },
} as never));
const followUps = (f: ReturnType<typeof factory>) => f.store.tasks().filter((t) => t.followUpOf === "MF-1");

test("handOff: the nudge, then task.handoff once its hand comes, then a follow-up draft and the original cancelled", async () => {
  const f = factory(62, { overBudget: "handOff" }, HANDOFF_PLAN);
  await f.check();
  assert.equal(f.typed.length, 1);
  assert.match(f.typed[0], /being handed off for a person to review\. Don't commit anything; stop at a safe point and call raise_hand with reason overBudget/);
  assert.equal(f.t().hand ?? null, null);

  const reply = await raiseHand(f, "Profiled it; the cache is half done and its tests flake.");
  assert.match(JSON.stringify(reply), /pushing your work and filing a follow-up/);
  assert.equal(f.t().hand ?? null, null, "nobody is asked");
  const handoff = f.commands.find((c) => c.type === "task.handoff")!;
  assert.ok(handoff, "the runner is asked to push");
  assert.equal(handoff.branch, "agent/mf-1");
  assert.equal(followUps(f).length, 0, "nothing filed before the push");

  await at(f.clock, () => f.engine.fromRunner("mac", { type: "task.handed_off", taskId: "MF-1", ok: true, pushed: "agent/mf-1", commit: "abc1234def" } as never));
  await tick();
  const [draft] = followUps(f);
  assert.equal(followUps(f).length, 1);
  assert.equal(draft.state, "drafting");
  assert.equal(draft.title, "Continue MF-1: Prove it");
  assert.match(draft.brief, /`agent\/mf-1` at abc1234/);
  assert.match(draft.brief, /## Budget used\n1 h 2 min of the 1 h budget/);
  assert.match(draft.brief, /Profiled it; the cache is half done and its tests flake\./);
  assert.match(draft.brief, /1 of 2 plan steps not done/);
  assert.match(draft.brief, /1\. \[x\] Profile it\n2\. \[ \] Cache the lookups \(in progress\)/);
  assert.match(draft.brief, /1\. \[x\] It's faster — bench: 2x/);
  assert.match(draft.brief, /## The original brief\nMake the thing faster\./);
  assert.equal(f.t().state, "cancelled");
  assert.ok(f.t().events.some((e) => e.text === `handed it off over budget to ${draft.id}; its branch stays`));
  assert.ok(f.store.statEvents().some((e) => e.kind === "budget.handedOff" && e.detail.followUp === draft.id && e.detail.commit === "abc1234def"));
  assert.equal(f.store.private("MF-1").budgetHandOff, null);
});

test("handOff: with no hand 10 minutes on, the factory hands it off itself", async () => {
  const f = factory(62, { overBudget: "handOff" }, HANDOFF_PLAN);
  await f.check();
  f.clock.at = T0 + 10 * MIN;
  await f.check();
  assert.equal(f.t().hand ?? null, null);
  assert.ok(f.commands.some((c) => c.type === "task.handoff"));
  await at(f.clock, () => f.engine.fromRunner("mac", { type: "task.handed_off", taskId: "MF-1", ok: true, commit: "abc1234def" } as never));
  await tick();
  assert.match(followUps(f)[0].brief, /the factory stepped in/);
  assert.equal(f.t().state, "cancelled");
});

test("handOff: a failed push raises an overBudget hand instead, and files nothing", async () => {
  const f = factory(62, { overBudget: "handOff" }, HANDOFF_PLAN);
  await f.check();
  await raiseHand(f, "Half done.");
  await at(f.clock, () => f.engine.fromRunner("mac", { type: "task.handed_off", taskId: "MF-1", ok: false, message: "push rejected" } as never));
  await tick();
  assert.equal(followUps(f).length, 0);
  assert.equal(f.t().state, "building");
  const hand = f.t().hand!;
  assert.equal(hand.reason, "overBudget");
  assert.match(hand.summary, /pushing its work failed \(push rejected\).*Half done\./);
  assert.deepEqual(hand.options.map((o) => o.title), ["Give it more budget", "Cancel it"]);
  // Giving it more still works as for any budget hand.
  await at(f.clock, () => f.engine.command({ type: "task.resolveHand", id: "MF-1", option: "Give it more budget", note: "" } as never, ME));
  assert.deepEqual(f.store.private("MF-1").budgetBase, { minutes: 62, costUsd: 0 });
});

test("handOff: a planning task with no worktree goes straight to a draft and is cancelled", async () => {
  const f = factory(62, { overBudget: "handOff" }, { state: "planning", worker: { role: "planner", agent: "claude", machine: "mac", session: "s1", startedAt: T0 - 62 * MIN } });
  await f.check();
  await raiseHand(f, "The codebase is bigger than the brief thought.");
  await tick();
  assert.ok(!f.commands.some((c) => c.type === "task.handoff"), "nothing to push");
  const [draft] = followUps(f);
  assert.match(draft.brief, /Nothing was pushed: it was handed off while planning/);
  assert.match(draft.brief, /bigger than the brief thought/);
  assert.equal(f.t().state, "cancelled");
});

test("handOff: with its machine out of reach, the worktree's work isn't cancelled away; an overBudget hand instead", async () => {
  const f = factory(62, { overBudget: "handOff" }, HANDOFF_PLAN);
  await f.check();
  f.runner.down = true;
  await raiseHand(f, "Half done.");
  await tick();
  assert.equal(followUps(f).length, 0, "nothing filed");
  assert.equal(f.t().state, "building", "not cancelled");
  assert.ok(f.t().worker, "its worker stays");
  const hand = f.t().hand!;
  assert.equal(hand.reason, "overBudget");
  assert.match(hand.summary, /couldn't be handed off: its machine \(mac\) couldn't be reached to push its work\..*Half done\./);
  assert.equal(f.store.private("MF-1").budgetHandOff, null);
  assert.equal(f.store.private("MF-1").worktree, "~/w");
});

test("handOff: a second hand while the push is in flight sends no second task.handoff", async () => {
  const f = factory(62, { overBudget: "handOff" }, HANDOFF_PLAN);
  await f.check();
  f.clock.at = T0 + 10 * MIN;
  await f.check(); // the factory steps in and pushes
  await raiseHand(f, "Late word.");
  await at(f.clock, () => f.engine.fromRunner("mac", { type: "mcp.request", session: "s1", tool: "raise_hand", args: { reason: "blocked", summary: "x", options: [] } } as never));
  assert.equal(f.commands.filter((c) => c.type === "task.handoff").length, 1);
});

test("handOff: nothing to carry files a draft that says nothing was pushed, not that work is on a branch", async () => {
  const f = factory(62, { overBudget: "handOff" }, HANDOFF_PLAN);
  await f.check();
  await raiseHand(f, "Didn't get anywhere.");
  await at(f.clock, () => f.engine.fromRunner("mac", { type: "task.handed_off", taskId: "MF-1", ok: false, message: "nothing to carry" } as never));
  await tick();
  const [draft] = followUps(f);
  assert.match(draft.brief, /Nothing was pushed: it had no changes to carry/);
  assert.doesNotMatch(draft.brief, /Its work is on/);
  assert.equal(f.t().state, "cancelled");
});

test("handOff: pushed, but its goal is archived: the hand says the work was pushed, not that the push failed", async () => {
  const f = factory(62, { overBudget: "handOff" }, HANDOFF_PLAN);
  await f.check();
  await raiseHand(f, "Half done.");
  f.store.saveGoal({ ...f.store.goal("g")!, archived: true });
  await at(f.clock, () => f.engine.fromRunner("mac", { type: "task.handed_off", taskId: "MF-1", ok: true, commit: "abc1234def" } as never));
  await tick();
  assert.equal(followUps(f).length, 0);
  const hand = f.t().hand!;
  assert.match(hand.summary, /its work was pushed \(abc1234\), but no follow-up could be filed, since G is archived/);
  assert.doesNotMatch(hand.summary, /pushing its work failed/);
});

test("ask mode is unchanged: the agent's overBudget hand is raised for a person", async () => {
  const f = factory(62, { overBudget: "ask" });
  await f.check();
  assert.match(f.typed[0], /the options \(carry on, cut the scope, or stop\)/);
  await raiseHand(f, "Half done.");
  assert.equal(f.t().hand!.reason, "overBudget");
  assert.ok(!f.commands.some((c) => c.type === "task.handoff"));
  assert.equal(followUps(f).length, 0);
});

test("validPolicy takes ask, handOff or none for overBudget, and nothing else", () => {
  for (const overBudget of ["ask", "handOff", null]) assert.equal(validPolicy(policy({ overBudget })), null, String(overBudget));
  for (const overBudget of ["push", "", "HANDOFF"]) assert.match(validPolicy(policy({ overBudget }))!, /asks or hands off/, overBudget);
});

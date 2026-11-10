// MF-366: ask an agent from a doc selection. The pure pieces (machine choice and refusals, the prompt, status
// mapping, budget), then the engine on a node:sqlite store with DocHub and MachineHub stand-ins: an ask opens a
// session, its tools are the doc tools only, a reply is typed into a live ask, Stop kills it, and the budget sweep
// kills one that ran too long.
import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import * as Y from "yjs";
import { readDoc, anchorFor, applySuggestion, seedDoc, DocToolError } from "../docs-editor/src/headless.js";
import { Engine } from "../src/factory/engine.ts";
import { Store } from "../src/factory/store.ts";
import * as asks from "../src/factory/doc-asks.ts";
import { agentsIn, docAgentsIn } from "../src/factory/mentions.ts";
import { newThread } from "../src/factory/doc-threads.ts";
import { DEFAULT_POLICY } from "../src/factory/policy.ts";
import type { DocThread, Machine } from "../src/wire.ts";

const DOC = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const MD = "# Launch plan\n\nWe ship on **Friday** and then celebrate.\n";

const mac = (over: Partial<Machine> = {}): Machine => ({ id: "mac", name: "studio", owner: "sam", online: true, sessions: [], ...over }) as Machine;
const deps = (over: Partial<asks.PickDeps> = {}): asks.PickDeps => ({ paused: () => false, hasAgent: () => true, overCap: () => null, lends: () => false, busy: () => 0, ...over });

test("pickMachine: own least-busy machine first, then a lent one", () => {
  const a = mac({ id: "a", name: "a" }), b = mac({ id: "b", name: "b" }), t = mac({ id: "t", name: "team", owner: "kim" });
  const busy = (m: Machine) => (m.id === "a" ? 2 : 0);
  assert.equal((asks.pickMachine([a, b, t], "sam", "claude", deps({ busy })) as asks.Pick).machine.id, "b");
  const lent = asks.pickMachine([t], "sam", "claude", deps({ lends: () => true })) as asks.Pick;
  assert.equal(lent.machine.id, "t");
  assert.equal(lent.kind, "team");
});

test("pickMachine refusals: paused, over cap, no agent, offline, none", () => {
  const m = mac();
  assert.match(asks.pickMachine([m], "sam", "claude", deps({ paused: () => true })) as string, /studio\) are paused.*No agent was started/);
  assert.match(asks.pickMachine([m], "sam", "claude", deps({ overCap: () => "studio's claude account has used 96% of its week (the cap is 90%)." })) as string, /96% of its week.*No agent was started/);
  assert.match(asks.pickMachine([m], "sam", "claude", deps({ hasAgent: () => false })) as string, /has claude installed/);
  assert.match(asks.pickMachine([mac({ online: false })], "sam", "claude", deps()) as string, /offline/);
  assert.match(asks.pickMachine([], "sam", "claude", deps()) as string, /no machines/);
});

test("prompt carries the doc, the quote, the thread, the repo and the doc-tools-only rule", () => {
  const t = newThread(DOC, "sam", "Is Friday right?", { from: "AA==", to: "AA==", quote: "We ship on Friday" }, []);
  const p = asks.askPrompt({ doc: { id: DOC, title: "Launch plan" }, markdown: "# Launch plan\n\nWe ship on Friday", thread: t, role: "researcher", by: "sam", repo: "acme/app", goal: "Apps" });
  for (const want of ["Launch plan", "> We ship on Friday", "sam: Is Friday right?", "acme/app", "reply_to_doc_thread", "suggest_doc_edit", "mermaid", "Never edit", t.id, "researcher"]) assert.ok(p.includes(want), want);
  assert.match(asks.askPrompt({ doc: { id: DOC, title: "x" }, markdown: null, thread: t, role: "planner", by: "sam", repo: null, goal: null }), /isn't in a goal with a repo/);
});

test("status mapping, live, budget and per-member limit", () => {
  assert.equal(asks.statusFor("working", "Reading src/app.ts"), "working");
  assert.equal(asks.statusFor("working", null), "thinking");
  assert.equal(asks.statusFor("waiting", "Allow?"), "waiting");
  assert.equal(asks.statusFor("done", null), "done");
  assert.equal(asks.statusFor("idle", null), "thinking");
  assert.equal(asks.live({ status: "thinking" } as never), true);
  assert.equal(asks.live({ status: "done" } as never), false);
  const r = { startedAt: 0, costUsd: 0, by: "sam", ended: false } as asks.AskRecord;
  assert.equal(asks.overBudget(r, { minutes: 10, costUsd: null }, 9 * 60_000), null);
  assert.equal(asks.overBudget(r, { minutes: 10, costUsd: null }, 10 * 60_000), "time");
  assert.equal(asks.overBudget({ ...r, costUsd: 3 }, { minutes: null, costUsd: 2 }), "cost");
  assert.match(asks.overLimit([r, r, r], "sam")!, /already have 3/);
  assert.equal(asks.overLimit([r, { ...r, ended: true }], "sam"), null);
  assert.equal(asks.overLimit([r, r, { ...r, idleSince: 5 }], "sam"), null);
});

test("docAgentsIn: @planner and @researcher in docs only; task comments keep their roles", () => {
  assert.deepEqual(docAgentsIn("@researcher and @Planner, @builder"), ["researcher", "planner"]);
  assert.deepEqual(agentsIn("@researcher @planner"), ["planner"]);
});

// ---------------------------------------------------------------------------------------------------------------
// Through the engine

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

function factory(machines: Machine[] = [mac()]) {
  const ydoc = seedDoc(new Y.Doc(), MD);
  const DOC_NS = {
    idFromName: (id: string) => id,
    get: () => ({
      fetch: async (url: string, init: RequestInit) => {
        const path = new URL(url).pathname;
        const body = JSON.parse(String(init.body));
        try {
          if (path === "/read") return Response.json(readDoc(ydoc, body.threads));
          if (path === "/anchor") return Response.json(anchorFor(ydoc, body));
          if (path === "/apply") return Response.json({ before: applySuggestion(ydoc, body.anchor, body.markdown).before });
          return new Response("Not found.", { status: 404 });
        } catch (e) {
          if (e instanceof DocToolError) return new Response(e.message, { status: 422 });
          throw e;
        }
      },
    }),
  };
  const commands: any[] = [], inputs: any[] = [];
  const MACHINE = {
    idFromName: (id: string) => id,
    get: (id: string) => ({
      fetch: async (url: string, init: RequestInit) => {
        const body = JSON.parse(String(init.body));
        if (url.endsWith("/command")) commands.push({ machine: id, ...body });
        if (url.endsWith("/input")) inputs.push({ machine: id, ...body });
        return new Response("ok");
      },
    }),
  };
  const store = new Store(sqlStorage());
  const broadcasts: any[] = [];
  const hooks = {
    broadcast: (m: any) => broadcasts.push(m), sendTo: () => {}, machines: async () => machines,
    members: async () => [{ login: "sam" }, { login: "kim" }], machineChanged: async () => {}, waitUntil: () => {}, wakeIn: () => {}, docMentions: () => {},
  };
  const engine = new Engine({ DOC: DOC_NS, MACHINE } as never, store, hooks as never, { forTask: () => {} } as never, {} as never);
  store.saveGoal({ id: "g", name: "Apps", prefix: "MF", summary: "", lead: "sam", repos: ["acme/app"], repo: "acme/app", archived: false } as never);
  store.saveDoc({ id: DOC, title: "Launch plan", goal: "g", createdBy: "sam", createdAt: 1, updatedAt: 1, archived: null } as never);
  const thread = newThread(DOC, "sam", "Is Friday right?", anchorFor(ydoc, { quote: "We ship on Friday and then celebrate." }), []);
  store.saveThread(thread);
  const call = async (session: string, tool: string, args: Record<string, unknown>) =>
    (await engine.fromRunner("mac", { type: "mcp.request", reqId: "r", session, tool, args } as never)) as { result?: { summary: string; data: any }; error?: string };
  return { store, engine, thread, commands, inputs, broadcasts, call, ydoc };
}

test("ask opens a session with the doc prompt in the goal's repo and marks the thread starting", async () => {
  const { engine, store, thread, commands, broadcasts } = factory();
  const t = await engine.ask("sam", thread.id, "planner");
  const open = commands.find((c) => c.type === "session.open");
  assert.ok(open);
  assert.equal(open.taskId, null);
  assert.match(open.worktree.name, /^ask-[0-9a-f]{8}$/);
  assert.equal(open.task.repo, "acme/app");
  assert.match(open.prompt, /We ship on Friday/);
  assert.match(open.prompt, /We ship on \*\*Friday\*\* and then celebrate/);
  assert.equal(t.agent!.status, "starting");
  assert.equal(store.thread(thread.id)!.agent!.session, open.id);
  assert.ok(broadcasts.some((b) => b.type === "doc.thread.updated" && b.thread.agent?.status === "starting"));
  await assert.rejects(engine.ask("sam", thread.id, "planner"), /already working in this thread/);
});

test("a refusal when every machine is paused or over its cap opens no session", async () => {
  for (const setup of ["paused", "capped"]) {
    const m = mac(setup === "capped" ? { usage: [{ agent: "claude", windows: [{ label: "7d", usedPercent: 97 }] }] } as never : {});
    const { engine, store, thread, commands } = factory([m]);
    if (setup === "paused") store.saveSettings("mac", { ...store.settings("mac"), paused: true });
    else store.saveSettings("mac", { ...store.settings("mac"), weeklyCap: 0.9 });
    await assert.rejects(engine.ask("sam", thread.id, "planner"), setup === "paused" ? /paused.*No agent was started/ : /97% of its week.*No agent was started/);
    assert.equal(commands.length, 0);
    assert.equal(store.thread(thread.id)!.agent ?? null, null);
  }
});

test("an ask session gets the doc tools only, as the asker's agent; its answer and suggestion land in the thread", async () => {
  const { engine, store, thread, commands, call, ydoc } = factory();
  await engine.ask("sam", thread.id, "researcher");
  const session = commands[0].id;
  const list = await call(session, "tools/list", {});
  const names = list.result!.data.tools.map((t: any) => t.name);
  assert.ok(names.includes("reply_to_doc_thread") && names.includes("suggest_doc_edit"));
  assert.ok(!names.includes("submit_plan") && !names.includes("save_repo_setup"));
  assert.match((await call(session, "submit_plan", {})).error!, /isn't available to an agent asked from a doc/);
  assert.match((await call(session, "save_repo_setup", { repo: "acme/app" })).error!, /isn't available/);
  const reply = await call(session, "reply_to_doc_thread", { doc: DOC, thread: thread.id, text: "Friday is a freeze day; Monday is safer." });
  assert.equal(reply.error, undefined, reply.error);
  assert.equal(store.thread(thread.id)!.comments.at(-1)!.agent, "researcher for @sam");
  const s = await call(session, "suggest_doc_edit", { doc: DOC, quote: "Friday", replacement: "Monday" });
  assert.equal(s.error, undefined, s.error);
  await engine.docs.decide("sam", DOC, s.result!.data.thread, true);
  assert.match(readDoc(ydoc).markdown, /We ship on Monday and then celebrate/);
});

test("activity drives the chip; a reply is typed into the live ask; once done a reply needs a fresh run", async () => {
  const { engine, store, thread, commands, inputs } = factory();
  await engine.ask("sam", thread.id, "planner");
  const session = commands[0].id;
  await engine.fromRunner("mac", { type: "session.activity", id: session, activity: { state: "working", message: null, at: 1 } } as never);
  assert.equal(store.thread(thread.id)!.agent!.status, "thinking");
  await engine.fromRunner("mac", { type: "session.activity", id: session, activity: { state: "working", step: "Reading src/ship.ts", at: 2 } } as never);
  assert.equal(store.thread(thread.id)!.agent!.status, "working");
  assert.equal(store.thread(thread.id)!.agent!.message, "Reading src/ship.ts");

  assert.equal(await engine.typeIntoAsk(store.thread(thread.id)!, "kim", "What about Thursday?"), true);
  assert.equal(inputs[0].session, session);
  assert.match(inputs[0].text, /^kim in doc thread .*What about Thursday\?.*reply_to_doc_thread/s);

  await engine.fromRunner("mac", { type: "session.ended", end: { id: session, cause: "exited", at: 3 } } as never);
  assert.equal(store.thread(thread.id)!.agent!.status, "done");
  assert.equal(await engine.typeIntoAsk(store.thread(thread.id)!, "kim", "And Tuesday?"), false);
  assert.equal(inputs.length, 1);
  await engine.ask("sam", thread.id, "researcher");
  const second = commands.filter((c) => c.type === "session.open");
  assert.equal(second.length, 2);
  assert.match(second[1].prompt, /sam: Is Friday right\?/);
  assert.equal(store.thread(thread.id)!.agent!.role, "researcher");
  assert.equal(store.thread(thread.id)!.agent!.status, "starting");
});

test("Stop: the asker, the machine owner or an admin; it kills the session and marks it stopped", async () => {
  const { engine, store, thread, commands } = factory([mac({ owner: "kim" })]);
  store.saveSettings("mac", { ...store.settings("mac"), teamSlots: 2, lendIdle: true });
  await engine.ask("sam", thread.id, "planner");
  await assert.rejects(engine.stopAsk("lee", false, thread.id), /Only who asked/);
  await engine.stopAsk("kim", false, thread.id);
  const kill = commands.find((c) => c.type === "session.kill");
  assert.equal(kill.id, commands[0].id);
  assert.equal(store.thread(thread.id)!.agent!.status, "stopped");
  assert.match(store.thread(thread.id)!.agent!.message!, /Stopped by kim/);
  await assert.rejects(engine.stopAsk("sam", false, thread.id), /No agent is running/);
});

test("the budget sweep kills an ask past policy minutes and says so in the thread", async () => {
  const { engine, store, thread, commands } = factory();
  store.savePolicy({ ...DEFAULT_POLICY, taskMinutes: 10 });
  const t = await engine.ask("sam", thread.id, "planner");
  await engine.checkAskBudgets(t.agent!.startedAt + 5 * 60_000);
  assert.equal(commands.filter((c) => c.type === "session.kill").length, 0);
  await engine.checkAskBudgets(t.agent!.startedAt + 11 * 60_000);
  assert.equal(commands.filter((c) => c.type === "session.kill").length, 1);
  const after = store.thread(thread.id)!;
  assert.equal(after.agent!.status, "stopped");
  assert.match(after.comments.at(-1)!.text, /stopped because it ran past 10 min/);
  assert.equal(engine.liveAsks().length, 0);
});

test("an answered ask turns Done without the session ending, stops counting, takes follow-ups, and closes after the grace", async () => {
  const { engine, store, thread, commands, inputs, call } = factory();
  store.savePolicy({ ...DEFAULT_POLICY, taskMinutes: 10 });
  const t = await engine.ask("sam", thread.id, "planner");
  const session = commands[0].id, start = t.agent!.startedAt;
  await engine.fromRunner("mac", { type: "session.activity", id: session, activity: { state: "working", message: null, at: 1 } } as never);
  await call(session, "reply_to_doc_thread", { doc: DOC, thread: thread.id, text: "Friday works." });
  await engine.fromRunner("mac", { type: "session.activity", id: session, activity: { state: "done", message: null, at: 2 } } as never);
  assert.equal(store.thread(thread.id)!.agent!.status, "done");
  assert.equal(engine.liveAsks().length, 0, "an answered ask isn't counted as running");
  // No budget note for an answered thread, however long it sits.
  await engine.checkAskBudgets(start + 11 * 60_000);
  assert.equal(commands.filter((c) => c.type === "session.kill").length, 0);
  assert.ok(!store.thread(thread.id)!.comments.some((c) => /stopped because/.test(c.text)));
  // A follow-up is typed into the still-open session and turns it back to Thinking.
  assert.equal(await engine.typeIntoAsk(store.thread(thread.id)!, "kim", "And Thursday?"), true);
  assert.equal(inputs.at(-1).session, session);
  assert.equal(store.thread(thread.id)!.agent!.status, "thinking");
  assert.equal(engine.liveAsks().length, 1);
  // A late 'done' from the previous turn, before the runner picks up the typed input, is ignored.
  await engine.fromRunner("mac", { type: "session.activity", id: session, activity: { state: "done", message: null, at: 3 } } as never);
  assert.equal(store.thread(thread.id)!.agent!.status, "thinking");
  await engine.fromRunner("mac", { type: "session.activity", id: session, activity: { state: "working", message: null, at: 4 } } as never);
  await call(session, "reply_to_doc_thread", { doc: DOC, thread: thread.id, text: "Thursday works too." });
  await engine.fromRunner("mac", { type: "session.activity", id: session, activity: { state: "done", message: null, at: 5 } } as never);
  assert.equal(store.thread(thread.id)!.agent!.status, "done");
  // Quiet past the grace period: the session is closed, the thread keeps Done, and a reply no longer types in.
  await engine.checkAskBudgets(Date.now() + asks.IDLE_GRACE_MS + 1000);
  const kills = commands.filter((c) => c.type === "session.kill");
  assert.equal(kills.length, 1);
  assert.equal(kills[0].id, session);
  assert.equal(store.thread(thread.id)!.agent!.status, "done");
  assert.equal(await engine.typeIntoAsk(store.thread(thread.id)!, "kim", "Tuesday?"), false);
});

test("a turn that ends without writing in the doc shows Waiting, not Done; it still closes after the grace", async () => {
  const { engine, store, thread, commands, inputs, call } = factory();
  await engine.ask("sam", thread.id, "planner");
  const session = commands[0].id;
  await engine.fromRunner("mac", { type: "session.activity", id: session, activity: { state: "working", message: null, at: 1 } } as never);
  await engine.fromRunner("mac", { type: "session.activity", id: session, activity: { state: "done", message: null, at: 2 } } as never);
  const run = store.thread(thread.id)!.agent!;
  assert.equal(run.status, "waiting");
  assert.match(run.message!, /without a reply/);
  assert.equal(engine.liveAsks().length, 0, "it's idle, so it doesn't count as running");
  // A reply nudges it; a turn that answers in the thread then shows Done. The first turn's reply doesn't count for the next.
  assert.equal(await engine.typeIntoAsk(store.thread(thread.id)!, "sam", "Answer in the thread please"), true);
  assert.equal(inputs.length, 1);
  assert.equal(store.thread(thread.id)!.agent!.status, "thinking");
  await engine.fromRunner("mac", { type: "session.activity", id: session, activity: { state: "working", message: null, at: 3 } } as never);
  await call(session, "reply_to_doc_thread", { doc: DOC, thread: thread.id, text: "Friday is fine." });
  await engine.fromRunner("mac", { type: "session.activity", id: session, activity: { state: "done", message: null, at: 4 } } as never);
  assert.equal(store.thread(thread.id)!.agent!.status, "done");
  // A Waiting ask that's closed after the grace doesn't stay live.
  const t2 = newThread(DOC, "sam", "And the venue?", null as never, []);
  store.saveThread(t2);
  await engine.ask("sam", t2.id, "planner");
  const s2 = commands.filter((c) => c.type === "session.open")[1].id;
  await engine.fromRunner("mac", { type: "session.activity", id: s2, activity: { state: "done", message: null, at: 5 } } as never);
  assert.equal(store.thread(t2.id)!.agent!.status, "waiting");
  await engine.checkAskBudgets(Date.now() + asks.IDLE_GRACE_MS + 1000);
  assert.equal(store.thread(t2.id)!.agent!.status, "done");
});

test("answered asks whose session is still open count toward machine load", async () => {
  const { engine, store, thread, commands, call } = factory([mac({ id: "a", name: "a" }), mac({ id: "b", name: "b" })]);
  await engine.ask("sam", thread.id, "planner");
  const first = commands[0];
  await call(first.id, "reply_to_doc_thread", { doc: DOC, thread: thread.id, text: "Yes." });
  await engine.fromRunner(first.machine, { type: "session.activity", id: first.id, activity: { state: "done", message: null, at: 2 } } as never);
  assert.equal(store.thread(thread.id)!.agent!.status, "done");
  const pick = await engine.askPreflight("sam");
  assert.notEqual(pick.machine.id, first.machine, "the machine holding the open, answered session is busier");
});

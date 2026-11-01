// @Maple in Slack, through the Worker's handlers (slack.ts) and the engine on a node:sqlite store (as
// scout.test.ts does): signatures and timestamps, url_verification, retries, a mention answered in its
// thread by a runner's agent, the proposed task's Create task, a channel's goals, /maple's thread, and the manifest.
// Slack's Web API and its files are a mocked fetch; OrgHub is a fake that routes to the engine.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { DatabaseSync } from "node:sqlite";
import { Engine } from "../src/factory/engine.ts";
import { Intake } from "../src/factory/intake.ts";
import { ARCHIVED_NOTE, parseAnswer } from "../src/factory/slack-asks.ts";
import { Store } from "../src/factory/store.ts";
import { deliver } from "../src/trackers.ts";
import { slackActions, slackCommand, slackEvents, wantsGoals } from "../src/slack.ts";
import { manifest, merged, definition, slackSetupUrl, SLACK_SCOPES } from "../src/integrations/registry.ts";
import type { Goal, ServerToRunner } from "../src/wire.ts";
import { d1 } from "./d1.ts";
import { linkApi } from "../src/slack-links.ts";

const SECRET = "slack-signing-secret";
const TOKEN = "xoxb-test-token";

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

const goal = (id: string, f: Partial<Goal> = {}): Goal => ({ id, name: id === "web" ? "Website" : "Mobile app", prefix: id === "web" ? "WEB" : "MOB", color: "blue", summary: id === "web" ? "The marketing website and its export page" : "The iPhone app", lead: "me", repos: [`acme/${id}`], repo: `acme/${id}`, archived: false, ...f });

type Call = { url: string; method: string; body: any };

/** A factory with two goals and one online machine, a fake OrgHub in front of its engine, and Slack mocked. */
function factory(opts: { config?: Record<string, string> | null; db?: D1Database } = {}) {
  const store = new Store(sqlStorage());
  store.saveGoal(goal("web"));
  store.saveGoal(goal("mob"));
  const sent: ServerToRunner[] = [];
  const r2 = new Map<string, { body: Uint8Array; type: string }>();
  const events: (string | null)[] = [];
  const config = opts.config === undefined ? { signingSecret: SECRET, botToken: TOKEN } : opts.config;
  const later: Promise<unknown>[] = [];
  const asks: any[] = [];
  const env: any = {
    DB: opts.db ?? { prepare: () => ({ bind: () => ({ run: async () => {} }) }) },
    MACHINE: { idFromName: (n: string) => n, get: () => ({ fetch: async (_: string, init: { body: string }) => (sent.push(JSON.parse(init.body)), new Response("ok")) }) },
    RELEASES: {
      put: async (key: string, body: Uint8Array, o: { httpMetadata: { contentType: string } }) => void r2.set(key, { body, type: o.httpMetadata.contentType }),
      delete: async (keys: string | string[]) => void [keys].flat().forEach((k) => r2.delete(k)),
    },
  };
  const access = { config: async () => config, event: async (_: unknown, e?: string) => void events.push(e ?? null) };
  const intake = new Intake(store, { broadcast: () => {}, waitUntil: (p) => void later.push(p), deliver: (url, said) => deliver(env, url, said, access as never) });
  const machine = { id: "m1", name: "m1", owner: "me", online: true, health: null, sessions: [] };
  const hooks = {
    broadcast: () => {}, sendTo: () => {}, machines: async () => [machine], members: async () => [], machineChanged: async () => {}, waitUntil: (p: Promise<unknown>) => void later.push(p), wakeIn: () => {},
    slack: { token: async () => config?.botToken ?? null, problem: (e: string) => void events.push(e) },
  };
  const engine = new Engine(env, store, hooks as never, intake, {} as never);
  // OrgHub's routes, as org-hub.ts has them.
  env.ORG = {
    idFromName: () => "org",
    get: () => ({
      fetch: async (url: string, init: { body?: string } = {}) => {
        const path = new URL(url).pathname;
        const body = init.body ? JSON.parse(init.body) : null;
        if (path === "/integrations/slack/config") return Response.json(config);
        if (path === "/integrations/slack/event") return events.push(body.error), new Response(null, { status: 204 });
        if (path === "/slack/seen") return Response.json({ seen: engine.slack.seen(body.id) });
        if (path === "/slack/ask") asks.push(body), await engine.slack.ask(body);
        if (path === "/slack/action") await engine.slack.action(body);
        if (path === "/slack/joined") await engine.slack.picker(body.channel, body.threadTs);
        if (path === "/intake") return Response.json(intake.create(body));
        return new Response(null, { status: 204 });
      },
    }),
  };

  // Slack: its Web API, and a file in the thread.
  const calls: Call[] = [];
  let ts = 100;
  const thread: any[] = [
    { user: "U1", text: "The export button times out on big workspaces", ts: "50.0001", files: [{ id: "F1", name: "export error.png", mimetype: "image/png", size: 4, url_private_download: "https://files.slack.com/files-pri/T1-F1/export.png" }] },
    { user: "U2", text: "<@UBOT> can you look into it?", ts: "50.0002", thread_ts: "50.0001" },
  ];
  const realFetch = globalThis.fetch;
  globalThis.fetch = (async (input: string | URL | Request, init: RequestInit = {}) => {
    const url = String(input instanceof Request ? input.url : input);
    const method = init.method ?? "GET";
    const body = typeof init.body === "string" ? JSON.parse(init.body) : null;
    calls.push({ url, method, body });
    if (url.startsWith("https://files.slack.com/")) {
      assert.equal(new Headers(init.headers).get("authorization"), `Bearer ${TOKEN}`);
      return new Response(new Uint8Array([0x89, 0x50, 0x4e, 0x47]), { headers: { "content-type": "image/png" } });
    }
    const api = /^https:\/\/slack\.com\/api\/([\w.]+)/.exec(url)?.[1];
    if (api === "chat.postMessage") return Response.json({ ok: true, ts: `${ts++}.0` });
    if (api === "chat.update") return Response.json({ ok: true });
    if (api === "chat.postEphemeral") return Response.json({ ok: true, message_ts: "1.0" });
    if (api === "auth.test") return Response.json({ ok: true, team: "Acme", user_id: "UBOT" });
    if (api === "conversations.replies") return Response.json({ ok: true, messages: thread });
    if (api === "users.info") return Response.json({ ok: true, user: { name: "x", profile: { display_name: url.includes("U1") ? "dana" : "sam" } } });
    return new Response("not mocked", { status: 500 });
  }) as typeof fetch;

  const ctx = { waitUntil: (p: Promise<unknown>) => void later.push(p) };
  const settle = async () => {
    while (later.length) await Promise.all(later.splice(0));
  };
  const posts = () => calls.filter((c) => c.url.endsWith("/chat.postMessage")).map((c) => c.body);
  const updates = () => calls.filter((c) => c.url.endsWith("/chat.update")).map((c) => c.body);
  const whispers = () => calls.filter((c) => c.url.endsWith("/chat.postEphemeral")).map((c) => c.body);
  return { store, engine, intake, env, sent, r2, events, calls, posts, updates, whispers, asks, ctx, settle, restore: () => (globalThis.fetch = realFetch) };
}

/** A request signed as Slack signs them (`v0:<timestamp>:<body>`). */
function signed(path: string, body: string, f: { secret?: string; at?: number; type?: string } = {}) {
  const at = String(f.at ?? Math.floor(Date.now() / 1000));
  const signature = `v0=${createHmac("sha256", f.secret ?? SECRET).update(`v0:${at}:${body}`).digest("hex")}`;
  return new Request(`https://factory.example${path}`, { method: "POST", body, headers: { "x-slack-request-timestamp": at, "x-slack-signature": signature, "content-type": f.type ?? "application/json" } });
}

const mention = (id = "Ev1", text = "<@UBOT> can you look into it?") =>
  JSON.stringify({ type: "event_callback", event_id: id, authorizations: [{ user_id: "UBOT" }], event: { type: "app_mention", user: "U2", text, ts: "50.0002", thread_ts: "50.0001", channel: "C1" } });

const click = (action: string, value: string | null, extra: Record<string, unknown> = {}) =>
  `payload=${encodeURIComponent(JSON.stringify({ type: "block_actions", user: { id: "U2", name: "sam" }, channel: { id: "C1", name: "support" }, message: { ts: "100.0" }, actions: [{ action_id: action, value, ...extra }] }))}`;

const PROPOSAL = {
  answer: "It's `exportAll` in *web/src/export.ts*: it loads every row at once.",
  proposal: { goal: "web", title: "Stream the export instead of loading every row", brief: "`exportAll` in web/src/export.ts loads every row; stream it.", doneWhen: ["A 100k-row export finishes in under 30s"] },
};

async function asked(f: ReturnType<typeof factory>, output: unknown = PROPOSAL, event = "Ev1") {
  const res = await slackEvents(signed("/integrations/slack/events", mention(event)), f.env, f.ctx);
  assert.equal(res.status, 200);
  await f.settle();
  const run = f.sent.find((c) => c.type === "draft.run") as Extract<ServerToRunner, { type: "draft.run" }>;
  assert.ok(run, "a draft.run went to the machine");
  await f.engine.fromRunner("m1", { type: "draft.done", id: run.id, output: typeof output === "string" ? output : JSON.stringify(output), error: null });
  await f.settle();
  return run;
}

// ---- Signatures, timestamps, url_verification, retries ----

test("events and actions refuse a bad signature or a stale timestamp", async () => {
  const f = factory();
  try {
    const body = mention();
    assert.equal((await slackEvents(signed("/integrations/slack/events", body, { secret: "wrong" }), f.env, f.ctx)).status, 401);
    assert.equal((await slackEvents(signed("/integrations/slack/events", body, { at: Math.floor(Date.now() / 1000) - 301 }), f.env, f.ctx)).status, 401);
    const noStamp = new Request("https://factory.example/integrations/slack/events", { method: "POST", body, headers: { "x-slack-signature": "v0=00" } });
    assert.equal((await slackEvents(noStamp, f.env, f.ctx)).status, 401);
    const form = click("slack.create", "slack-x");
    assert.equal((await slackActions(signed("/integrations/slack/actions", form, { secret: "wrong", type: "application/x-www-form-urlencoded" }), f.env, f.ctx)).status, 401);
    assert.equal((await slackActions(signed("/integrations/slack/actions", form, { at: 1, type: "application/x-www-form-urlencoded" }), f.env, f.ctx)).status, 401);
    await f.settle();
    assert.equal(f.sent.length, 0, "nothing ran");
    assert.equal(f.posts().length, 0, "nothing was said");
    assert.ok(f.events.some((e) => /bad signature/.test(e ?? "")), "the integration's status says so");
  } finally {
    f.restore();
  }
});

test("url_verification answers with the challenge", async () => {
  const f = factory();
  try {
    const res = await slackEvents(signed("/integrations/slack/events", JSON.stringify({ type: "url_verification", challenge: "abc123" })), f.env, f.ctx);
    assert.deepEqual(await res.json(), { challenge: "abc123" });
  } finally {
    f.restore();
  }
});

test("Slack isn't set up: events are refused with 404", async () => {
  const f = factory({ config: null });
  try {
    assert.equal((await slackEvents(signed("/integrations/slack/events", mention()), f.env, f.ctx)).status, 404);
  } finally {
    f.restore();
  }
});

test("a retried event_id is taken once; the bot's own mentions are ignored", async () => {
  const f = factory();
  try {
    for (let i = 0; i < 3; i++) assert.equal((await slackEvents(signed("/integrations/slack/events", mention("EvSame")), f.env, f.ctx)).status, 200);
    await f.settle();
    assert.equal(f.sent.filter((c) => c.type === "draft.run").length, 1, "one ask for three deliveries");
    const own = JSON.stringify({ type: "event_callback", event_id: "EvBot", authorizations: [{ user_id: "UBOT" }], event: { type: "app_mention", user: "UBOT", bot_id: "B1", text: "<@UBOT> hi", ts: "60.0", channel: "C1" } });
    await slackEvents(signed("/integrations/slack/events", own), f.env, f.ctx);
    await f.settle();
    assert.equal(f.sent.filter((c) => c.type === "draft.run").length, 1, "its own message asks nothing");
  } finally {
    f.restore();
  }
});

// ---- A mention, answered ----

test("a mention: 'Looking into it…' in the thread, a draft.run on the machine, and the answer replaces it with the proposal's card", async () => {
  const f = factory();
  try {
    const run = await asked(f);
    assert.match(run.id, /^slack-/);
    assert.equal(run.repo, "acme/web", "the best-suited goal's repo (the thread talks about the export)");
    assert.match(run.prompt, /dana: The export button times out/);
    assert.match(run.prompt, /export-error\.png \(image\/png\)/);
    assert.match(run.prompt, /- web · Website/);
    assert.match(run.prompt, /- mob · Mobile app/);
    assert.match(run.prompt, /"proposal"/);
    const [looking] = f.posts();
    assert.deepEqual([looking.channel, looking.thread_ts, looking.text], ["C1", "50.0001", "Looking into it…"]);
    const [answer] = f.updates();
    assert.equal(answer.ts, "100.0", "it replaces the 'Looking into it…' message");
    assert.match(answer.text, /exportAll/);
    const blocks = JSON.stringify(answer.blocks);
    assert.match(blocks, /Proposed task\* in Website/);
    assert.match(blocks, /Stream the export instead of loading every row/);
    assert.match(blocks, /A 100k-row export finishes in under 30s/);
    const buttons = answer.blocks.find((b: any) => b.type === "actions").elements;
    assert.deepEqual(buttons.map((b: any) => [b.action_id, b.text.text, b.value]), [["slack.create", "Create task", run.id], ["slack.dismiss", "Not now", run.id]]);
    // The thread's file is in the bucket, read with the bot token.
    const [key] = [...f.r2.keys()];
    assert.match(key, /^attachments\/[0-9a-f-]{36}\/export-error\.png$/);
    assert.equal(f.r2.get(key)!.type, "image/png");
  } finally {
    f.restore();
  }
});

test("a plain answer has no card; a runner's token request reads only the ask's goal", async () => {
  const f = factory();
  try {
    const run = await asked(f, { answer: "It's in web/src/export.ts." });
    const [answer] = f.updates();
    assert.equal(answer.text, "It's in web/src/export.ts.");
    assert.ok(!answer.blocks.some((b: any) => b.type === "actions"));
    // Answered: no more fetching for it.
    assert.equal(f.engine.slack.mayFetch(run.id, "m1", "acme/web"), false);
  } finally {
    f.restore();
  }
});

test("mayFetch: only the ask's goal's repos, only from its machine, only while it runs", async () => {
  const f = factory();
  try {
    await slackEvents(signed("/integrations/slack/events", mention()), f.env, f.ctx);
    await f.settle();
    const run = f.sent.find((c) => c.type === "draft.run") as Extract<ServerToRunner, { type: "draft.run" }>;
    assert.equal(f.engine.slack.mayFetch(run.id, "m1", "acme/web"), true);
    assert.equal(f.engine.slack.mayFetch(run.id, "m1", "acme/mob"), false);
    assert.equal(f.engine.slack.mayFetch(run.id, "m2", "acme/web"), false);
  } finally {
    f.restore();
  }
});

test("no machine online: the thread is told so", async () => {
  const f = factory();
  try {
    (f.engine as any).hooks.machines = async () => [{ id: "m1", name: "m1", owner: "me", online: false, health: null, sessions: [] }];
    await slackEvents(signed("/integrations/slack/events", mention()), f.env, f.ctx);
    await f.settle();
    assert.equal(f.sent.length, 0);
    assert.match(f.posts()[0].text, /No machine is online/);
    assert.equal(f.posts()[0].thread_ts, "50.0001");
  } finally {
    f.restore();
  }
});

// ---- What's in flight ----

/** Tasks in both goals: building, queued (WEB-3 ahead of WEB-2), in review, and a merged one. */
function inFlight(f: ReturnType<typeof factory>) {
  const base = { owner: "dana", brief: "", createdAt: 1, updatedAt: 1, plan: [], planVersion: 1, doneWhen: [], approvals: [], approvalsNeeded: 1, reviews: [], reviewsNeeded: 1,
    comments: [], changes: [], events: [], mockups: [], artifacts: [], tickets: [], shareable: false, agent: "claude", after: [], followUps: [] };
  const save = (id: string, goal: string, state: string, more: Record<string, unknown> = {}) => f.store.saveTask({ ...base, id, goal, title: `Task ${id}`, state, ...more } as never);
  save("WEB-1", "web", "building", { worker: { role: "builder", agent: "claude", machine: "m1", session: "s", startedAt: Date.now() - 5 * 60_000 } });
  save("WEB-2", "web", "building", { queueRank: 2 });
  save("WEB-3", "web", "building", { queueRank: 1 });
  save("WEB-4", "web", "reviewing", { pr: { number: 9, state: "open", branch: "b", base: "main", checks: [] } });
  save("WEB-5", "web", "merged");
  save("MOB-1", "mob", "building", { worker: { role: "builder", agent: "claude", machine: "m1", session: "s2", startedAt: Date.now() } });
  f.store.set("slack:channel:C1", JSON.stringify({ goals: ["web"] }));
}

test("@Maple status replies with the channel's work in flight, with no agent, even with no machine online", async () => {
  for (const [text, online] of [["<@UBOT> status", true], ["<@UBOT> what's in progress?", false]] as const) {
    const f = factory();
    try {
      inFlight(f);
      if (!online) (f.engine as any).hooks.machines = async () => [{ id: "m1", name: "m1", owner: "me", online: false, health: null, sessions: [] }];
      await slackEvents(signed("/integrations/slack/events", mention("Ev1", text)), f.env, f.ctx);
      await f.settle();
      assert.equal(f.sent.filter((c) => c.type === "draft.run").length, 0, `${text}: no draft.run`);
      assert.equal(f.posts().length, 1);
      const reply = f.posts()[0];
      assert.equal(reply.thread_ts, "50.0001");
      const said = reply.blocks.map((b: any) => b.text.text).join("\n");
      assert.match(said, /\*Building\*\n• \*WEB-1\*[^\n]*running 5m/);
      assert.match(said, /\*Queued\*\n• \*WEB-3\*[^\n]*#1 in line[^\n]*\n• \*WEB-2\*[^\n]*#2 in line/);
      assert.match(said, /\*In review\*\n• \*WEB-4\*[^\n]*PR #9/);
      assert.ok(!said.includes("WEB-5"), "merged work isn't in flight");
      assert.ok(!said.includes("MOB-1"), "another goal's work isn't this channel's");
      assert.ok(f.engine.slack.lastMention(), "the mention is noted");
    } finally {
      f.restore();
    }
  }
});

test("a free-form ask's prompt carries the factory's work in flight", async () => {
  const f = factory();
  try {
    inFlight(f);
    const run = await asked(f);
    const block = /<factory>\n([^]*?)\n<\/factory>/.exec(run.prompt)?.[1] ?? "";
    for (const id of ["WEB-1", "WEB-2", "WEB-3", "WEB-4"]) assert.ok(block.includes(id), `${id} is in the <factory> block`);
    assert.ok(!block.includes("MOB-1") && !block.includes("WEB-5"));
    assert.match(run.prompt, /Answer questions about tasks, progress, the queue or reviews from that block/);
  } finally {
    f.restore();
  }
});

test("no machine online: the reply says `@Maple status` still works", async () => {
  const f = factory();
  try {
    (f.engine as any).hooks.machines = async () => [{ id: "m1", name: "m1", owner: "me", online: false, health: null, sessions: [] }];
    await slackEvents(signed("/integrations/slack/events", mention()), f.env, f.ctx);
    await f.settle();
    assert.match(f.posts()[0].text, /`@Maple status` still works/);
  } finally {
    f.restore();
  }
});

// ---- Create task ----

test("Create task makes exactly one task in the proposed goal, its brief linking the thread's file, and starts planning", async () => {
  const f = factory();
  try {
    const run = await asked(f);
    const form = click("slack.create", run.id);
    for (let i = 0; i < 2; i++) {
      assert.equal((await slackActions(signed("/integrations/slack/actions", form, { type: "application/x-www-form-urlencoded" }), f.env, f.ctx)).status, 200);
      await f.settle();
    }
    const tasks = f.store.tasks();
    assert.equal(tasks.length, 1, "two clicks, one task");
    const [task] = tasks;
    assert.equal(task.goal, "web");
    assert.equal(task.id, "WEB-1");
    assert.equal(task.title, "Stream the export instead of loading every row");
    assert.equal(task.state, "planning");
    assert.equal(task.owner, "me", "the answering machine's owner");
    const [key] = [...f.r2.keys()];
    assert.ok(task.brief.includes(`## Attachments\n- [export-error.png](/${key})`), task.brief);
    assert.match(task.brief, /## Done when\n- A 100k-row export finishes in under 30s/);
    // A request for the thread: its replies go back into it.
    const request = f.store.intake()[0];
    assert.deepEqual([request.source, request.channel, request.requester, request.taskId], ["slack", "#support", "sam", "WEB-1"]);
    const card = f.updates().at(-1)!;
    assert.match(JSON.stringify(card.blocks), /Created WEB-1 in Website · planning/);
    assert.ok(!card.blocks.some((b: any) => b.type === "actions"), "the buttons are gone");
    const said = f.posts().map((p) => p.text);
    assert.ok(said.some((t) => /sam is tracking this as WEB-1; a planner is on it/.test(t)), "the thread hears it's planning");
    assert.ok(said.some((t) => t === "That's already WEB-1."), "the second click says so");
    assert.ok(f.posts().every((p) => p.channel === "C1" && p.thread_ts === "50.0001"));
    // The thread hears about the plan, and the merge.
    f.engine["intake"].forTask(task, "WEB-1 is merged into main. Thanks for asking!");
    await f.settle();
    assert.equal(f.posts().at(-1)!.text, "WEB-1 is merged into main. Thanks for asking!");
  } finally {
    f.restore();
  }
});

test("Not now sets the proposal aside; Create task on an expired ask says so", async () => {
  const f = factory();
  try {
    const run = await asked(f);
    await slackActions(signed("/integrations/slack/actions", click("slack.dismiss", run.id), { type: "application/x-www-form-urlencoded" }), f.env, f.ctx);
    await f.settle();
    assert.match(JSON.stringify(f.updates().at(-1)!.blocks), /sam said not now; no task made/);
    await f.engine.slack.action({ action: "slack.create", value: run.id, selected: [], user: { id: "U2", name: "sam" }, channel: { id: "C1", name: "support" }, messageTs: "100.0" });
    assert.equal(f.store.tasks().length, 0);

    const g = factory();
    try {
      const again = await asked(g);
      const saved = JSON.parse(g.store.get(`slack:ask:${again.id}`)!);
      g.store.set(`slack:ask:${again.id}`, JSON.stringify({ ...saved, expiresAt: Date.now() - 1 }));
      await g.engine.slack.action({ action: "slack.create", value: again.id, selected: [], user: { id: "U2", name: "sam" }, channel: { id: "C1", name: "support" }, messageTs: "100.0" });
      assert.equal(g.store.tasks().length, 0);
      assert.match(g.posts().at(-1)!.text, /expired/);
    } finally {
      g.restore();
    }
  } finally {
    f.restore();
  }
});

test("Create task refuses a goal archived since the proposal", async () => {
  const f = factory();
  try {
    const run = await asked(f);
    f.store.saveGoal(goal("web", { archived: true }));
    await f.engine.slack.action({ action: "slack.create", value: run.id, selected: [], user: { id: "U2", name: "sam" }, channel: { id: "C1", name: "support" }, messageTs: "100.0" });
    assert.equal(f.store.tasks().length, 0);
    assert.match(f.posts().at(-1)!.text, /I couldn't create it: Website is archived/);
  } finally {
    f.restore();
  }
});

test("Create task whose planning fails after the task is made: the ask stays created, the card names it, and another click makes none", async () => {
  const f = factory();
  try {
    const run = await asked(f);
    (f.engine as any).startPlanning = async () => {
      throw new Error("planning broke.");
    };
    const create = () => f.engine.slack.action({ action: "slack.create", value: run.id, selected: [], user: { id: "U2", name: "sam" }, channel: { id: "C1", name: "support" }, messageTs: "100.0" });
    await create();
    assert.equal(f.store.tasks().length, 1);
    const saved = JSON.parse(f.store.get(`slack:ask:${run.id}`)!);
    assert.deepEqual([saved.state, saved.task], ["created", "WEB-1"]);
    const card = f.updates().at(-1)!;
    assert.match(JSON.stringify(card.blocks), /Created WEB-1 in Website/);
    assert.ok(!card.blocks.some((b: any) => b.type === "actions"), "the buttons are gone");
    assert.match(f.posts().at(-1)!.text, /WEB-1 is made, but its planning didn't start: planning broke\./);
    await create();
    assert.equal(f.store.tasks().length, 1, "no second task");
    assert.equal(f.posts().at(-1)!.text, "That's already WEB-1.");
  } finally {
    f.restore();
  }
});

// ---- An answer that never comes ----

async function running(f: ReturnType<typeof factory>) {
  await slackEvents(signed("/integrations/slack/events", mention()), f.env, f.ctx);
  await f.settle();
  return f.sent.find((c) => c.type === "draft.run") as Extract<ServerToRunner, { type: "draft.run" }>;
}

test("a running ask whose machine goes offline: 'Looking into it…' says so, once", async () => {
  const f = factory();
  try {
    const run = await running(f);
    await f.engine.slack.machineGone("m2", "m2");
    assert.equal(f.updates().length, 0, "another machine's going offline says nothing");
    await f.engine.slack.machineGone("m1", "Dana's Mac");
    await f.engine.slack.machineGone("m1", "Dana's Mac");
    await f.engine.slack.sweep();
    const said = f.updates();
    assert.equal(said.length, 1, "said once");
    assert.deepEqual([said[0].ts, said[0].text], ["100.0", "Dana's Mac went offline before answering. Mention me again in a moment."]);
    // Its answer, if the runner comes back with one, is too late.
    await f.engine.fromRunner("m1", { type: "draft.done", id: run.id, output: JSON.stringify(PROPOSAL), error: null });
    assert.equal(f.updates().length, 1);
  } finally {
    f.restore();
  }
});

test("a running ask past its expiry: the alarm's sweep says so, once, and wakes for the next expiry", async () => {
  const f = factory();
  try {
    const wakes: number[] = [];
    (f.engine as any).hooks.wakeIn = (ms: number) => void wakes.push(ms);
    const run = await running(f);
    assert.ok(wakes.some((ms) => ms > 30 * 60_000), "the ask wakes the alarm at its expiry");
    await f.engine.slack.sweep();
    assert.equal(f.updates().length, 0, "not yet");
    const saved = JSON.parse(f.store.get(`slack:ask:${run.id}`)!);
    f.store.set(`slack:ask:${run.id}`, JSON.stringify({ ...saved, expiresAt: Date.now() - 1 }));
    await f.engine.slack.sweep();
    await f.engine.slack.sweep();
    const said = f.updates();
    assert.equal(said.length, 1, "said once");
    assert.equal(said[0].ts, "100.0");
    assert.match(said[0].text, /^I didn't hear back in time/);
  } finally {
    f.restore();
  }
});

// ---- Files of asks that never became a task ----

test("Not now deletes the ask's files from the bucket", async () => {
  const f = factory();
  try {
    const run = await asked(f);
    assert.equal(f.r2.size, 1);
    await f.engine.slack.action({ action: "slack.dismiss", value: run.id, selected: [], user: { id: "U2", name: "sam" }, channel: { id: "C1", name: "support" }, messageTs: "100.0" });
    await f.settle();
    assert.equal(f.r2.size, 0);
  } finally {
    f.restore();
  }
});

test("pruning an expired ask deletes its files unless it became a task", async () => {
  const f = factory();
  try {
    const expire = (id: string) => f.store.set(`slack:ask:${id}`, JSON.stringify({ ...JSON.parse(f.store.get(`slack:ask:${id}`)!), expiresAt: Date.now() - 1 }));
    // One that became a task: its files are the task's now.
    const made = await asked(f);
    await f.engine.slack.action({ action: "slack.create", value: made.id, selected: [], user: { id: "U2", name: "sam" }, channel: { id: "C1", name: "support" }, messageTs: "100.0" });
    const kept = [...f.r2.keys()];
    assert.equal(kept.length, 1);
    expire(made.id);
    await f.engine.slack.sweep();
    await f.settle();
    assert.equal(f.store.get(`slack:ask:${made.id}`), null, "forgotten");
    assert.deepEqual([...f.r2.keys()], kept, "its file is kept");
    // One answered and left: pruned on the next mention, its file deleted.
    f.sent.length = 0;
    const left = await asked(f, PROPOSAL, "Ev2");
    assert.equal(f.r2.size, 2);
    expire(left.id);
    await slackEvents(signed("/integrations/slack/events", mention("Ev3")), f.env, f.ctx);
    await f.settle();
    assert.equal(f.store.get(`slack:ask:${left.id}`), null, "forgotten");
    assert.equal([...f.r2.keys()].filter((k) => !kept.includes(k)).length, 1, "only the new mention's file is there besides the task's");
  } finally {
    f.restore();
  }
});

// ---- What the thread and the status line say ----

test("a Slack thread's accepted message points to the factory for the agent's questions", async () => {
  const f = factory();
  try {
    const run = await asked(f);
    await f.engine.slack.action({ action: "slack.create", value: run.id, selected: [], user: { id: "U2", name: "sam" }, channel: { id: "C1", name: "support" }, messageTs: "100.0" });
    await f.settle();
    const said = f.posts().map((p) => p.text).find((t) => /is tracking this as WEB-1/.test(t))!;
    assert.equal(said, "sam is tracking this as WEB-1; a planner is on it. Its agent's questions show up here (answer them in the factory), and this thread hears when it merges.");
    assert.doesNotMatch(said, /Questions from its agent come here/);
  } finally {
    f.restore();
  }
});

test("the Slack status line names its channels and the last mention's date", async () => {
  const f = factory();
  try {
    assert.equal(f.engine.slack.status(), "Invite @Maple to a public channel: /invite @Maple");
    f.store.set("slack:channels", JSON.stringify(["C1", "C2"]));
    assert.equal(f.engine.slack.status(), "@Maple is in 2 channels.");
    await running(f);
    const day = new Date().toLocaleDateString("en-US", { month: "short", day: "numeric", timeZone: "UTC" });
    assert.equal(f.engine.slack.status(), `@Maple is in 2 channels · last mentioned ${day}.`);
    f.store.set("slack:lastMention", String(Date.UTC(2026, 9, 30, 23, 0)));
    assert.equal(f.engine.slack.status(), "@Maple is in 2 channels · last mentioned Oct 30.");
  } finally {
    f.restore();
  }
});

// ---- A channel's goals ----

test("Maple joining a channel posts the goal picker; the pick is saved for the channel", async () => {
  const f = factory();
  try {
    const joined = JSON.stringify({ type: "event_callback", event_id: "EvJoin", authorizations: [{ user_id: "UBOT" }], event: { type: "member_joined_channel", user: "UBOT", channel: "C1" } });
    await slackEvents(signed("/integrations/slack/events", joined), f.env, f.ctx);
    await f.settle();
    const [picker] = f.posts();
    assert.equal(picker.channel, "C1");
    assert.equal(picker.thread_ts, undefined, "a message of its own in the channel");
    assert.equal(picker.text, "Which goals should I work on here?");
    const menu = picker.blocks.find((b: any) => b.type === "section").accessory;
    assert.equal(menu.type, "multi_static_select");
    assert.deepEqual(menu.options.map((o: any) => o.value), ["*", "web", "mob"]);
    // Someone else joining asks nothing.
    const other = JSON.stringify({ type: "event_callback", event_id: "EvJoin2", authorizations: [{ user_id: "UBOT" }], event: { type: "member_joined_channel", user: "U9", channel: "C1" } });
    await slackEvents(signed("/integrations/slack/events", other), f.env, f.ctx);
    await f.settle();
    assert.equal(f.posts().length, 1);

    await slackActions(signed("/integrations/slack/actions", click("goals.pick", null, { selected_options: [{ value: "mob" }] }), { type: "application/x-www-form-urlencoded" }), f.env, f.ctx);
    await f.settle();
    assert.deepEqual(f.engine.slack.channelGoals("C1").goals.map((g) => g.id), ["mob"]);
    assert.match(f.updates().at(-1)!.text, /I'll work on Mobile app here/);
    assert.deepEqual(f.engine.slack.channels(), ["C1"]);
    // `@Maple goals` brings the picker back.
    await slackEvents(signed("/integrations/slack/events", mention("EvGoals", "<@UBOT> goals")), f.env, f.ctx);
    await f.settle();
    assert.equal(f.posts().at(-1)!.text, "Which goals should I work on here?");
    assert.equal(f.sent.length, 0, "`goals` isn't a question for the agent");
  } finally {
    f.restore();
  }
});

test("`@Maple goals` in a thread posts the picker as a reply in that thread, and the agent gets nothing", async () => {
  const f = factory();
  try {
    await slackEvents(signed("/integrations/slack/events", mention("EvGoals", "<@UBOT> goals")), f.env, f.ctx);
    await f.settle();
    const [picker] = f.posts();
    assert.deepEqual([picker.channel, picker.thread_ts, picker.text], ["C1", "50.0001", "Which goals should I work on here?"]);
    const menu = picker.blocks.find((b: any) => b.type === "section").accessory;
    assert.deepEqual([menu.type, menu.action_id], ["multi_static_select", "goals.pick"]);
    assert.ok(!picker.blocks.some((b: any) => b.type === "actions"), "the menu is the section's accessory");
    assert.equal(f.sent.length, 0);
  } finally {
    f.restore();
  }
});

test("wordings of `goals` bring up the picker; a question naming goals in passing goes to the agent", async () => {
  for (const text of ["*goals*", "goals?", "change goals", "Goal", "pick goals.", "`set goals`", "which goals"]) assert.ok(wantsGoals(text), text);
  for (const text of ["what goals cover billing?", "goals for billing", "list the goals and their repos"]) assert.ok(!wantsGoals(text), text);
  const f = factory();
  try {
    for (const [i, text] of ["<@UBOT> *goals*", "<@UBOT> goals?", "<@UBOT> change goals"].entries()) {
      await slackEvents(signed("/integrations/slack/events", mention(`EvG${i}`, text)), f.env, f.ctx);
      await f.settle();
      assert.equal(f.posts().at(-1)!.text, "Which goals should I work on here?", text);
    }
    assert.equal(f.posts().length, 3);
    assert.equal(f.sent.length, 0, "none of them is a question for the agent");
    await slackEvents(signed("/integrations/slack/events", mention("EvQ", "<@UBOT> what goals cover billing?")), f.env, f.ctx);
    await f.settle();
    assert.equal(f.sent.length, 1, "a question goes to the agent");
    assert.ok(f.posts().slice(3).every((p) => p.text !== "Which goals should I work on here?"));
  } finally {
    f.restore();
  }
});

test("when Slack rejects the picker, a plain reply in the thread says why and the problem is recorded", async () => {
  const f = factory();
  const mocked = globalThis.fetch;
  globalThis.fetch = (async (input: string | URL | Request, init: RequestInit = {}) => {
    const res = await mocked(input, init);
    const body = typeof init.body === "string" ? JSON.parse(init.body) : null;
    if (String(input).endsWith("/chat.postMessage") && body?.blocks) return Response.json({ ok: false, error: "invalid_blocks" });
    return res;
  }) as typeof fetch;
  try {
    await slackEvents(signed("/integrations/slack/events", mention("EvGoals", "<@UBOT> goals")), f.env, f.ctx);
    await f.settle();
    const [picker, reply] = f.posts();
    assert.ok(picker.blocks);
    assert.deepEqual([reply.channel, reply.thread_ts, reply.blocks], ["C1", "50.0001", undefined]);
    assert.equal(reply.text, "I couldn't show the goal picker here: Slack's chat.postMessage said invalid_blocks");
    assert.ok(f.events.includes("Slack's chat.postMessage said invalid_blocks"));
    assert.equal(f.sent.length, 0);
  } finally {
    f.restore();
  }
});

test("a private channel: a mention in its thread reads conversations.replies and is asked like a public one; joining it posts the goal picker", async () => {
  const f = factory();
  try {
    const joined = JSON.stringify({ type: "event_callback", event_id: "EvJoinG", authorizations: [{ user_id: "UBOT" }], event: { type: "member_joined_channel", user: "UBOT", channel: "G1", channel_type: "G" } });
    await slackEvents(signed("/integrations/slack/events", joined), f.env, f.ctx);
    await f.settle();
    const [picker] = f.posts();
    assert.deepEqual([picker.channel, picker.text], ["G1", "Which goals should I work on here?"]);

    const event = { type: "app_mention", user: "U2", text: "<@UBOT> can you look into it?", ts: "50.0002", thread_ts: "50.0001", channel: "G1", channel_type: "group" };
    await slackEvents(signed("/integrations/slack/events", JSON.stringify({ type: "event_callback", event_id: "EvG", authorizations: [{ user_id: "UBOT" }], event })), f.env, f.ctx);
    await f.settle();
    const replies = f.calls.find((c) => c.url.includes("/conversations.replies"));
    assert.ok(replies, "the thread is read");
    assert.match(replies.url, /channel=G1/);
    assert.match(replies.url, /ts=50\.0001/);
    const run = f.sent.find((c) => c.type === "draft.run") as Extract<ServerToRunner, { type: "draft.run" }>;
    assert.ok(run, "the ask reached the factory and a draft.run went to the machine");
    assert.match(run.prompt, /dana: The export button times out/);
    const looking = f.posts().at(-1)!;
    assert.deepEqual([looking.channel, looking.thread_ts, looking.text], ["G1", "50.0001", "Looking into it…"]);
  } finally {
    f.restore();
  }
});

test("a channel whose picked goals are all archived: the answer uses every active goal and says once to pick again", async () => {
  const f = factory();
  try {
    f.store.saveGoal(goal("old", { name: "Old site", prefix: "OLD", archived: true }));
    f.store.set("slack:channel:C1", JSON.stringify({ goals: ["old"] }));
    assert.deepEqual(f.engine.slack.channelGoals("C1"), { goals: f.store.goals().filter((g) => !g.archived), note: ARCHIVED_NOTE });
    const run = await asked(f, { answer: "It's in web/src/export.ts." });
    assert.match(run.prompt, /- web · Website/);
    assert.match(run.prompt, /- mob · Mobile app/);
    assert.doesNotMatch(run.prompt, /Old site/);
    const [answer] = f.updates();
    assert.equal(answer.text, `It's in web/src/export.ts.\n\n_${ARCHIVED_NOTE}_`);
    assert.equal(answer.text.split(ARCHIVED_NOTE).length, 2, "said once");
    // A pick that's still active is used as it is, with no note.
    f.store.set("slack:channel:C1", JSON.stringify({ goals: ["old", "mob"] }));
    assert.deepEqual(f.engine.slack.channelGoals("C1"), { goals: [f.store.goal("mob")], note: null });
  } finally {
    f.restore();
  }
});

test("parseAnswer: a proposal only in one of the channel's goals, by id, name or prefix", () => {
  const goals = [goal("web"), goal("mob")];
  const p = (g: string) => JSON.stringify({ answer: "a", proposal: { goal: g, title: "t", brief: "b", doneWhen: ["x", 3] } });
  assert.equal(parseAnswer(p("web"), goals)?.proposal?.goal, "web");
  assert.equal(parseAnswer(p("Mobile app"), goals)?.proposal?.goal, "mob");
  assert.equal(parseAnswer(p("mob"), goals)?.proposal?.goal, "mob");
  assert.deepEqual(parseAnswer(p("web"), goals)?.proposal?.doneWhen, ["x"]);
  assert.equal(parseAnswer(p("elsewhere"), goals)?.proposal, null);
  assert.equal(parseAnswer('thinking… {"nope": 1}', goals), null);
});

// ---- The slash command ----

const command = (f: { secret?: string; at?: number } = {}) =>
  signed("/integrations/slack/command", new URLSearchParams({ text: "the export button times out", channel_id: "C1", channel_name: "support", user_name: "dana", response_url: "https://hooks.slack.com/commands/T1/1/abc" }).toString(), { ...f, type: "application/x-www-form-urlencoded" });

test("/maple posts the ask in the channel and the request's replies go in its thread; a bad signature is refused", async () => {
  const f = factory();
  try {
    const res = await slackCommand(command(), f.env);
    assert.equal(res.status, 200);
    assert.equal(await res.text(), "", "no second message from Slack");
    const [root, got] = f.posts();
    assert.deepEqual([root.channel, root.thread_ts, root.text], ["C1", undefined, "*dana* asked: the export button times out"]);
    assert.deepEqual([got.channel, got.thread_ts, got.text], ["C1", "100.0", "Got it: REQ-1 is in the factory's requests. I'll post updates in this thread."]);
    const [request] = f.store.intake();
    assert.deepEqual([request.source, request.channel, request.requester, request.title], ["slack", "#support", "dana", "the export button times out"]);
    assert.equal(f.store.intakeReplyUrl(request.id), "slack:C1|100.0|command");

    f.intake.accepted(request, { id: "WEB-1", state: "planning" } as never, "created", "Andrea");
    await f.settle();
    const accepted = f.posts()[2];
    assert.deepEqual([accepted.channel, accepted.thread_ts], ["C1", "100.0"]);
    assert.match(accepted.text, /^Andrea is tracking this as WEB-1/);

    assert.equal((await slackCommand(command({ secret: "wrong" }), f.env)).status, 401);
    assert.equal((await slackCommand(command({ at: 1 }), f.env)).status, 401);
  } finally {
    f.restore();
  }
});

for (const [why, config, refused] of [
  ["with no bot token", { signingSecret: SECRET }, null],
  ["when the bot isn't in the channel", undefined, "not_in_channel"],
] as const) {
  test(`/maple still makes a request and answers through response_url ${why}`, async () => {
    const f = factory({ config });
    const mocked = globalThis.fetch;
    if (refused) globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) =>
      String(input).endsWith("/chat.postMessage") ? (await mocked(input, init), Response.json({ ok: false, error: refused })) : mocked(input, init)) as typeof fetch;
    try {
      const res = await slackCommand(command(), f.env);
      assert.deepEqual(await res.json(), { response_type: "in_channel", text: "Got it: REQ-1 is in the factory's requests. I'll post here when someone picks it up." });
      const [request] = f.store.intake();
      assert.equal(request.requester, "dana");
      assert.equal(f.store.intakeReplyUrl(request.id), "https://hooks.slack.com/commands/T1/1/abc");
      assert.equal(f.posts().length, refused ? 1 : 0, refused ? "tried the channel once" : "no bot token, no post");
      if (refused) assert.ok(f.events.some((e) => e?.includes("not_in_channel")), "shows in Settings › Integrations");
    } finally {
      f.restore();
    }
  });
}

// ---- Setup ----

test("the manifest names this factory's events, actions and command URLs, the bot's events and scopes", () => {
  const m = manifest("https://factory.acme.dev/");
  assert.equal(m.settings.event_subscriptions.request_url, "https://factory.acme.dev/integrations/slack/events");
  assert.equal(m.settings.interactivity.request_url, "https://factory.acme.dev/integrations/slack/actions");
  assert.equal(m.features.slash_commands[0].url, "https://factory.acme.dev/integrations/slack/command");
  assert.equal(m.features.slash_commands[0].command, "/maple");
  assert.deepEqual(m.settings.event_subscriptions.bot_events, ["app_mention", "member_joined_channel"]);
  assert.deepEqual(m.oauth_config.scopes.bot, SLACK_SCOPES);
  assert.deepEqual(SLACK_SCOPES, ["app_mentions:read", "chat:write", "channels:history", "groups:history", "channels:read", "groups:read", "mpim:read", "files:read", "users:read", "commands"]);
  assert.equal(m.features.bot_user.display_name, "Maple");
  const url = new URL(slackSetupUrl("https://factory.acme.dev"));
  assert.equal(url.origin + url.pathname, "https://api.slack.com/apps");
  assert.equal(url.searchParams.get("new_app"), "1");
  assert.deepEqual(JSON.parse(url.searchParams.get("manifest_json")!), manifest("https://factory.acme.dev"));
});

// The scopes Slack refuses a manifest without, per bot event (api.slack.com/events). A new event goes here first.
const EVENT_SCOPES: Record<string, string[]> = {
  app_mention: ["app_mentions:read"],
  member_joined_channel: ["channels:read", "groups:read", "mpim:read"],
};

test("every bot event in the manifest has the scopes Slack requires for it", () => {
  for (const event of manifest("https://factory.acme.dev").settings.event_subscriptions.bot_events) {
    assert.ok(EVENT_SCOPES[event], `add ${event}'s required scopes to EVENT_SCOPES`);
    for (const scope of EVENT_SCOPES[event]) assert.ok(SLACK_SCOPES.includes(scope), `${event} needs ${scope}`);
  }
});

test("the bot token is optional and has to look like one", () => {
  const slack = definition("slack")!;
  assert.deepEqual(merged(slack, true, { signingSecret: "s" }, {}, {}), { signingSecret: "s" }, "slash-command-only still saves");
  assert.match(merged(slack, true, { signingSecret: "s", botToken: "xoxp-user" }, {}, {}) as string, /starts with xoxb-/);
  assert.deepEqual(merged(slack, true, { signingSecret: "s", botToken: "xoxb-1" }, {}, {}), { signingSecret: "s", botToken: "xoxb-1" });
});

// ---- Linking a Slack account (src/slack-links.ts) ----

const teamMention = (id: string, text: string, user = "U2") =>
  JSON.stringify({ type: "event_callback", event_id: id, team_id: "T1", authorizations: [{ user_id: "UBOT", team_id: "T1" }], event: { type: "app_mention", user, text, ts: "50.0002", thread_ts: "50.0001", channel: "C1" } });

test("@Maple link whispers a one-time /link/slack URL; redeeming it as a member links them; later mentions carry their login", async () => {
  const f = factory({ db: d1() });
  try {
    f.env.PUBLIC_URL = "https://factory.example";
    await slackEvents(signed("/integrations/slack/events", teamMention("Ev1", "<@UBOT> link")), f.env, f.ctx);
    await f.settle();
    assert.equal(f.posts().length, 0, "nothing in the channel for everyone");
    assert.equal(f.asks.length, 0, "no agent");
    const [w] = f.whispers();
    assert.equal(w.user, "U2");
    assert.equal(w.channel, "C1");
    const url = new URL(w.blocks[1].elements[0].url);
    assert.equal(`${url.origin}${url.pathname}`, "https://factory.example/link/slack");
    const code = url.searchParams.get("code")!;
    console.log(`chat.postEphemeral → user ${w.user}: ${url.origin}${url.pathname}?code=<${code.length} chars>`);

    const me = { login: "afomera", role: "member" } as never;
    const post = (c: string) => linkApi(new Request("https://factory.example/api/slack/link", { method: "POST", body: JSON.stringify({ code: c }) }), f.env, me);
    const res = (await post(code))!;
    assert.equal(res.status, 200);
    const linked = ((await res.json()) as any).slack;
    assert.deepEqual([linked.user, linked.team, linked.name, linked.teamName], ["U2", "T1", "sam", "Acme"]);
    console.log(`POST /api/slack/link as afomera → ${res.status} linked Slack @${linked.name} (${linked.teamName})`);
    assert.equal((await post(code))!.status, 400, "the code is single use");

    await slackEvents(signed("/integrations/slack/events", teamMention("Ev2", "<@UBOT> what's left on WEB-1?")), f.env, f.ctx);
    await f.settle();
    assert.equal(f.asks.at(-1).login, "afomera");
    console.log(`signed mention → /slack/ask login=${f.asks.at(-1).login}`);
    const run = f.sent.find((c) => c.type === "draft.run") as Extract<ServerToRunner, { type: "draft.run" }>;
    assert.match(run.prompt, /The person asking is @afomera/);

    // Another Slack user isn't linked: their asks carry no login.
    await slackEvents(signed("/integrations/slack/events", teamMention("Ev3", "<@UBOT> what's left on WEB-1?", "U1")), f.env, f.ctx);
    await f.settle();
    assert.equal(f.asks.at(-1).login, null);

    // @Maple unlink drops it, said only to them.
    await slackEvents(signed("/integrations/slack/events", teamMention("Ev4", "<@UBOT> unlink")), f.env, f.ctx);
    await f.settle();
    assert.match(f.whispers().at(-1).text, /Unlinked: I no longer know you as @afomera/);
    const audit = f.env.DB.sql.prepare("SELECT actor, action, target FROM audit ORDER BY id").all().map((r: any) => `${r.action} ${r.target}`);
    assert.deepEqual(audit, ["slack.linked afomera", "slack.unlinked afomera"]);
  } finally {
    f.restore();
  }
});

test("@Maple mine: a linked member gets only their work, with no agent; an unlinked person is told how to link", async () => {
  const f = factory({ db: d1() });
  try {
    f.store.saveGoal({ ...goal("web"), lead: "afomera" });
    const now = Date.now();
    const t = (id: string, x: Record<string, unknown>) => (f.engine as any).newTask(f.store.goal("web"), x.owner, { title: `Task ${id}`, brief: "b", tickets: [], shareable: false, agent: "claude", model: null, intake: null, repo: null, after: [], effort: null });
    const mine = t("a", { owner: "afomera" });
    mine.state = "building";
    mine.worker = { startedAt: now - 60_000, agent: "claude" };
    f.store.saveTask(mine);
    const theirs = t("b", { owner: "ana" });
    theirs.state = "awaitingApproval";
    f.store.saveTask(theirs);
    const other = t("c", { owner: "ana" });
    other.state = "building";
    f.store.saveTask(other);

    await slackEvents(signed("/integrations/slack/events", teamMention("Ev1", "<@UBOT> mine")), f.env, f.ctx);
    await f.settle();
    assert.match(f.posts().at(-1).text, /Mention me with `link`/);

    const { startLink, redeem } = await import("../src/slack-links.ts");
    await redeem(f.env, await startLink(f.env, "T1", "U2"), "afomera");
    await slackEvents(signed("/integrations/slack/events", teamMention("Ev2", "<@UBOT> what's waiting on me?")), f.env, f.ctx);
    await f.settle();
    const said = f.posts().at(-1).text as string;
    assert.match(said, new RegExp(`Your tasks in flight\\*\\n• \\*${mine.id}\\*`));
    assert.match(said, new RegExp(`Plans waiting on your approval\\*\\n• \\*${theirs.id}\\*`));
    assert.ok(!said.includes(other.id), "someone else's building task isn't listed");
    assert.equal(f.sent.filter((c) => c.type === "draft.run").length, 0, "no agent");
  } finally {
    f.restore();
  }
});

test("Create task by a linked clicker credits their login; the owner stays the answering machine's", async () => {
  const f = factory({ db: d1() });
  try {
    const { startLink, redeem } = await import("../src/slack-links.ts");
    await redeem(f.env, await startLink(f.env, "T1", "U2"), "afomera");
    const run = await asked(f);
    const payload = JSON.parse(decodeURIComponent(click("slack.create", run.id).slice("payload=".length)));
    payload.team = { id: "T1" };
    await slackActions(signed("/integrations/slack/actions", `payload=${encodeURIComponent(JSON.stringify(payload))}`, { type: "application/x-www-form-urlencoded" }), f.env, f.ctx);
    await f.settle();
    const task = f.store.tasks().find((t) => t.title.startsWith("Stream the export"))!;
    assert.equal(task.owner, "me");
    assert.ok(task.events.some((e) => /created from Slack .* by @afomera/.test(e.text)), task.events.map((e) => e.text).join(" | "));
  } finally {
    f.restore();
  }
});

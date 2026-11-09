// Langfuse (MF-348), against `wrangler dev` and a talking-only runner enrolled here (as e2e-stats.mjs),
// with this script standing in for Langfuse's ingestion API on :8798:
//   node server/test/e2e-langfuse.mjs http://localhost:8788
// An admin saves Langfuse (host http://localhost:8798) and sends a test trace. A task then plans, builds
// (steered once), is reviewed (one finding) and merges: every batch is basic-authed with the keys, and
// together they make one trace (the task's title, its goal as a tag) with a generation per session
// (tokens and cost) and plan_versions / human_touchpoints / review_verdict / review_findings /
// merged_as_is / cycle_minutes scores. No message any app was sent carries the secret key. Then Langfuse
// answers 401: a new task still plans, and Langfuse's card shows the 401 as its last error.

import http from "node:http";

const [base = "http://localhost:8788"] = process.argv.slice(2);
const ws = base.replace(/^http/, "ws");
const token = async (as) => (await (await fetch(`${base}/dev/token${as ? `?as=${as}` : ""}`, { method: "POST" })).json()).token;
const admin = await token();
const member = await token(`lf-member-${Date.now() % 100000}`);
const auth = { authorization: `Bearer ${admin}` };

// The runner: opens the sessions it's sent, and makes each one do its role's work through the tools.
const runnerId = `lf-${Date.now() % 100000}`;
const { code } = await (await fetch(`${base}/api/machines/enroll`, { method: "POST", headers: auth })).json();
const enrolled = await (await fetch(`${base}/runner/enroll`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ code, runnerId, hostname: runnerId, os: "macos", arch: "arm64", version: "0.0.0-fake" }),
})).json();
const runner = new WebSocket(`${ws}/runner/connect?runner=${runnerId}`, { headers: { authorization: `Bearer ${enrolled.token}` } });
await new Promise((r, j) => { runner.onopen = r; runner.onerror = j; });
const toServer = (m) => runner.send(JSON.stringify(m));
const sessions = new Map(); // taskId → the session open for it
const replies = new Map();
const opened = [];
runner.onmessage = (e) => {
  // Binary frames are terminal input: an answer or a change request typed into the session.
  if (typeof e.data !== "string") return;
  const m = JSON.parse(e.data);
  if (m.type === "session.open" && m.taskId) {
    sessions.set(m.taskId, m.id);
    opened.push(m);
    const cwd = m.worktree?.path ?? m.cwd;
    toServer({ type: "session.opened", session: { id: m.id, agent: m.agent, cwd, pid: 1, startedAt: Date.now(), taskId: m.taskId } });
    toServer({ type: "task.started", taskId: m.taskId, repo: null, repoDir: "/tmp/lf-repo", base: "main", project: null });
  }
  if (m.type === "session.kill") toServer({ type: "session.ended", end: { id: m.id, cause: "killed", code: null, signal: null, detail: null, at: Date.now(), lastOutput: [], by: null } });
  if (m.type === "mcp.response") replies.get(m.reqId)?.(m);
  if (m.type === "task.finish") toServer({ type: "task.finished", taskId: m.taskId, ok: true, pushed: "fallback", owner: null, repo: null, branch: m.branch, base: "main", commit: "abc1234def", reason: null, message: null });
  if (m.type === "task.diff") toServer({ type: "task.diff", taskId: m.taskId, ok: true, files: [{ path: "a.txt", added: 3, removed: 1 }], patch: "", truncated: false, message: null });
  if (m.type === "task.merge") toServer({ type: "task.merged", taskId: m.taskId, ok: true, commit: "feedbeef00", message: null });
};
toServer({ type: "hello", runnerId, hostname: runnerId, os: "macos", arch: "arm64", version: "0.0.0-fake", sessions: [], ended: [] });
toServer({ type: "health", health: { cpu: 5, cores: 10, load1: 0.5, memUsed: 8e9, memTotal: 32e9, diskUsed: 2e11, diskTotal: 1e12, uptime: 1000, battery: null, agents: [{ name: "claude", version: "2.1.0", loggedIn: true }] } });
// A session's spend so far, as the runner measures it from the agent's harness.
const sessionCost = (session, costUsd, inputTokens, outputTokens, model = "claude-opus-5-5") => toServer({
  type: "session.cost",
  cost: { session, agent: "claude", model, costUsd, inputTokens, outputTokens, cacheReadTokens: 0, cacheWriteTokens: 0, durationMs: 60_000, observedAt: Date.now() },
});
let n = 0;
const tool = (taskId, name, args = {}) => new Promise((resolve, reject) => {
  const reqId = `r${++n}`;
  replies.set(reqId, (m) => (m.error ? reject(new Error(`${name}: ${m.error}`)) : resolve(m.result)));
  toServer({ type: "mcp.request", reqId, session: sessions.get(taskId), tool: name, args });
});

// An app connection: the feed, and what the server said back to it.
function app(bearer) {
  const feed = new WebSocket(`${ws}/client/connect`, { headers: { authorization: `Bearer ${bearer}` } });
  const c = { feed, tasks: new Map(), goals: [], machines: [], errors: [], toasts: [], raw: [], integrations: [], stats: null, poke: null, me: null };
  feed.onmessage = (e) => {
    c.raw.push(String(e.data));
    const m = JSON.parse(e.data);
    if (m.type === "snapshot") c.integrations = m.integrations ?? [];
    if (m.type === "integrations.updated") c.integrations = m.integrations;
    if (m.type === "toast") c.toasts.push(m.text);
    if (m.type === "snapshot") { c.me = m.me; c.goals = m.goals; c.machines = m.machines; for (const t of m.tasks) c.tasks.set(t.id, t); }
    if (m.type === "goal.updated") c.goals = [...c.goals.filter((g) => g.id !== m.goal.id), m.goal];
    if (m.type === "machine.updated") c.machines = [...c.machines.filter((x) => x.id !== m.machine.id), m.machine];
    if (m.type === "task.updated") c.tasks.set(m.task.id, m.task);
    if (m.type === "stats") c.stats = m.summary;
    if (m.type === "error") c.errors.push(m.message);
    c.poke?.();
  };
  c.send = (m) => feed.send(JSON.stringify(m));
  c.wait = async (what, test, ms = 30000) => {
    const deadline = Date.now() + ms;
    for (;;) {
      const hit = test();
      if (hit) return hit;
      if (c.errors.length) throw new Error(`server said: ${c.errors.join("; ")}`);
      if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
      await new Promise((r) => { c.poke = r; setTimeout(r, 250); });
    }
  };
  return c;
}
const step = (text) => console.log(`✓ ${text}`);


// Langfuse's ingestion endpoint: records each batch; answers 207 (or `lfStatus`).
const run = Date.now() % 100000;
const PK = `pk-lf-e2e-${run}`;
const SK = `sk-lf-e2e-${run}-do-not-leak`;
let lfStatus = 207;
const batches = [];
const langfuse = http.createServer((req, res) => {
  let body = "";
  req.on("data", (d) => (body += d));
  req.on("end", () => {
    const parsed = JSON.parse(body || "{}");
    batches.push({ path: req.url, auth: req.headers.authorization, status: lfStatus, batch: parsed.batch ?? [] });
    res.statusCode = lfStatus;
    res.setHeader("content-type", "application/json");
    res.end(lfStatus === 207 ? JSON.stringify({ successes: (parsed.batch ?? []).map((e) => ({ id: e.id, status: 201 })), errors: [] }) : '{"message":"Invalid credentials. Confirm that you\'ve configured the correct host."}');
  });
});
await new Promise((r) => langfuse.listen(8798, r));
const events = () => batches.filter((b) => b.status === 207).flatMap((b) => b.batch);
const me = app(admin);
await new Promise((r) => (me.feed.onopen = r));
me.send({ type: "subscribe" });
const machine = await me.wait("the runner", () => me.machines.find((x) => x.id === runnerId && x.online));
const others = me.machines.filter((x) => x.id !== runnerId && x.owner === machine.owner && !x.settings?.paused);
const settings = (paused) => ({ capacity: null, teamSlots: 0, lendIdle: false, loadCap: 0.85, paused, pausedUntil: null });
for (const other of others) me.send({ type: "machine.settings", machine: other.id, settings: settings(true) });
me.send({ type: "machine.settings", machine: runnerId, settings: { ...settings(false), capacity: 2 } });
const lf = () => me.integrations.find((i) => i.kind === "langfuse");

try {
  // Set up Langfuse, and send a test trace.
  me.send({ type: "integrations.save", kind: "langfuse", enabled: true, values: { publicKey: PK, secretKey: SK, host: "http://localhost:8798" } });
  await me.wait("Langfuse saved", () => lf()?.enabled && lf().values.publicKey === PK);
  if (lf().webhookUrl !== "") throw new Error(`Langfuse has a webhook URL: ${lf().webhookUrl}`);
  step(`Langfuse saved: ${JSON.stringify({ enabled: lf().enabled, values: lf().values, webhookUrl: lf().webhookUrl })}`);
  me.send({ type: "integrations.test", kind: "langfuse" });
  const toast = await me.wait("the test's toast", () => me.toasts.find((t) => t.startsWith("Langfuse took")));
  const test = batches.at(-1);
  if (test.batch[0]?.body?.name !== "Maple Factory test trace") throw new Error(`test batch: ${JSON.stringify(test)}`);
  step(`Send a test trace → toast "${toast}"`);

  const prefix = `LF${String(Date.now() % 10000).padStart(4, "0")}`.slice(0, 6);
  me.send({ type: "goal.save", goal: { id: "", name: `Langfuse ${prefix}`, prefix, color: "#14B8A6", summary: "", lead: "", repos: [], folder: "/tmp/lf-repo", base: "main" } });
  const goal = await me.wait("the goal", () => me.goals.find((g) => g.prefix === prefix));
  me.send({ type: "task.create", goal: goal.id, title: "Trace me in Langfuse", brief: "A task for the Langfuse e2e.", shareable: false, plan: true, tickets: [] });
  const id = (await me.wait("the task", () => [...me.tasks.values()].find((t) => t.goal === goal.id))).id;
  const task = () => me.tasks.get(id);

  await me.wait("the planner", () => opened.find((o) => o.taskId === id && sessions.get(id) === o.id && task()?.worker?.role === "planner"));
  const plannerSession = sessions.get(id);
  sessionCost(plannerSession, 0.75, 12_000, 1_500);
  await tool(id, "submit_plan", {
    summary: "One step.", steps: [{ text: "Do it", file: "a.txt" }], doneWhen: [{ text: "It's done", proof: "terminal" }],
    risk: { level: "low", reasons: [], areas: [] }, footprint: { files: 1, lines: 3 },
  });
  await me.wait("awaiting approval", () => task()?.state === "awaitingApproval");
  me.send({ type: "task.approvePlan", id });
  step(`${id}: planned ($0.75) and plan v1 approved`);

  await me.wait("the builder", () => task()?.worker?.role === "builder" && sessions.get(id) === task().worker.session);
  const builderSession = sessions.get(id);
  sessionCost(builderSession, 2.5, 40_000, 6_000, "claude-sonnet-5-5");
  me.send({ type: "task.steer", id, text: "Make it three lines." });
  await me.wait("the change request", () => task()?.changes.length === 1);
  await tool(id, "progress", { applied: ["C1"], step: 1, status: "done" });
  await tool(id, "prove", { item: 1, kind: "terminal", summary: "Done.", command: "cat a.txt", output: ["1", "2", "3"] });
  await tool(id, "finish", { summary: "Did it." });
  step(`${id}: built ($2.50), steered once`);

  await me.wait("the reviewer", () => task()?.worker?.role === "reviewer" && sessions.get(id) === task().worker.session);
  await tool(id, "submit_review", {
    verdict: "passed", summary: "Fine.", ask: [{ text: "It's done", verdict: "met" }], proofs: [{ text: "It's done", verdict: "met" }],
    findings: [{ kind: "code", severity: "minor", text: "Trailing newline." }],
  });
  await me.wait("review passed", () => task()?.autoReview?.rounds.at(-1)?.verdict === "passed");
  me.send({ type: "task.approveChanges", id });
  await me.wait("approved", () => task()?.reviews.length >= task()?.reviewsNeeded);
  await me.wait("auto-merge", () => task()?.state === "merged" || task()?.liveLog === "Merging…", 3000).catch(() => me.send({ type: "task.merge", id }));
  await me.wait("merged", () => task()?.state === "merged");
  step(`${id}: reviewed (1 round, 1 finding) and merged`);

  // What reached Langfuse.
  const want = ["plan_versions", "human_touchpoints", "review_verdict", "review_findings", "merged_as_is", "cycle_minutes"];
  await me.wait("the scores", () => want.every((n) => events().some((e) => e.type === "score-create" && e.body.name === n)), 10000);
  const mine = batches.filter((b) => b.batch.some((e) => e.type === "trace-create" && e.body.metadata?.taskId === id));
  const traceIds = new Set(mine.flatMap((b) => b.batch.map((e) => (e.type === "trace-create" ? e.body.id : e.body.traceId))));
  if (traceIds.size !== 1) throw new Error(`${traceIds.size} trace ids: ${[...traceIds]}`);
  const [trace] = traceIds;
  const expectAuth = `Basic ${Buffer.from(`${PK}:${SK}`).toString("base64")}`;
  if (!batches.every((b) => b.auth === expectAuth && b.path === "/api/public/ingestion")) throw new Error("a batch without the keys");
  const last = (type, pred) => mine.flatMap((b) => b.batch).filter((e) => e.type === type && pred(e)).at(-1)?.body;
  const tr = last("trace-create", () => true);
  if (tr.name !== "Trace me in Langfuse" || !tr.tags.includes(`Langfuse ${prefix}`)) throw new Error(`trace: ${JSON.stringify(tr)}`);
  console.log(`  ${mine.length} batches for ${id}, all on trace ${trace}: name "${tr.name}", tags ${JSON.stringify(tr.tags)}`);
  const gens = new Map(mine.flatMap((b) => b.batch).filter((e) => e.type === "generation-create").map((e) => [e.body.id, e.body]));
  for (const [session, cost, input, model] of [[plannerSession, 0.75, 12_000, "claude-opus-5-5"], [builderSession, 2.5, 40_000, "claude-sonnet-5-5"]]) {
    const g = gens.get(session);
    if (!g || g.costDetails?.total !== cost || g.usageDetails.input !== input || g.model !== model) throw new Error(`generation ${session}: ${JSON.stringify(g)}`);
    console.log(`  generation ${g.name}: ${JSON.stringify({ model: g.model, usageDetails: g.usageDetails, costDetails: g.costDetails })}`);
  }
  const scores = mine.flatMap((b) => b.batch).filter((e) => e.type === "score-create");
  for (const n of want) {
    const s = scores.filter((e) => e.body.name === n).map((e) => e.body);
    if (!s.length) throw new Error(`no ${n} score`);
    console.log(`  score ${n}: ${s.map((x) => `${x.dataType} ${JSON.stringify(x.value)}${x.comment ? ` (${x.comment})` : ""}`).join("; ")}`);
  }
  const v = scores.find((e) => e.body.name === "review_verdict").body.value;
  const f = scores.find((e) => e.body.name === "review_findings").body.value;
  const asIs = scores.find((e) => e.body.name === "merged_as_is").body.value;
  if (v !== "passed" || f !== 1 || asIs !== 0) throw new Error(`verdict ${v}, findings ${f}, as-is ${asIs} (steered, so not as-is)`);
  step(`one trace with ${gens.size} generations and scores ${want.join(", ")}`);

  // The secret key never reached an app.
  const leaked = me.raw.filter((r) => r.includes(SK));
  if (leaked.length) throw new Error(`the secret key was in ${leaked.length} client messages`);
  const fresh = app(admin);
  await new Promise((r) => (fresh.feed.onopen = r));
  fresh.send({ type: "subscribe" });
  await fresh.wait("a fresh snapshot", () => fresh.me);
  if (fresh.raw.some((r) => r.includes(SK))) throw new Error("the secret key is in a fresh snapshot");
  const snap = fresh.integrations.find((i) => i.kind === "langfuse");
  step(`secret key in none of ${me.raw.length} feed messages, nor a fresh snapshot (values: ${JSON.stringify(snap.values)})`);
  fresh.feed.close();

  // Langfuse says 401: the factory carries on; the card shows the error.
  lfStatus = 401;
  me.send({ type: "task.create", goal: goal.id, title: "Still works when Langfuse doesn't", brief: "", shareable: false, plan: true, tickets: [] });
  const id2 = (await me.wait("the second task", () => [...me.tasks.values()].find((t) => t.goal === goal.id && t.id !== id))).id;
  await me.wait("its planner", () => me.tasks.get(id2)?.worker?.role === "planner" && sessions.get(id2) === me.tasks.get(id2).worker.session);
  sessionCost(sessions.get(id2), 0.1, 100, 10);
  await tool(id2, "submit_plan", {
    summary: "One step.", steps: [{ text: "Do it", file: "a.txt" }], doneWhen: [{ text: "It's done", proof: "terminal" }],
    risk: { level: "low", reasons: [], areas: [] }, footprint: { files: 1, lines: 3 },
  });
  await me.wait("awaiting approval", () => me.tasks.get(id2)?.state === "awaitingApproval");
  me.send({ type: "task.approvePlan", id: id2 });
  await me.wait("its builder", () => me.tasks.get(id2)?.worker?.role === "builder");
  const err = await me.wait("Langfuse's last error", () => lf()?.lastError);
  const refused = batches.filter((b) => b.status === 401).length;
  step(`Langfuse answering 401 (${refused} batches refused): ${id2} still planned, approved and is building (state ${me.tasks.get(id2).state})`);
  console.log(`  Langfuse card: lastError "${err}"`);
  me.send({ type: "integrations.test", kind: "langfuse" });
  await me.wait("the test's error", () => me.errors.length, 10000).catch(() => {});
  console.log(`  Send a test trace → error "${me.errors.at(-1)}"`);
  me.errors.length = 0;
  me.send({ type: "task.cancel", id: id2 });
} finally {
  for (const other of others) me.send({ type: "machine.settings", machine: other.id, settings: { ...other.settings, paused: false } });
  me.send({ type: "integrations.save", kind: "langfuse", enabled: false, values: {} });
  await new Promise((r) => setTimeout(r, 500));
  me.feed.close();
  runner.close();
  langfuse.close();
}
console.log("e2e-langfuse: ok");
process.exit(0);

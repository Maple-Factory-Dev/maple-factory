// Statistics: a task taken through a raised hand, a steer, a review round and a merge, against
// `wrangler dev` and a talking-only runner enrolled here (like test/fake-runner.mjs) that plays the
// planner, builder and reviewer itself through the `maple` tools:
//   node server/test/e2e-stats.mjs http://localhost:8788
// Checks: an admin's `stats.get` counts that task's merge, hand (and how long it was up), steer,
// review round and its findings, and first-try plan; a member's gets "Only admins can see
// statistics."; GET /api/stats?days=30 answers an admin with the same summary (and `raw=1` its event
// rows) and a member with 403; the `session.cost` readings the runner sent for the planner and the builder
// add up by role and by agent · model, a later lower reading doesn't lower a session's total, and a
// personal session's spend isn't counted. Other machines of yours are paused for the run and resumed after.

const [base = "http://localhost:8788"] = process.argv.slice(2);
const ws = base.replace(/^http/, "ws");
const token = async (as) => (await (await fetch(`${base}/dev/token${as ? `?as=${as}` : ""}`, { method: "POST" })).json()).token;
const admin = await token();
const member = await token(`stats-member-${Date.now() % 100000}`);
const auth = { authorization: `Bearer ${admin}` };

// The runner: opens the sessions it's sent, and makes each one do its role's work through the tools.
const runnerId = `stats-${Date.now() % 100000}`;
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
    toServer({ type: "task.started", taskId: m.taskId, repo: null, repoDir: "/tmp/stats-repo", base: "main", project: null });
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
  const c = { feed, tasks: new Map(), goals: [], machines: [], errors: [], stats: null, poke: null, me: null };
  feed.onmessage = (e) => {
    const m = JSON.parse(e.data);
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

const me = app(admin);
await new Promise((r) => (me.feed.onopen = r));
me.send({ type: "subscribe" });
const machine = await me.wait("the runner", () => me.machines.find((x) => x.id === runnerId && x.online));
const others = me.machines.filter((x) => x.id !== runnerId && x.owner === machine.owner && !x.settings?.paused);
const settings = (paused) => ({ capacity: null, teamSlots: 0, lendIdle: false, loadCap: 0.85, paused, pausedUntil: null });
for (const other of others) me.send({ type: "machine.settings", machine: other.id, settings: settings(true) });
me.send({ type: "machine.settings", machine: runnerId, settings: { ...settings(false), capacity: 2 } });

try {
  const before = await statsFor(me);

  const prefix = `ST${String(Date.now() % 10000).padStart(4, "0")}`.slice(0, 6);
  me.send({ type: "goal.save", goal: { id: "", name: `Stats ${prefix}`, prefix, color: "#14B8A6", summary: "", lead: "", repos: [], folder: "/tmp/stats-repo", base: "main" } });
  const goal = await me.wait("the goal", () => me.goals.find((g) => g.prefix === prefix));
  me.send({ type: "task.create", goal: goal.id, title: "Count the touchpoints", brief: "A task for the stats e2e.", shareable: false, plan: true, tickets: [] });
  const id = (await me.wait("the task", () => [...me.tasks.values()].find((t) => t.goal === goal.id))).id;
  const task = () => me.tasks.get(id);

  // Planner: plan v1, approved first try.
  await me.wait("the planner", () => opened.find((o) => o.taskId === id && sessions.get(id) === o.id && task()?.worker?.role === "planner"));
  const plannerSession = sessions.get(id);
  sessionCost(plannerSession, 0.75, 12_000, 1_500);
  await tool(id, "submit_plan", {
    summary: "One step.", steps: [{ text: "Do it", file: "a.txt" }], doneWhen: [{ text: "It's done", proof: "terminal" }],
    risk: { level: "low", reasons: [], areas: [] }, footprint: { files: 1, lines: 3 },
  });
  await me.wait("awaiting approval", () => task()?.state === "awaitingApproval");
  me.send({ type: "task.approvePlan", id });
  step(`${id}: plan v1 approved`);

  // Builder: raises a hand, which an admin answers; then a steer it applies.
  await me.wait("the builder", () => task()?.worker?.role === "builder" && sessions.get(id) === task().worker.session);
  const builderSession = sessions.get(id);
  sessionCost(builderSession, 2.5, 40_000, 6_000, "claude-sonnet-5-5");
  // Its status line restarted and counts from zero again: the total stays.
  sessionCost(builderSession, 0.25, 1_000, 100, "claude-sonnet-5-5");
  // A personal session on the same machine: its spend isn't the factory's.
  const personal = crypto.randomUUID();
  toServer({ type: "session.opened", session: { id: personal, agent: "claude", cwd: "/tmp", pid: 2, startedAt: Date.now(), taskId: null } });
  sessionCost(personal, 99, 1, 1);
  await tool(id, "raise_hand", { reason: "needsInput", summary: "Which file?", options: [{ title: "a.txt", detail: "The usual one", recommended: true }] });
  await me.wait("the hand", () => task()?.hand);
  await new Promise((r) => setTimeout(r, 1200));
  me.send({ type: "task.resolveHand", id, option: "a.txt", note: "" });
  await me.wait("the hand down", () => task() && !task().hand);
  step(`${id}: hand raised and resolved`);
  me.send({ type: "task.steer", id, text: "Make it three lines." });
  await me.wait("the change request", () => task()?.changes.length === 1);
  await tool(id, "progress", { applied: ["C1"], step: 1, status: "done" });
  step(`${id}: steered (C1 applied)`);
  await tool(id, "prove", { item: 1, kind: "terminal", summary: "Done.", command: "cat a.txt", output: ["1", "2", "3"] });
  await tool(id, "finish", { summary: "Did it." });

  // Reviewer: one round with a minor finding, passed; then an admin approves and merges it.
  await me.wait("the reviewer", () => task()?.worker?.role === "reviewer" && sessions.get(id) === task().worker.session);
  await tool(id, "submit_review", {
    verdict: "passed", summary: "Fine.", ask: [{ text: "It's done", verdict: "met" }], proofs: [{ text: "It's done", verdict: "met" }],
    findings: [{ kind: "code", severity: "minor", text: "Trailing newline." }],
  });
  await me.wait("review passed", () => task()?.autoReview?.rounds.at(-1)?.verdict === "passed");
  me.send({ type: "task.approveChanges", id });
  await me.wait("approved", () => task()?.reviews.length >= task()?.reviewsNeeded);
  // A low-risk change auto-merges; otherwise an admin merges it.
  await me.wait("auto-merge", () => task()?.state === "merged" || task()?.liveLog === "Merging…", 3000).catch(() => me.send({ type: "task.merge", id }));
  await me.wait("merged", () => task()?.state === "merged");
  step(`${id}: reviewed (1 round, 1 finding) and merged`);

  // What an admin's stats.get says now, for the whole factory and for this goal.
  const after = await statsFor(me);
  const t = after.totals;
  const delta = (k) => t[k] - before.totals[k];
  for (const [k, want] of [["merged", 1], ["handsRaised", 1], ["steers", 1], ["reviewRounds", 1], ["findings", 1], ["approvals", 1], ["planVersions", 1]]) {
    if (delta(k) !== want) throw new Error(`${k} went up by ${delta(k)}, not ${want}`);
  }
  // Factory-wide, the personal session's $99 isn't there: only the planner's and builder's $3.25.
  const spent = Math.round(((after.costTotal?.costUsd ?? 0) - (before.costTotal?.costUsd ?? 0)) * 100) / 100;
  if (spent !== 3.25) throw new Error(`factory-wide cost went up by $${spent}, not $3.25`);
  const mine = await statsFor(me, goal.id);
  const g = mine.totals;
  const want = { merged: 1, handsRaised: 1, steers: 1, reviewRounds: 1, findings: 1, approvals: 1, firstTryApproval: 1, reviewRoundsPerMerge: 1 };
  for (const [k, v] of Object.entries(want)) if (g[k] !== v) throw new Error(`goal ${k} is ${g[k]}, not ${v}`);
  if (!(g.handOpenMedianMs >= 1000)) throw new Error(`the hand was up ${g.handOpenMedianMs}ms`);
  if (mine.handsByReason[0]?.key !== "needsInput") throw new Error(`hands by reason: ${JSON.stringify(mine.handsByReason)}`);
  if (mine.findingsByKind[0]?.key !== "code") throw new Error(`findings by kind: ${JSON.stringify(mine.findingsByKind)}`);
  if (mine.topTasks[0]?.task !== id) throw new Error(`top tasks: ${JSON.stringify(mine.topTasks)}`);
  console.log(`  admin stats.get (goal ${prefix}, 30 days): ${JSON.stringify({ merged: g.merged, handsRaised: g.handsRaised, handOpenMedianMs: g.handOpenMedianMs, steers: g.steers, reviewRounds: g.reviewRounds, findings: g.findings, firstTryApproval: g.firstTryApproval, cycleMedianMs: g.cycleMedianMs })}`);
  step(`admin's stats.get counts the merge, hand, steer, review round and finding (factory-wide +1 each)`);

  // A member is told no.
  const them = app(member);
  await new Promise((r) => (them.feed.onopen = r));
  them.send({ type: "subscribe" });
  await them.wait("their snapshot", () => them.me);
  if (them.me.role === "admin") throw new Error(`${them.me.login} is an admin`);
  them.send({ type: "stats.get", days: 30 });
  await new Promise((r) => setTimeout(r, 1500));
  if (them.stats || them.errors[0] !== "Only admins can see statistics.") throw new Error(`a member got ${JSON.stringify(them.stats ?? them.errors)}`);
  step(`member ${them.me.login}'s stats.get: "${them.errors[0]}"`);
  them.feed.close();

  // GET /api/stats: the same summary for an admin, 403 for a member.
  const api = await fetch(`${base}/api/stats?days=30&goal=${goal.id}`, { headers: auth });
  const body = await api.json();
  if (api.status !== 200 || body.totals.merged !== 1 || body.days !== 30) throw new Error(`admin /api/stats: ${api.status} ${JSON.stringify(body).slice(0, 200)}`);
  const raw = await (await fetch(`${base}/api/stats?days=30&goal=${goal.id}&raw=1`, { headers: auth })).json();
  const kinds = [...new Set(raw.events.map((e) => e.kind))].sort();
  for (const k of ["hand.raised", "hand.resolved", "merged", "plan.approved", "plan.submitted", "review.round", "steer"]) if (!kinds.includes(k)) throw new Error(`raw events lack ${k}: ${kinds}`);
  // Cost: what the planner and builder sessions reported, filed by role and by agent · model.
  const costs = body;
  const role = (k) => costs.costByRole.find((r) => r.key === k);
  if (costs.costTotal?.costUsd !== 3.25 || costs.costTotal.sessions !== 2) throw new Error(`cost total: ${JSON.stringify(costs.costTotal)}`);
  if (role("planner")?.costUsd !== 0.75 || role("planner").tokens !== 13_500) throw new Error(`planner cost: ${JSON.stringify(costs.costByRole)}`);
  if (role("builder")?.costUsd !== 2.5 || role("builder").tokens !== 46_000) throw new Error(`builder cost (a lower reading lowered it?): ${JSON.stringify(costs.costByRole)}`);
  const agentKeys = costs.costByAgent.map((r) => `${r.key}=${r.costUsd}`).join(", ");
  if (agentKeys !== "claude · claude-sonnet-5-5=2.5, claude · claude-opus-5-5=0.75") throw new Error(`cost by agent: ${agentKeys}`);
  if (costs.topTasks.find((r) => r.task === id)?.costUsd !== 3.25) throw new Error(`task cost: ${JSON.stringify(costs.topTasks)}`);
  console.log(`  costByRole: ${JSON.stringify(costs.costByRole)}`);
  console.log(`  costByAgent: ${JSON.stringify(costs.costByAgent)}`);
  step(`cost: $${costs.costTotal.costUsd} over ${costs.costTotal.sessions} sessions (planner $0.75, builder $2.5; the lower reading and the personal session's $99 not counted)`);
  const no = await fetch(`${base}/api/stats?days=30`, { headers: { authorization: `Bearer ${member}` } });
  if (no.status !== 403) throw new Error(`member /api/stats: ${no.status}`);
  step(`GET /api/stats: admin 200 (merged ${body.totals.merged}; raw=1 has ${raw.events.length} events: ${kinds.join(", ")}), member ${no.status} "${await no.text()}"`);
} finally {
  for (const other of others) me.send({ type: "machine.settings", machine: other.id, settings: { ...other.settings, paused: false } });
  await new Promise((r) => setTimeout(r, 500));
  me.feed.close();
  runner.close();
}
console.log("e2e-stats: ok");
process.exit(0);

async function statsFor(c, goal) {
  c.stats = null;
  c.send({ type: "stats.get", days: 30, goal: goal ?? null });
  return c.wait("stats", () => c.stats);
}

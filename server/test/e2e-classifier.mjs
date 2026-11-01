// The risk classifier, end to end against `wrangler dev` and a talking-only runner (like e2e-stats.mjs):
//   node server/test/e2e-classifier.mjs http://localhost:8788
// Turns policy.classifier on (an empty prompt is refused), takes a low-risk task to review, checks the
// reviewer's prompt has the org's Risk classification text, that submit_review without `classification`
// is sent back, and that a high + humanReview grade makes it high with a review needed, a "classifier"
// factor and event, and no auto-merge. Restores the policy after.

const [base = "http://localhost:8788"] = process.argv.slice(2);
const ws = base.replace(/^http/, "ws");
const token = async (as) => (await (await fetch(`${base}/dev/token${as ? `?as=${as}` : ""}`, { method: "POST" })).json()).token;
const admin = await token();
const member = await token(`cls-member-${Date.now() % 100000}`);
const auth = { authorization: `Bearer ${admin}` };

// The runner: opens the sessions it's sent, and makes each one do its role's work through the tools.
const runnerId = `cls-${Date.now() % 100000}`;
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
    toServer({ type: "task.started", taskId: m.taskId, repo: null, repoDir: "/tmp/cls-repo", base: "main", project: null });
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
    if (m.type === "snapshot" || m.type === "policy.updated") c.policy = m.policy;
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

const PROMPT = "Anything that touches refunds, payments or user data needs a person's review.";
const original = structuredClone(await me.wait("the policy", () => me.policy));
try {
  // An enabled classifier with no prompt is refused.
  me.send({ type: "policy.save", policy: { ...original, classifier: { enabled: true, prompt: " " } } });
  await me.wait("the refusal", () => me.errors.length);
  step(`refused without a prompt: ${me.errors.splice(0).join("; ")}`);
  me.send({ type: "policy.save", policy: { ...original, classifier: { enabled: true, prompt: PROMPT } } });
  await me.wait("the classifier on", () => me.policy?.classifier?.enabled);
  step(`policy.classifier = ${JSON.stringify(me.policy.classifier)}`);

  const prefix = `CL${String(Date.now() % 10000).padStart(4, "0")}`.slice(0, 6);
  me.send({ type: "goal.save", goal: { id: "", name: `Classifier ${prefix}`, prefix, color: "#14B8A6", summary: "", lead: "", repos: [], folder: "/tmp/cls-repo", base: "main" } });
  const goal = await me.wait("the goal", () => me.goals.find((g) => g.prefix === prefix));
  me.send({ type: "task.create", goal: goal.id, title: "Tweak the refund copy", brief: "Change the refund confirmation text.", shareable: false, plan: true, tickets: [] });
  const id = (await me.wait("the task", () => [...me.tasks.values()].find((t) => t.goal === goal.id))).id;
  const task = () => me.tasks.get(id);

  await me.wait("the planner", () => task()?.worker?.role === "planner" && sessions.get(id) === task().worker.session);
  await tool(id, "submit_plan", {
    summary: "One step.", steps: [{ text: "Edit the copy", file: "a.txt" }], doneWhen: [{ text: "It's done", proof: "terminal" }],
    risk: { level: "low", reasons: ["A copy change"], areas: [] }, footprint: { files: 1, lines: 3 },
  });
  await me.wait("awaiting approval", () => task()?.state === "awaitingApproval");
  me.send({ type: "task.approvePlan", id });
  await me.wait("the builder", () => task()?.worker?.role === "builder" && sessions.get(id) === task().worker.session);
  await tool(id, "prove", { item: 1, kind: "terminal", summary: "Done.", command: "cat a.txt", output: ["1", "2", "3"] });
  await tool(id, "finish", { summary: "Did it." });

  await me.wait("the reviewer", () => task()?.worker?.role === "reviewer" && sessions.get(id) === task().worker.session);
  const open = opened.filter((o) => o.taskId === id).at(-1);
  const prompt = open.prompt ?? "";
  const at = prompt.indexOf("## Risk classification");
  if (at < 0 || !prompt.includes(PROMPT)) throw new Error("the reviewer prompt has no Risk classification section with the org's text");
  step("reviewer prompt:\n    " + prompt.slice(at, prompt.indexOf("Then call", at)).trim().split("\n").join("\n    "));
  console.log(`  before review: risk ${task().risk.level}, reviewsNeeded ${task().reviewsNeeded}`);

  const review = { verdict: "passed", summary: "Fine.", ask: [{ text: "Copy", verdict: "met" }], proofs: [{ text: "It's done", verdict: "met" }], findings: [] };
  const missing = await tool(id, "submit_review", review).then(() => null, (e) => e.message);
  if (!missing) throw new Error("submit_review without classification passed");
  step(`without classification: ${missing}`);
  await tool(id, "submit_review", { ...review, classification: { level: "high", humanReview: true, reasons: ["Touches the refunds flow customers see"] } });
  await me.wait("review passed", () => task()?.autoReview?.rounds.at(-1)?.verdict === "passed");
  await me.wait("the classification", () => task()?.classification);
  const t = task();
  step(`task.classification = ${JSON.stringify(t.classification)}`);
  step(`task.risk.level = ${t.risk.level}, reviewsNeeded = ${t.reviewsNeeded}`);
  step(`classifier factor = ${JSON.stringify(t.risk.factors.find((f) => f.source === "classifier"))}`);
  step(`event: ${JSON.stringify(t.events.find((e) => e.text.startsWith("classified")))}`);
  if (t.risk.level !== "high" || t.reviewsNeeded < 1 || !t.risk.factors.some((f) => f.source === "classifier")) throw new Error("the classifier didn't gate the task");
  await new Promise((r) => setTimeout(r, 1500));
  if (task().state === "merged") throw new Error("it auto-merged");
  step(`state after 1.5s: ${task().state} (not auto-merged)`);
} finally {
  me.send({ type: "policy.save", policy: original });
  for (const other of others) me.send({ type: "machine.settings", machine: other.id, settings: { ...other.settings, paused: false } });
  await new Promise((r) => setTimeout(r, 500));
  me.feed.close();
  runner.close();
}
console.log("e2e-classifier: ok");
process.exit(0);

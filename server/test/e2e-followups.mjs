// Follow-ups and priority (MF-155), against a local server: a fake runner plays a task's planner,
// builder and reviewer over the wire (as e2e-scout.mjs does) so it reaches review, passed, with two
// minor findings and a major left open. Then, as the web app does when you tick findings and click
// Approve changes: task.followUp for two of them (one at P2) and a note, then task.approveChanges.
// Checks the drafts land in the goal with their priority and followUpOf, inheriting the agent; that a
// second follow-up of the same finding is refused; and that a queued task set to P0 goes to the front.
//   node server/test/e2e-followups.mjs http://localhost:8788
//   node server/test/e2e-followups.mjs http://localhost:8788 serve 600   # stop at review and stay up, to click through the web app
// Run the server with a long MERGE_GRACE_MS so the task stays in review while you look.

const [base = "http://localhost:8788", mode = "test", serveSecs = "600"] = process.argv.slice(2);
const ws = base.replace(/^http/, "ws");
const step = (t) => console.log(`✓ ${t}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const post = (path, body, headers = {}) => fetch(`${base}${path}`, { method: "POST", headers: { "content-type": "application/json", ...headers }, body: JSON.stringify(body) });
async function until(what, ok, ms = 20_000) {
  for (const end = Date.now() + ms; Date.now() < end; await sleep(100)) {
    if (errors.length) throw new Error(`server said: ${errors.splice(0).join("; ")}`);
    const hit = ok();
    if (hit) return hit;
  }
  throw new Error(`timed out waiting for ${what}`);
}

const { token } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();
const feed = new WebSocket(`${ws}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
const tasks = new Map();
let goals = [];
let snapshot = false;
const errors = [];
feed.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "snapshot") { goals = m.goals; snapshot = true; for (const t of m.tasks) tasks.set(t.id, t); }
  if (m.type === "goal.updated") goals = [...goals.filter((g) => g.id !== m.goal.id), m.goal];
  if (m.type === "task.updated") tasks.set(m.task.id, m.task);
  if (m.type === "error") errors.push(m.message);
};
await new Promise((r) => (feed.onopen = r));
const send = (m) => feed.send(JSON.stringify(m));
send({ type: "subscribe" });
await until("the snapshot", () => snapshot);

// The fake machine: every session comes to it.
const runnerId = `followups-mac-${Date.now()}`;
const { code } = await (await post("/api/machines/enroll", {}, { authorization: `Bearer ${token}` })).json();
const enrolled = await (await post("/runner/enroll", { code, runnerId, hostname: runnerId, os: "macos", arch: "arm64", version: "0.0.0-fake" })).json();
const runner = new WebSocket(`${ws}/runner/connect?runner=${runnerId}`, { headers: { authorization: `Bearer ${enrolled.token}` } });
await new Promise((r, j) => { runner.onopen = r; runner.onerror = j; });
const toHub = (m) => runner.send(JSON.stringify(m));
toHub({ type: "hello", runnerId, hostname: runnerId, os: "macos", arch: "arm64", version: "0.0.0-fake", sessions: [], ended: [] });
toHub({ type: "health", health: { cpu: 1, cores: 16, load1: 0.1, memUsed: 1e9, memTotal: 32e9, diskUsed: 1e11, diskTotal: 1e12, uptime: 10, battery: null, agents: [{ name: "claude", version: "2.1.0", loggedIn: true }] } });

const replies = new Map();
const call = (session, tool, args = {}) => new Promise((resolve, reject) => {
  const reqId = crypto.randomUUID();
  replies.set(reqId, (m) => (m.error ? reject(new Error(`${tool}: ${m.error}`)) : resolve(m.result)));
  toHub({ type: "mcp.request", reqId, session, tool, args });
});
let first = null;
const roles = {
  async planner(s) {
    await call(s, "submit_plan", {
      summary: "Add a greeting file.", steps: [{ text: "Write hello.txt", file: "hello.txt" }],
      doneWhen: [{ text: "hello.txt says hello", proof: "terminal" }],
      risk: { level: "low", reasons: ["One new text file."], areas: [] }, footprint: { files: 1, lines: 1 }, otherRepos: [], mockups: [],
    });
  },
  async builder(s) {
    await call(s, "prove", { item: 1, kind: "terminal", summary: "It says hello", command: "cat hello.txt", output: ["hello"] });
    await call(s, "finish", { summary: "Added hello.txt." });
  },
  async reviewer(s) {
    await call(s, "submit_review", {
      verdict: "passed", summary: "Good, with a few things for later.",
      ask: [{ text: "Add a greeting file", verdict: "met" }], proofs: [{ text: "hello.txt says hello", verdict: "met" }],
      findings: [
        { kind: "code", severity: "minor", text: "hello.txt has no trailing newline.", file: "hello.txt:1" },
        { kind: "code", severity: "minor", text: "The greeting isn't capitalised.", file: "hello.txt:1" },
        { kind: "risk", severity: "minor", text: "Nothing checks the file is there at startup.", file: null },
      ],
      fixed: [],
    });
  },
};
runner.onmessage = async (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "ping") return toHub({ type: "pong" });
  if (m.type === "mcp.response") return replies.get(m.reqId)?.(m);
  if (m.type === "session.open" && m.taskId) {
    toHub({ type: "task.started", taskId: m.taskId, repo: null, repoDir: "/tmp/followups-e2e/repo", base: "main", project: null });
    toHub({ type: "session.opened", session: { id: m.id, agent: m.agent, cwd: `/tmp/followups-e2e/${m.taskId}`, pid: 1, startedAt: Date.now(), taskId: m.taskId } });
    const role = /You are the planner/.test(m.prompt) ? "planner" : /You are the builder/.test(m.prompt) ? "builder" : "reviewer";
    await sleep(200);
    // Only the first task plays its roles out; the rest just sit in the queue.
    if (m.taskId === first) roles[role](m.id).catch((err) => errors.push(String(err)));
    return;
  }
  if (m.type === "task.finish") return toHub({ type: "task.finished", taskId: m.taskId, ok: true, pushed: "fallback", owner: null, repo: null, branch: m.branch, base: "main", commit: "abc1234def", reason: null, message: null });
  if (m.type === "task.merge_check") return toHub({ type: "task.merge_check", taskId: m.taskId, ok: true, clean: true, conflicts: [], message: null });
  if (m.type === "task.merge") return toHub({ type: "task.merged", taskId: m.taskId, ok: true, commit: "fedcba9", message: null });
};
await sleep(500);

const prefix = `FU${String(Date.now()).slice(-4)}`;
send({ type: "goal.save", goal: { id: "", name: mode === "serve" ? "Greeting page" : `Follow-ups ${prefix}`, prefix, color: "#2EA043", summary: "A friendly greeting.", lead: "", repos: [], folder: "/tmp/followups-e2e/repo", base: null } });
const goal = await until("the goal", () => goals.find((g) => g.prefix === prefix));
const inGoal = () => [...tasks.values()].filter((t) => t.goal === goal.id);
send({ type: "task.create", goal: goal.id, title: "Add a greeting", brief: "Add hello.txt.", shareable: false, plan: true, tickets: [], agent: "claude", priority: "p1" });
first = (await until("the task", () => inGoal()[0])).id;
if (tasks.get(first).priority !== "p1") throw new Error(`${first} has priority ${tasks.get(first).priority}`);
await until("its plan", () => tasks.get(first).state === "awaitingApproval");
send({ type: "task.approvePlan", id: first });
await until(`${first} to pass review`, () => tasks.get(first).state === "reviewing" && tasks.get(first).autoReview?.rounds.at(-1)?.verdict === "passed", 30_000);
const findings = tasks.get(first).autoReview.findings;
step(`${first} (P1) in review, passed, with ${findings.length} findings open: ${findings.map((f) => `${f.id} ${f.severity}`).join(", ")}`);

if (mode === "serve") {
  step(`serving ${goal.name} (${goal.prefix}): open ${base}/app/#/t/${first}; up for ${serveSecs}s`);
  await sleep(Number(serveSecs) * 1000);
  process.exit(0);
}

// What the web app sends for two ticked minor findings (one moved to P2) and a note, then the approval.
const [a, b] = findings.filter((f) => f.severity === "minor");
send({ type: "task.followUp", id: first, items: [
  { finding: a.id, title: "Add a trailing newline", brief: "", priority: "p3" },
  { finding: b.id, title: "Capitalise the greeting", brief: "", priority: "p2" },
  { title: "Write up the greeting", brief: "A line in the README." },
] });
send({ type: "task.approveChanges", id: first });
const drafts = await until("three follow-ups", () => { const d = inGoal().filter((t) => t.followUpOf); return d.length === 3 && d; });
const by = (from) => drafts.find((t) => t.followUpOf === from) ?? (() => { throw new Error(`no follow-up of ${from}`); })();
const [fa, fb, note] = [by(`${first}#${a.id}`), by(`${first}#${b.id}`), by(first)];
for (const [t, priority] of [[fa, "p3"], [fb, "p2"], [note, null]]) {
  if (t.state !== "drafting" || t.priority !== priority || t.agent !== "claude" || !t.brief.endsWith(`Follow-up from ${first}.`)) throw new Error(`${t.id}: ${JSON.stringify({ state: t.state, priority: t.priority, agent: t.agent, brief: t.brief })}`);
}
if (!fa.brief.startsWith(`> **minor code** in \`hello.txt:1\`: hello.txt has no trailing newline.`)) throw new Error(`${fa.id}'s brief: ${fa.brief}`);
step(`follow-ups ${fa.id} (P3, of ${fa.followUpOf}), ${fb.id} (P2, of ${fb.followUpOf}) and ${note.id} (a note, of ${note.followUpOf}): drafts in ${goal.name}`);
await until("the approval", () => tasks.get(first).reviews.length > 0);
if (!tasks.get(first).events.some((e) => e.text === `made follow-ups ${fa.id}, ${fb.id}, ${note.id}`)) throw new Error("no event on the source task");
step(`${first} approved, and its timeline says it made them`);

send({ type: "task.followUp", id: first, items: [{ finding: a.id, title: "Again", brief: "" }] });
for (const end = Date.now() + 10_000; !errors.length && Date.now() < end; ) await sleep(100);
const refusal = errors.splice(0)[0] ?? "";
if (!refusal.includes(`already has a follow-up: ${fa.id}`)) throw new Error(`refused with: ${refusal}`);
step(`a second follow-up of ${first}#${a.id} is refused: "${refusal}"`);

// Priority on the queue: of three queued tasks, the last, set to P0, goes to the front.
const queued = [];
for (const title of ["Queue one", "Queue two", "Queue three"]) {
  send({ type: "task.create", goal: goal.id, title, brief: "Sit in the queue.", shareable: false, plan: false, tickets: [], agent: "claude" });
  const t = await until(title, () => inGoal().find((x) => x.title === title));
  // Held for an hour, so no session takes it out of the queue; each behind the last.
  send({ type: "task.queue", id: t.id, startAt: Date.now() + 3600_000 });
  await until(`${t.id} queued`, () => tasks.get(t.id).state === "planning");
  queued.push(t.id);
}
const order = () => queued.map((id) => tasks.get(id)).sort((x, y) => x.queueRank - y.queueRank).map((t) => t.id);
const last = queued[2];
send({ type: "task.edit", id: last, priority: "p0" });
await until(`${last} at the front`, () => tasks.get(last).priority === "p0" && order()[0] === last);
step(`${last} set to P0 went to the front: ${order().join(", ")}`);
send({ type: "task.edit", id: fa.id, clearPriority: true });
await until(`${fa.id}'s priority off`, () => tasks.get(fa.id).priority == null);
step(`${fa.id}'s priority taken off`);
for (const id of [...queued, fa.id, fb.id, note.id]) send({ type: "task.cancel", id });
await sleep(500);
console.log("all good");
process.exit(0);

// The closed state (MF-189), against a local server: a fake runner plays a "scan and propose tickets"
// task's planner, which calls propose_tasks instead of writing a plan. Checks the task closes (no
// worker, no hand), its proposals are drafts in the goal, a change of agent or priority is refused
// with "It's closed", and Retry picks it back up in planning with a new planner.
//   node server/test/e2e-closed.mjs http://localhost:8788
//   node server/test/e2e-closed.mjs http://localhost:8788 keep   # stop once it's closed (and a draft cancelled), to look at it in the apps

const [base = "http://localhost:8788", mode = "test"] = process.argv.slice(2);
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
/** Sends `msg` and expects the server to refuse it with a message matching `pattern`. */
const refused = async (what, msg, pattern) => {
  send(msg);
  for (const end = Date.now() + 5000; !errors.length && Date.now() < end;) await sleep(100);
  const said = errors.splice(0)[0];
  if (!said || !pattern.test(said)) throw new Error(`${what} wasn't refused as expected (got ${JSON.stringify(said)})`);
  return said;
};

// The fake machine: every session comes to it.
const runnerId = `closed-mac-${Date.now()}`;
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
let scan = null;
const prefix = `CL${String(Date.now()).slice(-4)}`;
let planners = 0;
let reply = null;
const killed = new Set();
runner.onmessage = async (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "ping") return toHub({ type: "pong" });
  if (m.type === "mcp.response") return replies.get(m.reqId)?.(m);
  if (m.type === "session.kill") {
    killed.add(m.id);
    return toHub({ type: "session.ended", end: { id: m.id, cause: "killed", code: null, signal: null, detail: null, at: Date.now(), lastOutput: [], by: "factory" } });
  }
  if (m.type === "session.open" && m.taskId) {
    toHub({ type: "task.started", taskId: m.taskId, repo: null, repoDir: "/tmp/closed-e2e/repo", base: "main", project: null });
    toHub({ type: "session.opened", session: { id: m.id, agent: m.agent, cwd: `/tmp/closed-e2e/${m.taskId}`, pid: 1, startedAt: Date.now(), taskId: m.taskId } });
    // The first planner scans and proposes; the one Retry starts just sits there, planning.
    if (m.taskId.startsWith(`${prefix}-`) && /You are the planner/.test(m.prompt) && ++planners === 1) {
      await sleep(200);
      call(m.id, "propose_tasks", { tasks: [
        { title: "Add a settings screen", brief: "The iOS app has no settings screen.", priority: "p2" },
        { title: "Show machine names", brief: "Machines show their ids, not their names." },
      ] }).then((r) => (reply = r), (err) => errors.push(String(err)));
    }
  }
};
await sleep(500);

send({ type: "goal.save", goal: { id: "", name: mode === "keep" ? "iOS gaps" : `Closed ${prefix}`, prefix, color: "#6B7280", summary: "Scan and propose.", lead: "", repos: [], folder: "/tmp/closed-e2e/repo", base: null } });
const goal = await until("the goal", () => goals.find((g) => g.prefix === prefix));
const inGoal = () => [...tasks.values()].filter((t) => t.goal === goal.id);
send({ type: "task.create", goal: goal.id, title: "Scan the iOS app for missing features", brief: "Scan the iOS app and propose tickets.", shareable: false, plan: true, tickets: [], agent: "claude" });
scan = (await until("the task", () => inGoal()[0])).id;
step(`${scan} created and planning`);

// propose_tasks from planning closes it: no plan, no worker, no hand.
const closed = await until(`${scan} closed`, () => { const t = tasks.get(scan); return t.state === "closed" && !t.worker && t; });
if (closed.hand) throw new Error(`${scan} has a hand up: ${closed.hand.summary}`);
if (closed.plan.length) throw new Error(`${scan} has a plan`);
const drafts = await until("two drafts", () => { const d = inGoal().filter((t) => t.id !== scan); return d.length === 2 && d; });
for (const d of drafts) if (d.state !== "drafting") throw new Error(`${d.id} is ${d.state}, not a draft`);
if (!closed.events.some((e) => /^closed it: proposed /.test(e.text))) throw new Error(`no "closed it" event on ${scan}`);
await until("the tool's reply", () => reply);
if (!/closed/.test(reply.summary)) throw new Error(`propose_tasks said: ${reply.summary}`);
step(`${scan} closed with no worker and no hand; drafts ${drafts.map((d) => d.id).join(", ")}; it was told: ${reply.summary}`);
// The factory kills a session it closed a few seconds after its last word.
await until("its session killed", () => killed.size > 0, 15_000);
await sleep(1000);
if (tasks.get(scan).hand || tasks.get(scan).state !== "closed") throw new Error(`${scan} didn't stay closed with its hand down once its session ended`);
step(`its session ended and it stayed closed, hand down`);

// Finished: it can't change agent or priority, and there's no Cancel.
step(`agent change refused: ${await refused("agent change", { type: "task.edit", id: scan, agent: "codex" }, /^It's closed/)}`);
step(`priority refused: ${await refused("priority", { type: "task.edit", id: scan, priority: "p1" }, /^It's closed/)}`);
step(`cancel refused: ${await refused("cancel", { type: "task.cancel", id: scan }, /already finished/)}`);

if (mode === "keep") {
  // One of its proposals cancelled, so Closed sits beside Cancelled.
  send({ type: "task.cancel", id: drafts[1].id });
  await until(`${drafts[1].id} cancelled`, () => tasks.get(drafts[1].id).state === "cancelled");
  step(`kept: ${scan} closed, ${drafts[1].id} cancelled, ${drafts[0].id} a draft in ${goal.name}`);
  process.exit(0);
}

// Retry picks it back up in planning, with a new planner.
send({ type: "task.retry", id: scan });
const back = await until(`${scan} planning again`, () => { const t = tasks.get(scan); return t.state === "planning" && t.worker?.role === "planner" && t; });
if (!back.events.some((e) => e.text === "picked it back up (planning)")) throw new Error(`no "picked it back up" event`);
step(`Retry: ${scan} is planning again with a new planner (${back.worker.session})`);

send({ type: "task.cancel", id: scan });
await until(`${scan} cancelled`, () => tasks.get(scan).state === "cancelled");
console.log("e2e-closed passed");
process.exit(0);

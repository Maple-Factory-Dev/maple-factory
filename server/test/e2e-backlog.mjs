// The backlog: a planned task sent there starts no session, even after a pump; queue and retry are
// refused. Steering it plans it again; sent back and approved from the backlog, it builds. A draft
// sent there can have its brief edited, and is then sent to planning.
//   node server/test/e2e-backlog.mjs http://localhost:8788 <repo folder>
// Needs a real runner whose agents.toml has the `scripted` agent (test/scripted-agent.mjs), and a
// local repo whose origin is a bare repo.

const [base = "http://localhost:8788", folder] = process.argv.slice(2);
if (!folder) throw new Error("usage: e2e-backlog.mjs <server> <repo folder>");
const ws = base.replace(/^http/, "ws");
const { token } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();

const feed = new WebSocket(`${ws}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
const tasks = new Map();
let goals = null;
let errors = [];
let poke = null;
feed.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "snapshot") { goals = m.goals; for (const t of m.tasks) tasks.set(t.id, t); }
  if (m.type === "task.updated") tasks.set(m.task.id, m.task);
  if (m.type === "goal.updated") goals = [...goals.filter((g) => g.id !== m.goal.id), m.goal];
  if (m.type === "error") errors.push(m.message);
  poke?.();
};
const send = (m) => feed.send(JSON.stringify(m));
const wait = async (what, test, ms = 30000) => {
  const deadline = Date.now() + ms;
  for (;;) {
    const hit = test();
    if (hit) return hit;
    if (errors.length) throw new Error(`server said: ${errors.join("; ")}`);
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((r) => { poke = r; setTimeout(r, 250); });
  }
};
const pause = (ms) => new Promise((r) => setTimeout(r, ms));
const step = (text) => console.log(`✓ ${text}`);
/** Sends `m` and expects the server to refuse it with a message matching `pattern`. */
const refused = async (m, pattern) => {
  errors = [];
  send(m);
  const deadline = Date.now() + 10000;
  while (!errors.length && Date.now() < deadline) await pause(100);
  const said = errors.splice(0).join("; ");
  if (!pattern.test(said)) throw new Error(`${m.type} on ${m.id}: expected ${pattern}, got "${said}"`);
  return said;
};
/** Nothing runs on it: no worker, no new session event, still in the backlog. */
const parked = async (id) => {
  const before = tasks.get(id).events.length;
  // An edit pumps the queue; a few seconds is plenty for a pump to start a session.
  send({ type: "task.edit", id, shareable: !tasks.get(id).shareable });
  await pause(6000);
  const t = tasks.get(id);
  const started = t.events.slice(before).filter((e) => e.text.startsWith("started on "));
  if (t.state !== "backlog" || t.worker || t.waiting || started.length) throw new Error(`${id} ran: ${t.state} ${JSON.stringify(t.worker)} ${t.events.slice(before).map((e) => e.text).join(" / ")}`);
  return t;
};

await new Promise((r) => (feed.onopen = r));
send({ type: "subscribe" });
await wait("snapshot", () => goals);

const prefix = `BL${Date.now() % 100000}`.slice(0, 7);
send({ type: "goal.save", goal: { id: "", name: `Backlog ${prefix}`, prefix, color: "#8B949E", summary: "Backlog test", lead: "", folder, base: "main" } });
const goal = await wait("goal", () => goals.find((g) => g.prefix === prefix));
step(`goal ${goal.name}`);

// 1. A planned task sent to the backlog: nothing runs on it, and queue and retry are refused.
const id = `${prefix}-1`;
send({ type: "task.create", goal: goal.id, title: "Say hello, later", brief: "Add hello.txt with a greeting.", shareable: false, plan: true, tickets: [], agent: "scripted" });
let t = await wait(`${id} plan`, () => tasks.get(id)?.state === "awaitingApproval" && !tasks.get(id).worker && tasks.get(id), 60000);
step(`${id}: plan v${t.planVersion} waiting for approval`);
send({ type: "task.backlog", id });
t = await wait(`${id} in the backlog`, () => tasks.get(id)?.state === "backlog" && tasks.get(id));
if (t.events.at(-1).text !== "sent it to the backlog") throw new Error(`last event: ${t.events.at(-1).text}`);
step(`${id}: sent it to the backlog (plan v${t.planVersion} kept, ${t.approvals.length} approvals)`);
await parked(id);
step(`${id}: after a pump, still in the backlog with no session`);
step(`task.queue refused: "${await refused({ type: "task.queue", id, before: "top" }, /Pick it up first/)}"`);
step(`task.retry refused: "${await refused({ type: "task.retry", id }, /backlog/)}"`);
step(`task.edit of its brief refused: "${await refused({ type: "task.edit", id, brief: "Something else" }, /only change while it's a draft/)}"`);

// 2. Steering it from the backlog plans it again.
const version = t.planVersion;
send({ type: "task.steer", id, text: "Greet the world, not just hello." });
await wait(`${id} planning`, () => tasks.get(id)?.state === "planning");
t = await wait(`${id} plan v${version + 1}`, () => tasks.get(id)?.state === "awaitingApproval" && tasks.get(id).planVersion > version && tasks.get(id), 60000);
step(`${id}: steered from the backlog, re-planned to v${t.planVersion}`);

// 3. Back to the backlog, then approved from there: it builds.
send({ type: "task.backlog", id });
await wait(`${id} in the backlog again`, () => tasks.get(id)?.state === "backlog");
await parked(id);
step(`${id}: in the backlog again, no session`);
send({ type: "task.approvePlan", id });
t = await wait(`${id} builder`, () => tasks.get(id)?.worker?.role === "builder" && tasks.get(id), 60000);
step(`${id}: approved from the backlog → ${t.state}, builder session ${t.worker.session}`);
t = await wait(`${id} in review`, () => tasks.get(id)?.state === "reviewing" && tasks.get(id), 180000);
step(`${id}: built and pushed → ${t.state}`);

// 4. A draft in the backlog: its brief changes, then it goes to planning.
const draft = `${prefix}-2`;
send({ type: "task.create", goal: goal.id, title: "Say goodbye, someday", brief: "Add bye.txt.", shareable: false, plan: false, tickets: [], agent: "scripted" });
await wait(`${draft} draft`, () => tasks.get(draft)?.state === "drafting");
send({ type: "task.backlog", id: draft });
await wait(`${draft} in the backlog`, () => tasks.get(draft)?.state === "backlog");
await parked(draft);
step(`${draft}: draft sent to the backlog, no session`);
step(`approving a plan it doesn't have refused: "${await refused({ type: "task.approvePlan", id: draft }, /isn't planned yet/)}"`);
send({ type: "task.edit", id: draft, brief: "Add bye.txt with a farewell." });
await wait(`${draft} edited`, () => tasks.get(draft)?.brief === "Add bye.txt with a farewell.");
step(`${draft}: brief edited in the backlog`);
send({ type: "task.plan", id: draft });
t = await wait(`${draft} planned`, () => tasks.get(draft)?.state === "awaitingApproval" && tasks.get(draft), 60000);
step(`${draft}: sent to planning from the backlog → plan v${t.planVersion} waiting for approval`);

console.log(`\n${tasks.get(id).events.map((e) => `  ${e.who}: ${e.text.split("\n")[0]}`).join("\n")}\n`);
send({ type: "task.cancel", id: draft });
feed.close();
process.exit(0);

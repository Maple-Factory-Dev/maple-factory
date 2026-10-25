// Splitting a planned task: it keeps its first step and goes back to the planner to rescope; the
// rest becomes a new task, planned on its own.
//   node server/test/e2e-split.mjs http://localhost:8788 <goal prefix>
// Needs the scripted agent (its planner writes a two-step plan).

const [base = "http://localhost:8788", prefix = "GRT"] = process.argv.slice(2);
const { token } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();
const feed = new WebSocket(`${base.replace(/^http/, "ws")}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
const tasks = new Map();
let goals = [];
const errors = [];
let poke = null;
feed.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "snapshot") { goals = m.goals; for (const t of m.tasks) tasks.set(t.id, t); }
  if (m.type === "task.updated") tasks.set(m.task.id, m.task);
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
const step = (text) => console.log(`✓ ${text}`);

await new Promise((r) => (feed.onopen = r));
send({ type: "subscribe" });
await wait("snapshot", () => goals.length);
const goal = goals.find((g) => g.prefix === prefix) ?? (() => { throw new Error(`no goal ${prefix}`); })();
const before = new Set(tasks.keys());
send({ type: "task.create", goal: goal.id, title: "Split me", brief: "Add hello.txt with a greeting.", shareable: false, plan: true, tickets: [], agent: "scripted" });
const t = await wait("plan", () => [...tasks.values()].find((x) => !before.has(x.id) && x.state === "awaitingApproval"));
const { id } = t;
step(`${id} planned with ${t.plan.length} steps`);

send({ type: "task.split", id, parts: 2 });
const part = await wait("the new task", () => [...tasks.values()].find((x) => x.splitFrom === id));
step(`${part.id} split off: "${part.title}"`);
if (!part.brief.includes(t.plan[1].text)) throw new Error("the new task's brief doesn't name its steps");
const original = await wait("rescope", () => tasks.get(id)?.state === "planning" && tasks.get(id));
step(`${id} went back to the planner: ${original.changes.at(-1).text}`);
await wait("the new task planned", () => tasks.get(part.id)?.state === "awaitingApproval");
step(`${part.id} got its own plan`);

for (const x of [id, part.id]) send({ type: "task.cancel", id: x });
await wait("cancelled", () => tasks.get(id)?.state === "cancelled" && tasks.get(part.id)?.state === "cancelled");
step("cancelled both");
process.exit(0);

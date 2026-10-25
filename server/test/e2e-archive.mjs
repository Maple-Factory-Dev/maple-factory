// Archiving a goal with unfinished tasks:
//   node server/test/e2e-archive.mjs http://localhost:8788
// Checks: without saying what to do with them it's refused; "cancel" cancels them and archives;
// "finish" archives and leaves them as they were.

const [base = "http://localhost:8788"] = process.argv.slice(2);
const { token } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();
const ws = new WebSocket(`${base.replace(/^http/, "ws")}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
let goals = null;
const tasks = new Map();
let errors = [];
ws.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "snapshot") { goals = m.goals; for (const t of m.tasks) tasks.set(t.id, t); }
  if (m.type === "goal.updated") goals = [...goals.filter((g) => g.id !== m.goal.id), m.goal];
  if (m.type === "task.updated") tasks.set(m.task.id, m.task);
  if (m.type === "error") errors.push(m.message);
};
const send = (m) => ws.send(JSON.stringify(m));
const wait = async (what, test, ms = 10000) => {
  const deadline = Date.now() + ms;
  for (;;) {
    const hit = test();
    if (hit) return hit;
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 100));
  }
};
const step = (text) => console.log(`✓ ${text}`);

await new Promise((r) => (ws.onopen = r));
send({ type: "subscribe" });
await wait("snapshot", () => goals);

/** A goal with one unfinished task: a draft, which no machine picks up. */
const goalWithWork = async (prefix) => {
  send({ type: "goal.save", goal: { id: "", name: `Archive ${prefix}`, prefix, color: "#F59E0B", summary: "", lead: "", repos: [], folder: "/tmp/archive-test", base: null } });
  const goal = await wait("goal", () => goals.find((g) => g.prefix === prefix));
  send({ type: "task.create", goal: goal.id, title: "Unfinished", brief: "Add hello.txt.", shareable: false, plan: false, tickets: [] });
  const task = await wait("task", () => tasks.get(`${prefix}-1`));
  return { goal, task };
};

const n = Date.now() % 1000;
const a = await goalWithWork(`AR${n}`);
send({ type: "goal.archive", id: a.goal.id, archived: true });
const refused = await wait("refusal", () => errors[0]);
if (goals.find((g) => g.id === a.goal.id).archived) throw new Error("it archived anyway");
step(`archiving with ${a.task.id} unfinished and no choice is refused: "${refused}"`);

send({ type: "goal.archive", id: a.goal.id, archived: true, unfinished: "cancel" });
await wait("archived", () => goals.find((g) => g.id === a.goal.id).archived);
await wait("cancelled", () => tasks.get(a.task.id).state === "cancelled");
step(`"cancel" cancelled ${a.task.id} ("${tasks.get(a.task.id).events.at(-1).text}") and archived the goal`);

const b = await goalWithWork(`AF${n}`);
const before = tasks.get(b.task.id).state;
send({ type: "goal.archive", id: b.goal.id, archived: true, unfinished: "finish" });
await wait("archived", () => goals.find((g) => g.id === b.goal.id).archived);
await new Promise((r) => setTimeout(r, 300));
if (tasks.get(b.task.id).state !== before) throw new Error(`${b.task.id} went from ${before} to ${tasks.get(b.task.id).state}`);
step(`"finish" archived the goal and left ${b.task.id} ${before}`);
send({ type: "task.cancel", id: b.task.id });
await new Promise((r) => setTimeout(r, 300));
process.exit(0);

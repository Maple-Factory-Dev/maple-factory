// A planner that asks a question and a builder that raises a hand, both answered from the "app":
//   node server/test/e2e-interactive.mjs http://localhost:8788 <goal prefix>
// Needs the scripted agent (test/scripted-agent.mjs) and a goal on a local repo (e2e-factory.mjs makes one).

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
const goal = goals.find((g) => g.prefix === prefix) ?? goals.find((g) => g.folder);
const before = new Set(tasks.keys());
send({ type: "task.create", goal: goal.id, title: "Greet, asking first", brief: "Add a greeting. [ask] [hand]", shareable: false, plan: true, tickets: [], agent: "scripted" });
const id = await wait("task", () => [...tasks.keys()].find((k) => !before.has(k)));

let t = await wait("question", () => tasks.get(id)?.question && tasks.get(id));
step(`${id}: the planner asks "${t.question.text}" (${t.question.options.join(" / ")})`);
send({ type: "task.answer", id, text: "Casual" });
t = await wait("plan", () => tasks.get(id)?.state === "awaitingApproval" && tasks.get(id));
if (!t.planSummary.includes("Casual")) throw new Error(`the plan didn't get the answer: ${t.planSummary}`);
step(`answered; the plan has it: "${t.planSummary.slice(-30)}"`);

send({ type: "task.approvePlan", id });
t = await wait("hand", () => tasks.get(id)?.hand && tasks.get(id));
step(`the builder raises a hand: ${t.hand.summary} [${t.hand.options.map((o) => o.title).join(" / ")}]`);
send({ type: "task.resolveHand", id, option: "A new file", note: "Keep it simple." });
t = await wait("merged", () => tasks.get(id)?.state === "merged" && tasks.get(id), 90000);
step(`resolved; it built, passed review and merged (${t.events.filter((e) => e.who === "reviewer").length} reviewer events)`);
process.exit(0);

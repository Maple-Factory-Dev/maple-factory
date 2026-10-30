// The planner suggests a clearer title with its plan: the task keeps its title until the plan is
// approved, then takes the new one (and says so). An approver can keep the current title instead, a
// rename through task.edit drops the suggestion, and a plan without a title changes nothing.
//   node server/test/e2e-rename.mjs http://localhost:8788 <repo folder>
// Needs a real runner whose agents.toml has the `scripted` agent (test/scripted-agent.mjs), and a
// local repo whose origin is a bare repo.

const [base = "http://localhost:8788", folder] = process.argv.slice(2);
if (!folder) throw new Error("usage: e2e-rename.mjs <server> <repo folder>");
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
const step = (text) => console.log(`✓ ${text}`);
const expect = (ok, what) => { if (!ok) throw new Error(what); };

await new Promise((r) => (feed.onopen = r));
send({ type: "subscribe" });
await wait("snapshot", () => goals);

const prefix = `RN${Date.now() % 100000}`.slice(0, 7);
send({ type: "goal.save", goal: { id: "", name: `Rename ${prefix}`, prefix, color: "#8B949E", summary: "Rename test", lead: "", folder, base: "main" } });
const goal = await wait("goal", () => goals.find((g) => g.prefix === prefix));
step(`goal ${goal.name}`);

/** A task whose scripted planner submits a plan; waits for it to be waiting for approval. */
const planned = async (n, title, brief) => {
  const id = `${prefix}-${n}`;
  send({ type: "task.create", goal: goal.id, title, brief, shareable: false, plan: true, tickets: [], agent: "scripted" });
  return wait(`${id} plan`, () => tasks.get(id)?.state === "awaitingApproval" && !tasks.get(id).worker && tasks.get(id), 60000);
};
const renamedEvent = (t) => t.events.find((e) => e.text.startsWith("renamed it from"));

// 1. A plan with a title: the old title stays until approval, then the task takes the new one.
let t = await planned(1, "hello thing", "Add hello.txt. [rename: Add a hello.txt greeting]");
expect(t.title === "hello thing", `${t.id} renamed before approval: ${t.title}`);
expect(t.suggestedTitle === "Add a hello.txt greeting", `${t.id} suggestedTitle: ${t.suggestedTitle}`);
step(`${t.id}: plan v${t.planVersion} waiting; title still "${t.title}", suggestedTitle "${t.suggestedTitle}"`);
send({ type: "task.approvePlan", id: t.id });
t = await wait(`${t.id} approved`, () => tasks.get(t.id)?.state === "building" && tasks.get(t.id));
const ev = renamedEvent(t);
expect(t.title === "Add a hello.txt greeting", `${t.id} title after approval: ${t.title}`);
expect(ev?.text === 'renamed it from "hello thing"', `${t.id} rename event: ${ev?.text}`);
expect(t.suggestedTitle == null, `${t.id} suggestedTitle after approval: ${t.suggestedTitle}`);
step(`${t.id}: approved → title "${t.title}", event "${ev.who}: ${ev.text}", suggestedTitle ${t.suggestedTitle ?? null}`);
send({ type: "task.cancel", id: t.id });

// 2. Approved with keepTitle: the person's title stays and the suggestion is dropped.
t = await planned(2, "keep me", "Add hello.txt. [rename: A planner's other name]");
expect(t.suggestedTitle === "A planner's other name", `${t.id} suggestedTitle: ${t.suggestedTitle}`);
send({ type: "task.approvePlan", id: t.id, keepTitle: true });
t = await wait(`${t.id} approved`, () => tasks.get(t.id)?.state === "building" && tasks.get(t.id));
expect(t.title === "keep me" && t.suggestedTitle == null && !renamedEvent(t), `${t.id} after keepTitle: ${t.title} / ${t.suggestedTitle}`);
expect(t.events.some((e) => e.text === "kept the title"), `${t.id} has no "kept the title" event`);
step(`${t.id}: approved with keepTitle → title "${t.title}", "kept the title" logged, suggestedTitle ${t.suggestedTitle ?? null}`);
send({ type: "task.cancel", id: t.id });

// 3. Renamed through task.edit first: the person's name wins.
t = await planned(3, "vague", "Add hello.txt. [rename: The planner's name]");
expect(t.suggestedTitle === "The planner's name", `${t.id} suggestedTitle: ${t.suggestedTitle}`);
send({ type: "task.edit", id: t.id, title: "My own name" });
t = await wait(`${t.id} edited`, () => tasks.get(t.id)?.title === "My own name" && tasks.get(t.id));
expect(t.suggestedTitle == null, `${t.id} suggestedTitle after task.edit: ${t.suggestedTitle}`);
send({ type: "task.approvePlan", id: t.id });
t = await wait(`${t.id} approved`, () => tasks.get(t.id)?.state === "building" && tasks.get(t.id));
expect(t.title === "My own name" && !renamedEvent(t), `${t.id} after approval: ${t.title}`);
step(`${t.id}: renamed by task.edit, suggestion dropped; approved → title "${t.title}"`);
send({ type: "task.cancel", id: t.id });

// 4. A plan without a title changes nothing.
t = await planned(4, "plain title", "Add hello.txt.");
expect(t.suggestedTitle == null, `${t.id} suggestedTitle without a title: ${t.suggestedTitle}`);
send({ type: "task.approvePlan", id: t.id });
t = await wait(`${t.id} approved`, () => tasks.get(t.id)?.state === "building" && tasks.get(t.id));
expect(t.title === "plain title" && !renamedEvent(t), `${t.id} after approval: ${t.title}`);
step(`${t.id}: plan without a title → no suggestion; approved → title "${t.title}" unchanged`);
send({ type: "task.cancel", id: t.id });

await new Promise((r) => setTimeout(r, 500));
feed.close();
process.exit(0);

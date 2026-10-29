// Live updates reach every subscribed app, not just the one that acted:
//   node server/test/e2e-live.mjs http://localhost:8788 <repo folder>
// Needs the scripted agent (test/scripted-agent.mjs) on a runner owned by the dev user, and a local
// repo whose origin is a bare repo. One app makes a goal and a task and answers the agent; a second
// app, signed in as a teammate, only watches. It must hear goal.updated and every task.updated as the
// task moves from planning to building, raises a hand, has it resolved and goes on to review.

const [base = "http://localhost:8788", folder] = process.argv.slice(2);
if (!folder) throw new Error("usage: e2e-live.mjs <server> <repo folder>");

function connect(login) {
  const c = { goals: [], tasks: new Map(), heard: [], errors: [], poke: null };
  c.ready = (async () => {
    const { token } = await (await fetch(`${base}/dev/token${login ? `?as=${login}` : ""}`, { method: "POST" })).json();
    c.feed = new WebSocket(`${base.replace(/^http/, "ws")}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
    c.feed.onmessage = (e) => {
      const m = JSON.parse(e.data);
      if (m.type === "snapshot") { c.goals = m.goals; for (const t of m.tasks) c.tasks.set(t.id, t); c.snapshot = true; }
      if (m.type === "goal.updated") { c.goals = [...c.goals.filter((g) => g.id !== m.goal.id), m.goal]; c.heard.push({ goal: m.goal }); }
      if (m.type === "task.updated") { c.tasks.set(m.task.id, m.task); c.heard.push({ task: m.task }); }
      if (m.type === "error") c.errors.push(m.message);
      c.poke?.();
    };
    await new Promise((r) => (c.feed.onopen = r));
    c.send({ type: "subscribe" });
    await c.wait("snapshot", () => c.snapshot);
  })();
  c.send = (m) => c.feed.send(JSON.stringify(m));
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

const me = connect(null);
const watcher = connect("live-watcher");
await me.ready;
await watcher.ready;

const prefix = `LV${Date.now() % 10000}`;
me.send({ type: "goal.save", goal: { id: "", name: `Live ${prefix}`, prefix, color: "#2F80ED", summary: "Live updates", lead: "", folder, base: "main" } });
const goal = await watcher.wait("goal.updated", () => watcher.heard.find((h) => h.goal?.prefix === prefix)?.goal);
step(`the watcher heard goal.updated for a new goal: ${goal.name} (${goal.id})`);

me.send({ type: "goal.save", goal: { ...goal, name: `Live ${prefix} renamed` } });
await watcher.wait("rename", () => watcher.goals.find((g) => g.id === goal.id)?.name.endsWith("renamed"));
step("and for its rename");

me.send({ type: "task.create", goal: goal.id, title: "Greet live", brief: "Add a greeting. [hand]", shareable: true, plan: true, tickets: [], agent: "scripted" });
const id = await watcher.wait("task", () => watcher.heard.find((h) => h.task?.goal === goal.id)?.task.id);
step(`the watcher heard ${id} arrive`);

// What the watcher saw of the task, one entry per change of state or hand.
const seen = () => {
  const out = [];
  for (const { task } of watcher.heard) {
    if (task?.id !== id) continue;
    const label = task.hand ? `${task.state}+hand` : task.state;
    if (out.at(-1) !== label) out.push(label);
  }
  return out;
};

await watcher.wait("planning", () => seen().includes("planning"));
await me.wait("plan", () => me.tasks.get(id)?.state === "awaitingApproval");
await watcher.wait("awaitingApproval", () => seen().includes("awaitingApproval"));
step(`the watcher saw it plan: ${seen().join(" → ")}`);

me.send({ type: "task.approvePlan", id });
await watcher.wait("building", () => seen().includes("building"));
const hand = await watcher.wait("hand", () => watcher.tasks.get(id)?.hand, 60000);
step(`the watcher saw it build and raise a hand: "${hand.summary}"`);

me.send({ type: "task.resolveHand", id, option: "A new file", note: "Keep it simple." });
await watcher.wait("hand resolved", () => !watcher.tasks.get(id)?.hand);
step("the watcher saw the hand go once it was resolved");

await watcher.wait("reviewing", () => seen().includes("reviewing"), 90000);
const states = seen();
const order = ["planning", "awaitingApproval", "building", "reviewing"];
const firsts = order.map((s) => states.findIndex((x) => x === s || x === `${s}+hand`));
if (firsts.some((i) => i < 0) || firsts.some((i, n) => n && i < firsts[n - 1])) throw new Error(`out of order: ${states.join(" → ")}`);
if (!states.some((s) => s.endsWith("+hand"))) throw new Error("never saw the hand");
step(`every change reached the watcher, in order: ${states.join(" → ")}`);
console.log(`  (${watcher.heard.filter((h) => h.task?.id === id).length} task.updated messages)`);

me.send({ type: "task.cancel", id });
me.send({ type: "goal.archive", id: goal.id, archived: true });
await new Promise((r) => setTimeout(r, 500));
process.exit(0);

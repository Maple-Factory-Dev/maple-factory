// Mentions:
//   node server/test/e2e-mentions.mjs http://localhost:8788
// Checks: alice's comment "@bob can you look? cc @nobody" is saved with mentions ["bob"] (nobody
// isn't a member), her own @alice isn't a mention, and a comment with none carries no mentions.

const [base = "http://localhost:8788"] = process.argv.slice(2);
const connect = async (as) => {
  const { token } = await (await fetch(`${base}/dev/token${as ? `?as=${as}` : ""}`, { method: "POST" })).json();
  const ws = new WebSocket(`${base.replace(/^http/, "ws")}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
  const app = { ws, goals: [], tasks: [], updates: [], me: null, errors: [] };
  ws.onmessage = (e) => {
    const m = JSON.parse(e.data);
    if (m.type === "snapshot") { app.goals = m.goals; app.tasks = m.tasks; app.me = m.me; }
    if (m.type === "goal.updated") app.goals = [...app.goals.filter((g) => g.id !== m.goal.id), m.goal];
    if (m.type === "task.updated") { app.tasks = [...app.tasks.filter((t) => t.id !== m.task.id), m.task]; app.updates.push(m.task); }
    if (m.type === "error") app.errors.push(m.message);
  };
  await new Promise((r) => (ws.onopen = r));
  ws.send(JSON.stringify({ type: "subscribe" }));
  await wait("snapshot", () => app.me);
  return app;
};
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
const send = (app, m) => app.ws.send(JSON.stringify(m));

const alice = await connect("alice");
const bob = await connect("bob");
const prefix = `MN${Date.now() % 1000}`;
send(alice, { type: "goal.save", goal: { id: "", name: `Mentions ${prefix}`, prefix, color: "#14B8A6", summary: "", lead: "", team: "", repos: [], folder: "/tmp/mentions", base: null } });
const goal = await wait("goal", () => alice.goals.find((g) => g.prefix === prefix));
send(alice, { type: "task.create", goal: goal.id, title: "Mention me", brief: "", tickets: [], shareable: false, plan: false });
const task = await wait("task", () => alice.tasks.find((t) => t.goal === goal.id));
step(`alice made ${task.id}`);

send(alice, { type: "task.comment", id: task.id, text: "@bob can you look? cc @nobody @alice" });
const comment = await wait("bob's task.updated", () => bob.updates.find((t) => t.id === task.id && t.comments.length === 1)?.comments[0]);
if (JSON.stringify(comment.mentions) !== JSON.stringify(["bob"])) throw new Error(`mentions are ${JSON.stringify(comment.mentions)}, not ["bob"]`);
step(`"${comment.text}" from ${comment.author} mentions ${JSON.stringify(comment.mentions)}`);

send(alice, { type: "task.comment", id: task.id, text: "Mail bob@example.com, nobody here." });
const plain = await wait("second comment", () => bob.updates.find((t) => t.id === task.id && t.comments.length === 2)?.comments[1]);
if (plain.mentions?.length) throw new Error(`a comment with no mentions has ${JSON.stringify(plain.mentions)}`);
step("an email address isn't a mention");

if (alice.errors.length) throw new Error(alice.errors.join("; "));
send(alice, { type: "goal.archive", id: goal.id, archived: true, unfinished: "cancel" });
await new Promise((r) => setTimeout(r, 300));
process.exit(0);

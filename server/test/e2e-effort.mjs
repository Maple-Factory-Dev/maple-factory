// Efforts: tasks that share a name, like an epic. Created into one, edited in and out, and split parts inherit it.
//   node server/test/e2e-effort.mjs http://localhost:8788 <goal prefix>
// Needs the scripted agent (its planner writes a two-step plan, so one of them can be split).

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
const EFFORT = "Login revamp";

await new Promise((r) => (feed.onopen = r));
send({ type: "subscribe" });
await wait("snapshot", () => goals.length);
const goal = goals.find((g) => g.prefix === prefix) ?? (() => { throw new Error(`no goal ${prefix}`); })();
const before = new Set(tasks.keys());
const created = async (title, extra) => {
  send({ type: "task.create", goal: goal.id, title, brief: "Add hello.txt with a greeting.", shareable: false, plan: false, tickets: [], agent: "scripted", ...extra });
  return wait(title, () => [...tasks.values()].find((x) => !before.has(x.id) && x.title === title));
};

const ids = [];
for (const [i, name] of ["Login form", "Session cookie", "Password reset"].entries()) {
  // Padding and doubled spaces are tidied away, so one effort is one name.
  const t = await created(name, { effort: i === 2 ? `  Login   revamp ` : EFFORT });
  if (t.effort !== EFFORT) throw new Error(`${t.id} has effort ${JSON.stringify(t.effort)}`);
  ids.push(t.id);
}
step(`created ${ids.join(", ")} in "${EFFORT}"`);

const loose = await created("Remember me", {});
if (loose.effort != null) throw new Error(`${loose.id} shouldn't have an effort yet`);
send({ type: "task.edit", id: loose.id, effort: EFFORT });
const edited = await wait("edited in", () => tasks.get(loose.id)?.effort === EFFORT && tasks.get(loose.id));
if (!edited.events.some((e) => e.text === `put it in effort ${EFFORT}`)) throw new Error("no event for joining the effort");
ids.push(loose.id);
step(`${loose.id} edited into it`);

send({ type: "task.edit", id: ids[1], effort: "" });
const cleared = await wait("cleared", () => tasks.get(ids[1])?.effort == null && tasks.get(ids[1]));
if (!cleared.events.some((e) => e.text === `took it out of effort ${EFFORT}`)) throw new Error("no event for leaving the effort");
step(`${ids[1]} taken out with an empty string`);

send({ type: "task.plan", id: ids[0] });
await wait("plan", () => tasks.get(ids[0])?.state === "awaitingApproval");
// It can change in any state, not just drafting.
send({ type: "task.edit", id: ids[0], effort: "Other" });
await wait("moved while planned", () => tasks.get(ids[0])?.effort === "Other");
send({ type: "task.edit", id: ids[0], effort: EFFORT });
await wait("moved back", () => tasks.get(ids[0])?.effort === EFFORT);
step(`${ids[0]} changed effort while awaiting approval`);

send({ type: "task.split", id: ids[0], parts: 2 });
const part = await wait("split part", () => [...tasks.values()].find((x) => x.splitFrom === ids[0]));
if (part.effort !== EFFORT) throw new Error(`split part ${part.id} has effort ${JSON.stringify(part.effort)}`);
step(`split part ${part.id} inherited "${EFFORT}"`);

// What a fresh client sees.
const fresh = await (async () => {
  const ws = new WebSocket(`${base.replace(/^http/, "ws")}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
  await new Promise((r) => (ws.onopen = r));
  const snap = new Promise((r) => (ws.onmessage = (e) => { const m = JSON.parse(e.data); if (m.type === "snapshot") r(m); }));
  ws.send(JSON.stringify({ type: "subscribe" }));
  const m = await snap;
  ws.close();
  return new Map(m.tasks.map((t) => [t.id, t]));
})();
const inEffort = [...fresh.values()].filter((t) => !before.has(t.id) && t.effort === EFFORT).map((t) => t.id).sort();
const want = [ids[0], ids[2], ids[3], part.id].sort();
if (JSON.stringify(inEffort) !== JSON.stringify(want)) throw new Error(`snapshot has ${inEffort} in the effort, want ${want}`);
if (fresh.get(ids[1]).effort != null) throw new Error(`${ids[1]} still has an effort in the snapshot`);
step(`a new snapshot has ${want.join(", ")} in "${EFFORT}" and ${ids[1]} in none`);

for (const x of [...ids, part.id]) send({ type: "task.cancel", id: x });
await wait("cancelled", () => [...ids, part.id].every((x) => tasks.get(x)?.state === "cancelled"));
step("cancelled them all");
process.exit(0);

// A goal's due date through goal.save:
//   node server/test/e2e-goal-due.mjs http://localhost:8788
// Checks: a due date round-trips in goal.updated and a fresh snapshot; a later one replaces it;
// null clears it; a bad value (-5, "soon", 1.5) is refused and leaves the goal as it was.

const [base = "http://localhost:8788"] = process.argv.slice(2);
const { token } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();
const connect = async () => {
  const ws = new WebSocket(`${base.replace(/^http/, "ws")}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
  const c = { ws, goals: null, errors: [] };
  ws.onmessage = (e) => {
    const m = JSON.parse(e.data);
    if (m.type === "snapshot") c.goals = m.goals;
    if (m.type === "goal.updated") c.goals = [...c.goals.filter((g) => g.id !== m.goal.id), m.goal];
    if (m.type === "error") c.errors.push(m.message);
  };
  await new Promise((r) => (ws.onopen = r));
  ws.send(JSON.stringify({ type: "subscribe" }));
  await wait("snapshot", () => c.goals);
  return c;
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
const day = (ms) => new Date(ms).toISOString().slice(0, 10);

const c = await connect();
const send = (m) => c.ws.send(JSON.stringify(m));
const prefix = `DUE${Date.now() % 1000}`;
const due = Date.UTC(2026, 10, 19, 12);
send({ type: "goal.save", goal: { id: "", name: `Due ${prefix}`, prefix, color: "#F59E0B", summary: "", lead: "", repos: [], folder: "/tmp/due-test", base: null, due } });
let goal = await wait("goal", () => c.goals.find((g) => g.prefix === prefix));
if (goal.due !== due) throw new Error(`goal.updated has due ${goal.due}, not ${due}`);
const fresh = await connect();
if (fresh.goals.find((g) => g.id === goal.id)?.due !== due) throw new Error("the snapshot lost the due date");
fresh.ws.close();
step(`set: due ${day(due)} in goal.updated and in a fresh snapshot`);

const later = Date.UTC(2026, 11, 3, 12);
send({ type: "goal.save", goal: { ...goal, due: later } });
goal = await wait("extended", () => c.goals.find((g) => g.id === goal.id && g.due === later));
step(`extended: due moved to ${day(later)}`);

for (const bad of [-5, "soon", 1.5]) {
  const seen = c.errors.length;
  send({ type: "goal.save", goal: { ...goal, due: bad } });
  const refused = await wait(`refusal of ${JSON.stringify(bad)}`, () => c.errors[seen]);
  step(`bad due ${JSON.stringify(bad)} refused: "${refused}"`);
}
if (c.goals.find((g) => g.id === goal.id).due !== later) throw new Error("a refused save changed the due date");

send({ type: "goal.save", goal: { ...goal, due: null } });
goal = await wait("cleared", () => c.goals.find((g) => g.id === goal.id && g.due === null));
const { due: _, ...noDue } = goal;
send({ type: "goal.save", goal: { ...noDue, summary: "no due field" } });
goal = await wait("saved without due", () => c.goals.find((g) => g.id === goal.id && g.summary === "no due field"));
if (goal.due !== null) throw new Error(`leaving due out gave ${goal.due}`);
const after = await connect();
if (after.goals.find((g) => g.id === goal.id).due != null) throw new Error("the snapshot still has a due date");
after.ws.close();
step("cleared: due null (and left out) is no due date, in goal.updated and a fresh snapshot");

send({ type: "goal.archive", id: goal.id, archived: true });
await new Promise((r) => setTimeout(r, 300));
process.exit(0);

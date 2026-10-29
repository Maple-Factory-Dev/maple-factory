// What the web app sends to compose tasks and keep a scratchpad:
//   node server/test/e2e-web-compose.mjs http://localhost:8788
// Checks, with the web app's own messages: task.create plan:false makes a draft; task.edit changes its
// title and brief; task.plan sends it to planning; task.cancel drops another draft; and a note saved
// with note.save, then saved again with the taskId it became, keeps that link in a fresh snapshot.

const [base = "http://localhost:8788"] = process.argv.slice(2);
const connect = async () => {
  const { token } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();
  const ws = new WebSocket(`${base.replace(/^http/, "ws")}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
  const app = { ws, me: null, goals: null, tasks: new Map(), notes: null, errors: [] };
  ws.onmessage = (e) => {
    const m = JSON.parse(e.data);
    if (m.type === "snapshot") { app.me = m.me; app.goals = m.goals; app.notes = m.notes; app.tasks = new Map(m.tasks.map((t) => [t.id, t])); }
    if (m.type === "goal.updated") app.goals = [...app.goals.filter((g) => g.id !== m.goal.id), m.goal];
    if (m.type === "task.updated") app.tasks.set(m.task.id, m.task);
    if (m.type === "note.updated") app.notes = [...app.notes.filter((n) => n.id !== m.note.id), m.note];
    if (m.type === "error") app.errors.push(m.message);
  };
  await new Promise((r) => (ws.onopen = r));
  ws.send(JSON.stringify({ type: "subscribe" }));
  await wait("snapshot", () => app.notes);
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
const noErrors = (app) => { if (app.errors.length) throw new Error(`the server refused: ${app.errors.join("; ")}`); };

const me = await connect();
const prefix = `W${Math.random().toString(36).slice(2, 5).toUpperCase()}`;
send(me, { type: "goal.save", goal: { id: "", name: `Web compose ${prefix}`, prefix, color: "#7C5CE0", summary: "", lead: "", repos: [], folder: "/tmp/web-compose", base: null } });
const goal = await wait("goal.updated", () => me.goals.find((g) => g.prefix === prefix));
step(`made goal ${goal.name}`);

// The composer's Save draft.
const title = `Draft from the web ${prefix}`;
send(me, { type: "task.create", goal: goal.id, title, brief: "First go.", shareable: false, plan: false, tickets: [], repo: null });
const draft = await wait("the draft's task.updated", () => [...me.tasks.values()].find((t) => t.title === title && t.owner === me.me.login));
noErrors(me);
if (draft.state !== "drafting") throw new Error(`a plan:false task is ${draft.state}, not drafting`);
step(`task.create plan:false made ${draft.id}, drafting`);

// The draft's editor.
send(me, { type: "task.edit", id: draft.id, title: `${title}, edited`, brief: "Second go, with **markdown**." });
await wait("the edit", () => me.tasks.get(draft.id).brief === "Second go, with **markdown**.");
noErrors(me);
if (me.tasks.get(draft.id).title !== `${title}, edited`) throw new Error("task.edit didn't change the title");
step("task.edit changed its title and brief");

// Send to planning.
send(me, { type: "task.plan", id: draft.id });
await wait("planning", () => me.tasks.get(draft.id).state === "planning");
noErrors(me);
step("task.plan sent it to planning");

// Cancel draft.
const doomed = `Doomed draft ${prefix}`;
send(me, { type: "task.create", goal: goal.id, title: doomed, brief: "", shareable: true, plan: false, tickets: [], repo: null });
const other = await wait("the second draft", () => [...me.tasks.values()].find((t) => t.title === doomed));
send(me, { type: "task.cancel", id: other.id });
await wait("cancelled", () => me.tasks.get(other.id).state === "cancelled");
noErrors(me);
step(`task.cancel dropped draft ${other.id}`);

// A scratchpad note, turned into a task: the web app saves it again with the task it became.
const id = crypto.randomUUID();
const note = { id, owner: me.me.login, title: `Idea ${prefix}`, body: "Jotted on the web.", updatedAt: 0, taskId: null };
send(me, { type: "note.save", note });
await wait("note.updated", () => me.notes.find((n) => n.id === id));
const fromNote = `Idea ${prefix}`;
send(me, { type: "task.create", goal: goal.id, title: fromNote, brief: note.body, shareable: false, plan: true, tickets: [], repo: null });
const task = await wait("the note's task", () => [...me.tasks.values()].find((t) => t.title === fromNote));
send(me, { type: "note.save", note: { ...me.notes.find((n) => n.id === id), taskId: task.id } });
await wait("the link", () => me.notes.find((n) => n.id === id)?.taskId === task.id);
noErrors(me);
step(`note "${note.title}" became ${task.id} (${task.state})`);

const again = await connect();
if (again.notes.find((n) => n.id === id)?.taskId !== task.id) throw new Error("a new snapshot lost the note's taskId");
if (again.tasks.get(draft.id)?.state !== "planning") throw new Error("a new snapshot doesn't have the planned draft");
step("a new connection's snapshot has the note's link and the planned draft");

process.exit(0);

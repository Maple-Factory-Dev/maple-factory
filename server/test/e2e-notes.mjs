// Deleting scratchpad notes:
//   node server/test/e2e-notes.mjs http://localhost:8788
// Checks: a saved note reaches its owner's apps; someone else's note.delete for it is ignored; the owner's
// delete sends note.removed, and a fresh connection's snapshot no longer has the note.

const [base = "http://localhost:8788"] = process.argv.slice(2);
const connect = async (as) => {
  const { token } = await (await fetch(`${base}/dev/token${as ? `?as=${as}` : ""}`, { method: "POST" })).json();
  const ws = new WebSocket(`${base.replace(/^http/, "ws")}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
  const app = { ws, notes: null, me: null, removed: [], errors: [], seen: [] };
  ws.onmessage = (e) => {
    const m = JSON.parse(e.data);
    app.seen.push(m.type);
    if (m.type === "snapshot") { app.notes = m.notes; app.me = m.me; }
    if (m.type === "note.updated") app.notes = [...app.notes.filter((n) => n.id !== m.note.id), m.note];
    if (m.type === "note.removed") { app.removed.push(m.id); app.notes = app.notes.filter((n) => n.id !== m.id); }
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

const me = await connect();
const other = await connect("notes2");
const id = crypto.randomUUID();
send(me, { type: "note.save", note: { id, owner: me.me.login, title: `Doomed ${id.slice(0, 4)}`, body: "Delete me.", updatedAt: 0, taskId: null } });
const note = await wait("note.updated", () => me.notes.find((n) => n.id === id));
step(`saved "${note.title}" for ${note.owner}`);

send(other, { type: "note.delete", id });
await new Promise((r) => setTimeout(r, 300));
if (me.removed.includes(id) || other.removed.includes(id)) throw new Error("someone else's delete removed the note");
if (!(await connect()).notes.some((n) => n.id === id)) throw new Error("someone else's delete removed the note from the snapshot");
step(`${other.me.login}'s delete for it is ignored`);

send(me, { type: "note.delete", id });
await wait("note.removed", () => me.removed.includes(id));
step("my delete sends note.removed");

const again = await connect();
if (again.notes.some((n) => n.id === id)) throw new Error("a new snapshot still has the note");
step("a new connection's snapshot no longer has it");

process.exit(0);

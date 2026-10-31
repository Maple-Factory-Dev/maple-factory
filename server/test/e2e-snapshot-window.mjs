// The snapshot window (MF-212), against a local server: seeds a goal with hundreds of tasks, ages most of
// them into merged or cancelled long ago (POST /dev/age-tasks), then checks a fresh connection's snapshot
// holds only the unfinished tasks and those finished in the last 14 days, its tallies still count every
// task, `tasks.older` pages back through the rest until `more` is false, and `task.get` returns an old
// task by ID, both answered to the asking connection only. Prints the snapshot's size before and after.
//   node server/test/e2e-snapshot-window.mjs http://localhost:8788
//   node server/test/e2e-snapshot-window.mjs http://localhost:8788 keep   # leave the goal there, to look at in the apps

const [base = "http://localhost:8788", mode = "test"] = process.argv.slice(2);
const ws = base.replace(/^http/, "ws");
const step = (t) => console.log(`✓ ${t}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const DAY = 86_400_000;
const assert = (ok, what) => { if (!ok) throw new Error(what); };

const { token } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();

/** A feed connection that keeps everything it's sent, and the snapshot's raw size. */
async function connect() {
  const socket = new WebSocket(`${ws}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
  const c = { socket, tasks: new Map(), goals: [], snapshot: null, snapshotBytes: 0, pages: [], updates: [], errors: [] };
  socket.onmessage = (e) => {
    const m = JSON.parse(e.data);
    if (m.type === "snapshot") { c.snapshot = m; c.snapshotBytes = Buffer.byteLength(e.data); c.goals = m.goals; for (const t of m.tasks) c.tasks.set(t.id, t); }
    if (m.type === "goal.updated") c.goals = [...c.goals.filter((g) => g.id !== m.goal.id), m.goal];
    if (m.type === "task.updated") { c.tasks.set(m.task.id, m.task); c.updates.push(m.task.id); }
    if (m.type === "tasks.page") c.pages.push(m);
    if (m.type === "error") c.errors.push(m);
  };
  await new Promise((r, j) => { socket.onopen = r; socket.onerror = j; });
  c.send = (m) => socket.send(JSON.stringify(m));
  c.until = async (what, ok, ms = 30_000) => {
    for (const end = Date.now() + ms; Date.now() < end; await sleep(50)) { const hit = ok(); if (hit) return hit; }
    throw new Error(`timed out waiting for ${what}`);
  };
  c.send({ type: "subscribe" });
  await c.until("the snapshot", () => c.snapshot);
  return c;
}

const me = await connect();
const prefix = `SW${String(Date.now() % 10000).padStart(4, "0")}`;
me.send({ type: "goal.save", goal: { id: "", name: `Snapshot window ${prefix}`, prefix, color: "#14B8A6", summary: "", lead: "", repos: [], folder: "/tmp/snapshot-window", base: "main" } });
const goal = await me.until("the goal", () => me.goals.find((g) => g.prefix === prefix));

// 400 drafts, each with a brief about the size of a real task's plan and events.
const N = 400;
const brief = "A task for the snapshot window e2e. ".repeat(110);
for (let i = 0; i < N; i++) me.send({ type: "task.create", goal: goal.id, title: `Seeded task ${i}`, brief, shareable: false, plan: false, tickets: [] });
const ours = () => [...me.tasks.values()].filter((t) => t.goal === goal.id);
await me.until(`${N} tasks`, () => ours().length === N, 120_000);
step(`seeded ${N} tasks in ${goal.prefix}`);

// Before: every task is a draft, so the snapshot sends all of them, as every snapshot did before MF-212.
const before = await connect();
const beforeOurs = before.snapshot.tasks.filter((t) => t.goal === goal.id).length;
assert(beforeOurs === N, `the snapshot should hold all ${N} drafts, held ${beforeOurs}`);
before.socket.close();

// Age them: 4 stay drafts, 10 merged and 6 cancelled in the last 14 days, 300 merged and 80 cancelled long ago.
const now = Date.now();
const ids = ours().map((t) => t.id).sort((a, b) => a.localeCompare(b, "en", { numeric: true }));
const plan = ids.map((id, i) => {
  if (i < 4) return null;
  if (i < 14) return { id, state: "merged", updatedAt: now - 2 * DAY - i * 60_000 };
  if (i < 20) return { id, state: "cancelled", updatedAt: now - 13 * DAY };
  if (i < 320) return { id, state: "merged", updatedAt: now - 15 * DAY - i * 3_600_000 };
  return { id, state: "cancelled", updatedAt: now - 20 * DAY - i * 3_600_000 };
}).filter(Boolean);
const aged = await fetch(`${base}/dev/age-tasks`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ tasks: plan }) });
assert(aged.ok, `age-tasks: ${aged.status} ${await aged.text()}`);
const old = new Set(plan.filter((p) => p.updatedAt < now - 14 * DAY).map((p) => p.id));
step(`aged ${plan.length}: 16 finished in the last 14 days, ${old.size} finished long ago`);

// After: a fresh connection's snapshot.
const after = await connect();
const other = await connect(); // a second connection of the same person, which mustn't see the answers
const sent = after.snapshot.tasks.filter((t) => t.goal === goal.id);
assert(sent.length === 20, `the snapshot should hold 4 open + 16 recent, held ${sent.length}`);
assert(sent.every((t) => !old.has(t.id)), "the snapshot holds a task finished long ago");
step(`the snapshot holds ${sent.length} of the goal's ${N} tasks: the 4 open and 16 finished in the last 14 days`);

const tally = after.snapshot.tallies?.find((t) => t.goal === goal.id);
assert(tally && tally.merged === 310 && tally.cancelled === 86 && tally.closed === 0 && tally.total === N, `tallies: ${JSON.stringify(tally)}`);
assert(after.snapshot.olderTasks >= old.size, `olderTasks: ${after.snapshot.olderTasks}`);
step(`tallies count every task: ${JSON.stringify(tally)}; olderTasks ${after.snapshot.olderTasks}`);
console.log(`  snapshot size: ${(before.snapshotBytes / 1024).toFixed(0)} KiB before (every task), ${(after.snapshotBytes / 1024).toFixed(0)} KiB after (the window), ${(100 - (after.snapshotBytes / before.snapshotBytes) * 100).toFixed(0)}% smaller`);

// tasks.older, a page at a time, until there are no more.
const paged = [];
let cursor = null;
for (let page = 1; ; page++) {
  after.send({ type: "tasks.older", goal: goal.id, before: cursor?.updatedAt ?? null, beforeId: cursor?.id ?? null, limit: 50 });
  const reply = await after.until(`page ${page}`, () => after.pages[page - 1]);
  assert(reply.goal === goal.id, "the page names another goal");
  assert(reply.tasks.every((t) => old.has(t.id)), "a page holds a task the snapshot sent");
  paged.push(...reply.tasks);
  cursor = reply.tasks.at(-1);
  if (!reply.more) { step(`tasks.older paged back through ${paged.length} old finished tasks in ${page} pages; the last says more: false`); break; }
  assert(reply.tasks.length === 50, `a page that has more should be full, held ${reply.tasks.length}`);
}
assert(paged.length === old.size && new Set(paged.map((t) => t.id)).size === old.size, `paged ${paged.length}, expected ${old.size}`);
for (let i = 1; i < paged.length; i++) assert(paged[i - 1].updatedAt >= paged[i].updatedAt, "pages aren't newest first");

// task.get: an old task by ID; an unknown one is an error tied to it.
const oldest = paged.at(-1).id;
after.send({ type: "task.get", id: oldest });
await after.until("task.get's answer", () => after.updates.includes(oldest));
step(`task.get returned ${oldest}, finished ${Math.round((now - after.tasks.get(oldest).updatedAt) / DAY)} days ago`);
after.send({ type: "task.get", id: `${prefix}-99999` });
const missing = await after.until("task.get's refusal", () => after.errors.find((e) => e.requestId === `task.get:${prefix}-99999`));
step(`task.get of an unknown ID: "${missing.message}"`);

await sleep(500);
assert(other.pages.length === 0 && !other.updates.includes(oldest), "the other connection saw an answer it didn't ask for");
step("the other connection saw neither answer");

if (mode !== "keep") {
  // Leave nothing behind: archive the goal (its tasks are all finished or drafts).
  for (const id of ids.slice(0, 4)) me.send({ type: "task.cancel", id });
  me.send({ type: "goal.archive", id: goal.id, archived: true });
}
await sleep(300);
for (const c of [me, after, other]) c.socket.close();
console.log("e2e-snapshot-window: all good");
process.exit(0);

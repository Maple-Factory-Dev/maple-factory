// The queue: order and schedules, against `wrangler dev` and one talking-only runner (enrolled here,
// like test/fake-runner.mjs) set to one session at a time:
//   node server/test/e2e-queue.mjs http://localhost:8788
// Its sessions never run, so a task holds the slot until it's cancelled. Checks: with the slot
// taken, tasks queue in order and the last one moved to the top starts first; a scheduled task
// reads `Scheduled` and stays queued with the slot free, then starts from the hub's alarm alone; a
// draft queued with a time is held until then; with the slot taken, a forced task starts anyway
// (two sessions on the one-slot machine) and its flag clears, but a running or finished task can't
// be forced and a teammate's forced task doesn't take the lent slot of a full machine; a finished
// (cancelled) task can't be queued.
// (e2e-cancel checks the same of a merged one.)

const [base = "http://localhost:8788"] = process.argv.slice(2);
const ws = base.replace(/^http/, "ws");
const { token } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();
const auth = { authorization: `Bearer ${token}` };

// The runner: enrolls, says hello and its health, and ignores the sessions it's sent.
const runnerId = `queue-${Date.now() % 100000}`;
const { code } = await (await fetch(`${base}/api/machines/enroll`, { method: "POST", headers: auth })).json();
const enrolled = await (await fetch(`${base}/runner/enroll`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ code, runnerId, hostname: runnerId, os: "macos", arch: "arm64", version: "0.0.0-fake" }),
})).json();
const runner = new WebSocket(`${ws}/runner/connect?runner=${runnerId}`, { headers: { authorization: `Bearer ${enrolled.token}` } });
await new Promise((r, j) => { runner.onopen = r; runner.onerror = j; });
const opened = [];
runner.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "session.open") opened.push(m.taskId);
};
runner.send(JSON.stringify({ type: "hello", runnerId, hostname: runnerId, os: "macos", arch: "arm64", version: "0.0.0-fake", sessions: [], ended: [] }));
runner.send(JSON.stringify({ type: "health", health: { cpu: 5, cores: 10, load1: 0.5, memUsed: 8e9, memTotal: 32e9, diskUsed: 2e11, diskTotal: 1e12, uptime: 1000, battery: null, agents: [{ name: "claude", version: "2.1.0", loggedIn: true }] } }));

const feed = new WebSocket(`${ws}/client/connect`, { headers: auth });
const tasks = new Map();
let goals = [];
let machines = [];
let errors = [];
let poke = null;
feed.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "snapshot") { goals = m.goals; machines = m.machines; for (const t of m.tasks) tasks.set(t.id, t); }
  if (m.type === "goal.updated") goals = [...goals.filter((g) => g.id !== m.goal.id), m.goal];
  if (m.type === "machine.updated") machines = [...machines.filter((x) => x.id !== m.machine.id), m.machine];
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
const refused = async (what, msg, pattern) => {
  send(msg);
  await new Promise((r) => setTimeout(r, 1500));
  const said = errors.shift();
  if (!said || !pattern.test(said)) throw new Error(`${what} wasn't refused (got ${JSON.stringify(said)})`);
  errors = [];
  return said;
};

await new Promise((r) => (feed.onopen = r));
send({ type: "subscribe" });
const machine = await wait("the runner", () => machines.find((x) => x.id === runnerId && x.online));
// Every other machine of ours paused, so this one is the only slot.
for (const other of machines.filter((x) => x.id !== runnerId && x.owner === machine.owner)) {
  send({ type: "machine.settings", machine: other.id, settings: { capacity: null, teamSlots: 0, lendIdle: false, loadCap: 0.85, paused: true, pausedUntil: null } });
}
send({ type: "machine.settings", machine: runnerId, settings: { capacity: 1, teamSlots: 0, lendIdle: false, loadCap: 0.85, paused: false, pausedUntil: null } });
await new Promise((r) => setTimeout(r, 500));
step(`${runnerId} connected, one session at a time`);

const prefix = `QX${Date.now() % 1000}`;
send({ type: "goal.save", goal: { id: "", name: `Queue ${prefix}`, prefix, color: "#3B82F6", summary: "Queue order", lead: "", folder: "/tmp/queue-test", base: "main" } });
const goal = await wait("goal", () => goals.find((g) => g.prefix === prefix));
let n = 0;
const create = (title, plan = true) => {
  send({ type: "task.create", goal: goal.id, title, brief: title, shareable: false, plan, tickets: [], agent: "claude" });
  return `${prefix}-${++n}`;
};
const running = (id) => tasks.get(id)?.worker && tasks.get(id);
const queued = () => [...tasks.values()].filter((t) => t.goal === goal.id && t.state === "planning" && !t.worker).sort((a, b) => a.queueRank - b.queueRank).map((t) => t.id);
const cancel = async (id) => {
  send({ type: "task.cancel", id });
  await wait(`${id} cancelled`, () => tasks.get(id)?.state === "cancelled" && !tasks.get(id).worker);
};

// ---- order ----
const a = create("First");
await wait(`${a} started`, () => running(a));
const b = create("Second");
const c = create("Third");
const d = create("Fourth");
await wait("three queued", () => queued().length === 3 && [b, c, d].every((id) => tasks.get(id)?.waiting));
step(`${a} has the slot; queued ${queued().join(", ")} (${tasks.get(b).waiting})`);
send({ type: "task.queue", id: d, before: "top" });
await wait(`${d} at the top`, () => queued()[0] === d);
if (!tasks.get(d).events.some((e) => e.text === "moved it to the top of the queue")) throw new Error("no event for the move");
step(`moved ${d} to the top: ${queued().join(", ")}`);
await cancel(a);
await wait(`${d} started`, () => running(d));
if (running(b) || running(c)) throw new Error("an older task started in its place");
if (opened.at(-1) !== d) throw new Error(`the runner was last sent ${opened.at(-1)}`);
step(`slot freed: ${d} started before the older ${b} and ${c}`);

// ---- scheduled ----
const at = Date.now() + 3000;
send({ type: "task.queue", id: b, before: "top", startAt: at });
await wait(`${b} scheduled`, () => tasks.get(b)?.startAt === at);
await cancel(c);
await cancel(d);
const held = await wait(`${b} held`, () => /^Scheduled/.test(tasks.get(b)?.waiting ?? "") && tasks.get(b));
if (held.worker || Date.now() >= at) throw new Error(`${b} wasn't held: ${JSON.stringify(held.worker)}`);
step(`slot free, ${b} stays queued: "${held.waiting}"`);
const started = await wait(`${b} started from the alarm`, () => running(b), 15000);
const late = started.worker.startedAt - at;
if (late < 0) throw new Error(`${b} started ${-late}ms early`);
if (started.startAt != null) throw new Error("its schedule wasn't cleared");
step(`${b} started ${late}ms after its time, from the alarm (nothing else sent), schedule cleared`);
await cancel(b);

// ---- a draft with a time ----
const e = create("Draft for tonight", false);
await wait(`${e} drafted`, () => tasks.get(e)?.state === "drafting");
const at2 = Date.now() + 3000;
send({ type: "task.queue", id: e, startAt: at2 });
const drafted = await wait(`${e} held`, () => tasks.get(e)?.state === "planning" && /^Scheduled/.test(tasks.get(e).waiting ?? "") && tasks.get(e));
if (drafted.worker) throw new Error(`${e} started early`);
step(`${e}: queued from drafting with a time; no planner yet ("${drafted.waiting}")`);
const planned = await wait(`${e} planner`, () => running(e), 15000);
if (planned.worker.role !== "planner" || planned.worker.startedAt < at2) throw new Error(`${e}: ${JSON.stringify(planned.worker)}`);
step(`${e}: its planner started at its time`);

// ---- start now ----
const f = create("Later");
const at3 = Date.now() + 3600e3;
send({ type: "task.queue", id: f, startAt: at3 });
await wait(`${f} scheduled`, () => tasks.get(f)?.startAt === at3);
send({ type: "task.queue", id: f, before: "top", clearSchedule: true });
await wait(`${f} cleared`, () => tasks.get(f)?.startAt == null && queued()[0] === f && !/^Scheduled/.test(tasks.get(f).waiting ?? ""));
step(`${f}: Start now cleared its schedule and put it first`);
await cancel(e);
await wait(`${f} started`, () => running(f));
await cancel(f);

// ---- force ----
const g = create("Holder");
await wait(`${g} started`, () => running(g));
const h = create("Forced");
await wait(`${h} waiting`, () => /free slot/.test(tasks.get(h)?.waiting ?? ""));
step(`${g} has the slot; ${h}: "${tasks.get(h).waiting}"`);
send({ type: "task.queue", id: h, force: true });
const forced = await wait(`${h} forced`, () => running(h));
if (opened.at(-1) !== h) throw new Error(`the runner was last sent ${opened.at(-1)}`);
const live = [...tasks.values()].filter((t) => t.worker?.machine === runnerId).map((t) => t.id);
if (live.length !== 2) throw new Error(`${runnerId} runs ${live.join(", ")}`);
if (forced.force != null) throw new Error("its force flag wasn't cleared");
if (!forced.events.some((e) => e.text === "ran it now, over its machine's slot limit")) throw new Error("no event for the force");
step(`${h}: forced, session.open sent; ${runnerId} (1 slot) runs ${live.join(" and ")}; force is ${forced.force ?? null}`);
step(`${h}: forcing it again is refused: "${await refused("force running", { type: "task.queue", id: h, force: true }, /already running/)}"`);
step(`${a}: forcing a cancelled task is refused: "${await refused("force cancelled", { type: "task.queue", id: a, force: true }, /finished/)}"`);

// A teammate's forced task: this machine lends one team slot, but its one slot is taken (twice
// over), so it stays off it.
send({ type: "machine.settings", machine: runnerId, settings: { capacity: 1, teamSlots: 1, lendIdle: false, loadCap: 0.85, paused: false, pausedUntil: null } });
await wait("a team slot lent", () => machines.find((x) => x.id === runnerId)?.settings?.teamSlots === 1);
const { token: samToken } = await (await fetch(`${base}/dev/token?as=sam-maple`, { method: "POST" })).json();
const sam = new WebSocket(`${ws}/client/connect`, { headers: { authorization: `Bearer ${samToken}` } });
const samTasks = new Map();
sam.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "snapshot") for (const t of m.tasks) samTasks.set(t.id, t);
  if (m.type === "task.updated") samTasks.set(m.task.id, m.task);
  if (m.type === "error") errors.push(`sam: ${m.message}`);
  poke?.();
};
await new Promise((r) => (sam.onopen = r));
sam.send(JSON.stringify({ type: "subscribe" }));
const known = new Set(tasks.keys());
sam.send(JSON.stringify({ type: "task.create", goal: goal.id, title: "Sam's", brief: "Sam's", shareable: true, plan: true, tickets: [], agent: "claude" }));
const theirs = await wait("sam's task", () => [...samTasks.values()].find((t) => t.goal === goal.id && !known.has(t.id) && t.state === "planning" && t.waiting));
sam.send(JSON.stringify({ type: "task.queue", id: theirs.id, force: true }));
await wait(`${theirs.id} forced`, () => samTasks.get(theirs.id)?.force === true);
await new Promise((r) => setTimeout(r, 3000));
const still = samTasks.get(theirs.id);
if (still.worker?.machine === runnerId || opened.includes(theirs.id)) throw new Error(`${theirs.id} took ${runnerId}, which lends no slots`);
step(`${theirs.id} (sam-maple's, forced): not on ${runnerId}, which lends 1 team slot but is full; "${still.waiting}"${still.worker ? ` (running on sam's own ${still.worker.machine})` : ""}`);
sam.send(JSON.stringify({ type: "task.cancel", id: theirs.id }));
await wait(`${theirs.id} cancelled`, () => samTasks.get(theirs.id)?.state === "cancelled");
await cancel(g);
await cancel(h);
send({ type: "machine.settings", machine: runnerId, settings: { capacity: 1, teamSlots: 0, lendIdle: false, loadCap: 0.85, paused: false, pausedUntil: null } });

// ---- finished ----
step(`${a}: queueing a cancelled task is refused: "${await refused("queue", { type: "task.queue", id: a, before: "top" }, /finished/)}"`);
process.exit(0);

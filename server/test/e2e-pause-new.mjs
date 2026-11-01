// "Pause new work" (MF-304), against `wrangler dev` and a runner played by this script (enrolled here,
// like test/e2e-queue.mjs) that answers each session itself:
//   node server/test/e2e-pause-new.mjs http://localhost:8788
// Checks: with a planned task's worktree on the machine, pausing it for new work (paused + pauseNew)
// still lets that task's builder start there once its plan is approved, and its reviewer after it
// finishes; a task created meanwhile waits with "<machine> is paused for new work."; under a full pause
// an approved plan's builder doesn't start ("<machine> is paused."), and resuming starts it; a
// teammate's task in a team slot isn't handed off by a new-work pause, and is by a full one; Maple's own
// runs (Draft with AI) still go out to a machine paused for new work.

const [base = "http://localhost:8788"] = process.argv.slice(2);
const ws = base.replace(/^http/, "ws");
const { token } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();
const auth = { authorization: `Bearer ${token}` };

// The runner: enrolls, says hello and its health, opens each session it's sent in a worktree of its own,
// and answers a finish as pushed.
const runnerId = `pausenew-${Date.now() % 100000}`;
const { code } = await (await fetch(`${base}/api/machines/enroll`, { method: "POST", headers: auth })).json();
const enrolled = await (await fetch(`${base}/runner/enroll`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ code, runnerId, hostname: runnerId, os: "macos", arch: "arm64", version: "0.0.0-fake" }),
})).json();
const runner = new WebSocket(`${ws}/runner/connect?runner=${runnerId}`, { headers: { authorization: `Bearer ${enrolled.token}` } });
await new Promise((r, j) => { runner.onopen = r; runner.onerror = j; });
const rsend = (m) => runner.send(JSON.stringify(m));
const sessions = [];
const draftRuns = [];
const replies = new Map();
runner.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "ping") rsend({ type: "pong" });
  if (m.type === "session.open") {
    sessions.push(m);
    rsend({ type: "task.started", taskId: m.taskId, repo: null, repoDir: "/tmp/pause-new", base: "main", project: null });
    rsend({ type: "session.opened", session: { id: m.id, agent: "claude", cwd: `/tmp/pause-new/wt/${m.taskId}`, pid: 1, startedAt: Date.now(), taskId: m.taskId } });
  }
  if (m.type === "draft.run") draftRuns.push(m);
  if (m.type === "task.finish") rsend({ type: "task.finished", taskId: m.taskId, ok: true, pushed: "fallback", owner: null, repo: null, branch: m.branch, base: "main", commit: "abc1234def", reason: null });
  if (m.type === "mcp.response") replies.get(m.reqId)?.(m);
  poke?.();
};
rsend({ type: "hello", runnerId, hostname: runnerId, os: "macos", arch: "arm64", version: "0.0.0-fake", sessions: [], ended: [] });
rsend({ type: "health", health: { cpu: 5, cores: 10, load1: 0.5, memUsed: 8e9, memTotal: 32e9, diskUsed: 2e11, diskTotal: 1e12, uptime: 1000, battery: null, agents: [{ name: "claude", version: "2.1.0", loggedIn: true }] } });
/** A tool call from one of this runner's sessions, as runner/src/mcp.rs forwards it. */
const call = (session, tool, args) => new Promise((resolve) => {
  const reqId = crypto.randomUUID();
  replies.set(reqId, resolve);
  rsend({ type: "mcp.request", reqId, session, tool, args });
});

const feed = new WebSocket(`${ws}/client/connect`, { headers: auth });
const tasks = new Map();
let goals = [];
let machines = [];
let errors = [];
const drafts = new Map();
let poke = null;
feed.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "snapshot") { goals = m.goals; machines = m.machines; for (const t of m.tasks) tasks.set(t.id, t); }
  if (m.type === "goal.updated") goals = [...goals.filter((g) => g.id !== m.goal.id), m.goal];
  if (m.type === "machine.updated") machines = [...machines.filter((x) => x.id !== m.machine.id), m.machine];
  if (m.type === "task.updated") tasks.set(m.task.id, m.task);
  if (m.type === "draft.updated") drafts.set(m.draft.id, m.draft);
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
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}: ${JSON.stringify([...tasks.values()].filter((t) => t.goal === goal?.id).map((t) => [t.id, t.state, t.waiting, t.worker?.role]))}`);
    await new Promise((r) => { poke = r; setTimeout(r, 250); });
  }
};
const step = (text) => console.log(`✓ ${text}`);
const settings = (over) => ({ capacity: 4, teamSlots: 0, lendIdle: false, loadCap: 0.85, paused: false, pausedUntil: null, ...over });
const setPause = async (over) => {
  send({ type: "machine.settings", machine: runnerId, settings: settings(over) });
  await wait("settings", () => {
    const s = machines.find((x) => x.id === runnerId)?.settings;
    return s && s.paused === (over.paused ?? false) && Boolean(s.pauseNew) === Boolean(over.pauseNew);
  });
};

await new Promise((r) => (feed.onopen = r));
send({ type: "subscribe" });
let goal;
const machine = await wait("the runner", () => machines.find((x) => x.id === runnerId && x.online));
// Every other machine of ours paused, so this one is the only place work can go.
for (const other of machines.filter((x) => x.id !== runnerId && x.owner === machine.owner)) {
  send({ type: "machine.settings", machine: other.id, settings: settings({ capacity: null, paused: true }) });
}
await setPause({});
step(`${runnerId} connected; the owner's other machines paused`);

const prefix = `PN${Date.now() % 1000}`;
send({ type: "goal.save", goal: { id: "", name: `Pause new ${prefix}`, prefix, color: "#3B82F6", summary: "Pause new work", lead: "", folder: "/tmp/pause-new", base: "main" } });
goal = await wait("goal", () => goals.find((g) => g.prefix === prefix));
let n = 0;
const create = (title) => {
  send({ type: "task.create", goal: goal.id, title, brief: title, shareable: false, plan: true, tickets: [], agent: "claude" });
  return `${prefix}-${++n}`;
};
const sessionOf = (id, role) => wait(`${id}'s ${role}`, () => tasks.get(id)?.worker?.role === role && tasks.get(id).worker.machine === runnerId && sessions.find((s) => s.id === tasks.get(id).worker.session));
const plan = async (id) => {
  const planner = await sessionOf(id, "planner");
  const r = await call(planner.id, "submit_plan", {
    summary: "A small change.",
    steps: [{ text: "Change it", file: "README.md" }],
    doneWhen: [{ text: "It's changed", proof: "terminal" }],
    risk: { level: "low", reasons: ["One file."], areas: [] },
    footprint: { files: 1, lines: 2 },
  });
  if (r.error) throw new Error(`submit_plan: ${r.error}`);
  await wait(`${id} awaiting approval`, () => tasks.get(id)?.state === "awaitingApproval" && !tasks.get(id).worker);
};

// ---- a new-work pause: the task already here finishes ----
const a = create("Already here");
await plan(a);
step(`${a}: planned on ${runnerId}, its worktree there, awaiting approval`);
await setPause({ paused: true, pauseNew: true });
step(`${runnerId} paused for new work`);
const b = create("New one");
const waiting = await wait(`${b} waiting`, () => /paused for new work/.test(tasks.get(b)?.waiting ?? "") && tasks.get(b));
if (waiting.worker || sessions.some((s) => s.taskId === b)) throw new Error(`${b} started on the paused machine`);
step(`${b}: new, held back: "${waiting.waiting}"`);
const draftId = crypto.randomUUID();
send({ type: "draft.start", id: draftId, idea: "Add a dark mode", goal: goal.id, agent: "claude" });
const drafted = await wait("the draft's run", () => draftRuns.find((r) => r.id === `draft-${draftId}`));
const draft = await wait("the draft on the machine", () => drafts.get(draftId)?.machine === runnerId && drafts.get(draftId));
if (draft.state === "failed") throw new Error(`Draft with AI failed: ${draft.error}`);
step(`Draft with AI: ${drafted.type} went to ${runnerId} under the new-work pause (draft ${draft.state})`);
send({ type: "draft.cancel", id: draftId });
if (tasks.get(b).worker || sessions.some((s) => s.taskId === b)) throw new Error(`${b} started alongside the draft`);
step(`${b}: still waiting: "${tasks.get(b).waiting}"`);
send({ type: "task.approvePlan", id: a });
const builder = await sessionOf(a, "builder");
step(`${a}: plan approved, its builder started on ${runnerId} under the new-work pause`);
const proved = await call(builder.id, "prove", { item: 1, kind: "terminal", summary: "Changed", command: "cat README.md", output: ["changed"] });
if (proved.error) throw new Error(`prove: ${proved.error}`);
const finished = await call(builder.id, "finish", { summary: "Changed it." });
if (finished.error) throw new Error(`finish: ${finished.error}`);
await sessionOf(a, "reviewer");
step(`${a}: finished and pushed; its reviewer started on ${runnerId}, still paused for new work`);
if (tasks.get(b).worker) throw new Error(`${b} started meanwhile`);
step(`${b}: still waiting: "${tasks.get(b).waiting}"`);
send({ type: "task.cancel", id: a });
send({ type: "task.cancel", id: b });
await wait("both cancelled", () => tasks.get(a)?.state === "cancelled" && tasks.get(b)?.state === "cancelled");

// ---- a full pause: nothing starts ----
await setPause({});
const c = create("Paused fully");
await plan(c);
await setPause({ paused: true });
step(`${c}: planned on ${runnerId}; ${runnerId} paused fully`);
send({ type: "task.approvePlan", id: c });
const held = await wait(`${c} held`, () => tasks.get(c)?.state === "building" && /is paused\.$/.test(tasks.get(c).waiting ?? "") && tasks.get(c));
await new Promise((r) => setTimeout(r, 2000));
if (tasks.get(c).worker || sessions.filter((s) => s.taskId === c).length !== 1) throw new Error(`${c}'s builder started under a full pause`);
step(`${c}: plan approved, no builder under the full pause: "${held.waiting}"`);
await setPause({});
await sessionOf(c, "builder");
step(`${c}: resumed, its builder started`);
send({ type: "task.cancel", id: c });
await wait(`${c} cancelled`, () => tasks.get(c)?.state === "cancelled");

// ---- a teammate's task: handed off by a full pause only ----
await setPause({ teamSlots: 1 });
const { token: samToken } = await (await fetch(`${base}/dev/token?as=sam-maple`, { method: "POST" })).json();
const sam = new WebSocket(`${ws}/client/connect`, { headers: { authorization: `Bearer ${samToken}` } });
sam.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "task.updated") tasks.set(m.task.id, m.task);
  if (m.type === "error") errors.push(`sam: ${m.message}`);
  poke?.();
};
await new Promise((r) => (sam.onopen = r));
const known = new Set(tasks.keys());
sam.send(JSON.stringify({ type: "task.create", goal: goal.id, title: "Sam's", brief: "Sam's", shareable: true, plan: true, tickets: [], agent: "claude" }));
const theirs = await wait("sam's task on a team slot", () => [...tasks.values()].find((t) => t.goal === goal.id && !known.has(t.id) && t.worker?.machine === runnerId));
const handedOff = () => tasks.get(theirs.id).events.some((e) => /handed it off/.test(e.text));
send({ type: "machine.settings", machine: runnerId, settings: settings({ teamSlots: 1, paused: true, pauseNew: true }), handOff: true });
await new Promise((r) => setTimeout(r, 2500));
if (handedOff() || tasks.get(theirs.id).worker?.machine !== runnerId) throw new Error(`${theirs.id} was handed off by a new-work pause`);
step(`${theirs.id} (sam-maple's): a new-work pause with hand-off asked leaves it running here`);
send({ type: "machine.settings", machine: runnerId, settings: settings({ teamSlots: 1, paused: true }), handOff: true });
await wait(`${theirs.id} handed off`, handedOff);
step(`${theirs.id}: going to a full pause hands it off: "${tasks.get(theirs.id).events.findLast((e) => /handed it off/.test(e.text)).text}"`);
sam.send(JSON.stringify({ type: "task.cancel", id: theirs.id }));
await setPause({});
process.exit(0);

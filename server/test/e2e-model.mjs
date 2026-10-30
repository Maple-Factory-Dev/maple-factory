// A task's agent and model, against `wrangler dev` and a talking-only runner (enrolled here, like
// test/fake-runner.mjs):
//   node server/test/e2e-model.mjs http://localhost:8788
// Checks: task.edit sets a model (stored, with an event), and the task's next session.open carries it.
// Editing while a session runs doesn't restart it; clearing the model sends null from the next session (Retry).
// Switching to codex drops a Claude-only model and opens with agent codex; codex with gpt-5 keeps it.
// An unknown agent, or any change once it's cancelled, is refused.

const [base = "http://localhost:8788"] = process.argv.slice(2);
const ws = base.replace(/^http/, "ws");
const { token } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();
const auth = { authorization: `Bearer ${token}` };
const step = (text) => console.log(`✓ ${text}`);
const pause = (ms) => new Promise((r) => setTimeout(r, ms));

const feed = new WebSocket(`${ws}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
const c = { errors: [], snapshot: null, tasks: new Map(), goals: [], machines: [], poke: null };
feed.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "snapshot") { c.snapshot = m; c.goals = m.goals; c.machines = m.machines; for (const t of m.tasks) c.tasks.set(t.id, t); }
  if (m.type === "goal.updated") c.goals = [...c.goals.filter((g) => g.id !== m.goal.id), m.goal];
  if (m.type === "machine.updated") c.machines = [...c.machines.filter((x) => x.id !== m.machine.id), m.machine];
  if (m.type === "task.updated") c.tasks.set(m.task.id, m.task);
  if (m.type === "error") c.errors.push(m.message);
  c.poke?.();
};
const send = (m) => feed.send(JSON.stringify(m));
const wait = async (what, test, ms = 30000) => {
  const deadline = Date.now() + ms;
  for (;;) {
    const hit = test();
    if (hit) return hit;
    if (c.errors.length) throw new Error(`server said: ${c.errors.join("; ")}`);
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((r) => { c.poke = r; setTimeout(r, 250); });
  }
};
const refused = async (what, msg, pattern) => {
  send(msg);
  await pause(1000);
  const got = c.errors.shift();
  if (!got || !pattern.test(got)) throw new Error(`${what} wasn't refused (got ${JSON.stringify(got)})`);
  step(`${what} refused: "${got}"`);
};
await new Promise((r) => (feed.onopen = r));
send({ type: "subscribe" });
await wait("snapshot", () => c.snapshot);

// ---- a runner with both agents, which records the sessions it's asked to open ----
const runnerId = `model-${Date.now() % 100000}`;
const { code } = await (await fetch(`${base}/api/machines/enroll`, { method: "POST", headers: auth })).json();
const enrolled = await (await fetch(`${base}/runner/enroll`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ code, runnerId, hostname: runnerId, os: "macos", arch: "arm64", version: "0.0.0-fake" }),
})).json();
const sock = new WebSocket(`${ws}/runner/connect?runner=${runnerId}`, { headers: { authorization: `Bearer ${enrolled.token}` } });
await new Promise((r, j) => { sock.onopen = r; sock.onerror = j; });
const say = (m) => sock.send(JSON.stringify(m));
const opened = [];
const killed = [];
sock.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "session.open" && m.taskId) {
    opened.push(m);
    say({ type: "session.opened", session: { id: m.id, agent: m.agent, cwd: `~/.worktrees/x/${m.worktree.name}`, pid: 1, startedAt: Date.now(), taskId: m.taskId } });
  }
  if (m.type === "session.kill") {
    killed.push(m.id);
    say({ type: "session.ended", end: { id: m.id, cause: "killed", code: null, signal: null, detail: null, at: Date.now(), lastOutput: [], by: null } });
  }
  c.poke?.();
};
say({ type: "hello", runnerId, hostname: runnerId, os: "macos", arch: "arm64", version: "0.0.0-fake", sessions: [], ended: [] });
say({ type: "health", health: { cpu: 5, cores: 10, load1: 0.5, memUsed: 8e9, memTotal: 32e9, diskUsed: 2e11, diskTotal: 1e12, uptime: 1000, battery: null, agents: [{ name: "claude", version: "2.1.0", loggedIn: true }, { name: "codex", version: "0.50.0", loggedIn: true }] } });
await wait("the runner", () => c.machines.some((m) => m.id === runnerId && m.online));
const settings = (paused, capacity) => ({ capacity, teamSlots: 0, lendIdle: false, loadCap: 0.85, paused, pausedUntil: null });
const others = c.machines.filter((x) => x.id !== runnerId && x.owner === c.snapshot.me.login);
for (const m of others) send({ type: "machine.settings", machine: m.id, settings: settings(true, null) });
send({ type: "machine.settings", machine: runnerId, settings: settings(false, 2) });
await pause(500);

/** Its next session: Retry stops the one running and opens another. */
const restart = async (taskId) => {
  const count = opened.length;
  send({ type: "task.retry", id: taskId });
  return wait(`${taskId}'s next session.open`, () => opened.length > count && opened.at(-1).taskId === taskId && opened.at(-1));
};
const hasEvent = (id, text) => wait(`event "${text}"`, () => c.tasks.get(id)?.events.some((e) => e.text === text) && c.tasks.get(id));

const prefix = `MD${Date.now() % 1000}`;
send({ type: "goal.save", goal: { id: "", name: `Model ${prefix}`, prefix, color: "#8B5CF6", summary: "Model test", lead: "", repos: ["acme/web"], base: "main" } });
const goal = await wait("goal", () => c.goals.find((g) => g.prefix === prefix));
send({ type: "task.create", goal: goal.id, title: "Pick a model", brief: "Nothing.", shareable: false, plan: false, tickets: [], agent: "claude" });
const id = `${prefix}-1`;
const created = await wait(id, () => c.tasks.get(id));
if (created.model != null) throw new Error(`a new task's model is ${JSON.stringify(created.model)}`);
step(`${id} starts with agent ${created.agent} and the default model`);

// ---- set it, then its session opens with it ----
send({ type: "task.edit", id, model: "  opus " });
let task = await hasEvent(id, "set its model to opus");
if (task.model !== "opus") throw new Error(`model stored as ${JSON.stringify(task.model)}`);
if (task.events.some((e) => e.text === "edited it")) throw new Error("a model change also said \"edited it\"");
step(`task.edit stored model "opus" (trimmed) with the event "set its model to opus"`);

send({ type: "task.plan", id });
let open = await wait(`${id}'s session.open`, () => opened.find((m) => m.taskId === id));
if (open.model !== "opus" || open.agent !== "claude") throw new Error(`session.open: agent ${open.agent}, model ${JSON.stringify(open.model)}`);
step(`the planner's session.open carries agent "claude", model "opus"`);

// ---- clearing it while the session runs: that session keeps going, the next one gets null ----
const running = open.id;
send({ type: "task.edit", id, model: "" });
task = await hasEvent(id, "set its model back to the default");
if (task.model != null) throw new Error(`a cleared model is ${JSON.stringify(task.model)}`);
await pause(1000);
if (killed.includes(running) || c.tasks.get(id).worker?.session !== running) throw new Error("the running session was restarted by the edit");
step(`cleared with "" while its planner ran; that session (${running.slice(0, 8)}) kept going`);
open = await restart(id);
if (open.model !== null) throw new Error(`the next session.open's model is ${JSON.stringify(open.model)}`);
step("its next session.open carries model null");

// ---- switching agent drops a Claude-only model; codex with its own model keeps it ----
send({ type: "task.edit", id, model: "sonnet" });
await hasEvent(id, "set its model to sonnet");
send({ type: "task.edit", id, agent: "codex" });
task = await hasEvent(id, "switched it to codex");
if (task.agent !== "codex" || task.model != null) throw new Error(`after the switch: agent ${task.agent}, model ${JSON.stringify(task.model)}`);
step(`switching to codex dropped "sonnet" ("switched it to codex")`);
open = await restart(id);
if (open.agent !== "codex" || open.model !== null) throw new Error(`session.open: agent ${open.agent}, model ${JSON.stringify(open.model)}`);
step(`the next session.open carries agent "codex", model null`);

send({ type: "task.edit", id, agent: "claude", model: "haiku" });
await hasEvent(id, "switched it to claude · haiku");
send({ type: "task.edit", id, agent: "codex", model: "gpt-5" });
task = await hasEvent(id, "switched it to codex · gpt-5");
if (task.model !== "gpt-5") throw new Error(`model ${JSON.stringify(task.model)}`);
open = await restart(id);
if (open.agent !== "codex" || open.model !== "gpt-5") throw new Error(`session.open: agent ${open.agent}, model ${JSON.stringify(open.model)}`);
step(`agent and model together: "switched it to codex · gpt-5", and session.open carries both`);

// ---- refusals ----
await refused("an unknown agent", { type: "task.edit", id, agent: "gemini" }, /isn't an agent/);
send({ type: "task.cancel", id });
await wait("cancelled", () => c.tasks.get(id)?.state === "cancelled");
await refused("a change once cancelled", { type: "task.edit", id, model: "opus" }, /cancelled/);

// What a fresh client sees.
const fresh = await (async () => {
  const f = new WebSocket(`${ws}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
  const snap = new Promise((r) => (f.onmessage = (e) => { const m = JSON.parse(e.data); if (m.type === "snapshot") r(m); }));
  await new Promise((r) => (f.onopen = r));
  f.send(JSON.stringify({ type: "subscribe" }));
  const m = await snap;
  f.close();
  return m.tasks.find((t) => t.id === id);
})();
if (fresh?.agent !== "codex" || fresh.model !== "gpt-5") throw new Error(`a new snapshot has ${fresh?.agent} · ${fresh?.model}`);
step("a new snapshot carries codex · gpt-5");

for (const m of others) send({ type: "machine.settings", machine: m.id, settings: settings(false, null) });
await pause(1000);
console.log("all model checks passed");
process.exit(0);

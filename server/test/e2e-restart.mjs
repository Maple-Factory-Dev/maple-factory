// A machine restart doesn't strand a task: its session comes back on its own, no Retry.
//   node server/test/e2e-restart.mjs http://localhost:8788
// A fake runner (as fake-runner.mjs, but it answers session.open with session.opened) takes a task's
// planner session, then goes away and comes back with the same id and an empty hello (`sessions: []`,
// `ended: []`), as a runner does after a reboot. The task must open a second session by itself, its
// timeline saying why, and never raise a hand.

const [base = "http://localhost:8788"] = process.argv.slice(2);
const runnerId = `restart-mac-${Date.now() % 100000}`;
const step = (text) => console.log(`✓ ${text}`);

const { token } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();
const auth = { authorization: `Bearer ${token}` };
const { code } = await (await fetch(`${base}/api/machines/enroll`, { method: "POST", headers: auth })).json();
const enrolled = await (await fetch(`${base}/runner/enroll`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ code, runnerId, hostname: runnerId, os: "macos", arch: "arm64", version: "0.0.0-fake" }),
})).json();

/** One run of the runner process: every session.open it gets is in `opens`, answered with session.opened. */
async function runner() {
  const r = { opens: [], poke: null };
  r.ws = new WebSocket(`${base.replace(/^http/, "ws")}/runner/connect?runner=${runnerId}`, { headers: { authorization: `Bearer ${enrolled.token}` } });
  await new Promise((ok, fail) => { r.ws.onopen = ok; r.ws.onerror = fail; });
  const send = (m) => r.ws.send(JSON.stringify(m));
  r.ws.onmessage = (e) => {
    if (typeof e.data !== "string") return;
    const m = JSON.parse(e.data);
    if (m.type !== "session.open") return;
    r.opens.push(m);
    console.log(`  runner: session.open ${m.id} (${m.agent}, task ${m.task?.id ?? m.taskId})`);
    send({ type: "session.opened", session: { id: m.id, agent: m.agent, cwd: m.cwd || "/tmp", pid: 4242, startedAt: Date.now(), taskId: m.task?.id ?? m.taskId ?? null } });
    r.poke?.();
  };
  // After a reboot: tmux is empty and the runner's record of recent ends went with it.
  send({ type: "hello", runnerId, hostname: runnerId, os: "macos", arch: "arm64", version: "0.0.0-fake", sessions: [], ended: [] });
  return r;
}

const feed = { tasks: new Map(), errors: [], poke: null };
feed.ws = new WebSocket(`${base.replace(/^http/, "ws")}/client/connect`, { headers: auth });
feed.ws.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "snapshot") { for (const t of m.tasks) feed.tasks.set(t.id, t); feed.snapshot = true; }
  if (m.type === "task.updated") feed.tasks.set(m.task.id, m.task);
  if (m.type === "goal.updated") feed.goal ??= m.goal;
  if (m.type === "error") feed.errors.push(m.message);
  feed.poke?.();
};
await new Promise((r) => (feed.ws.onopen = r));
const send = (m) => feed.ws.send(JSON.stringify(m));
async function wait(what, test, ms = 20000) {
  const deadline = Date.now() + ms;
  for (;;) {
    const hit = test();
    if (hit) return hit;
    if (feed.errors.length) throw new Error(`server said: ${feed.errors.join("; ")}`);
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((r) => { feed.poke = r; setTimeout(r, 250); });
  }
}
send({ type: "subscribe" });
await wait("snapshot", () => feed.snapshot);

let mac = await runner();
step(`${runnerId} connected`);

const prefix = `RS${Date.now() % 10000}`;
send({ type: "goal.save", goal: { id: "", name: `Restart ${prefix}`, prefix, color: "#2F80ED", summary: "Restarts", lead: "", folder: "/tmp/mf-restart", base: "main" } });
const goal = await wait("goal", () => feed.goal?.prefix === prefix && feed.goal);
// A made-up agent, so only a machine that doesn't report its agents (this one) is a fit for it.
send({ type: "task.create", goal: goal.id, title: "Survive a restart", brief: "Keep going after a reboot.", shareable: false, plan: true, tickets: [], agent: "scripted" });
const id = await wait("task", () => [...feed.tasks.values()].find((t) => t.goal === goal.id)?.id);
const first = await wait("first session", () => feed.tasks.get(id)?.worker?.machine === runnerId && feed.tasks.get(id).worker);
if (mac.opens.length !== 1 || mac.opens[0].id !== first.session) throw new Error(`expected one session.open for ${first.session}, got ${mac.opens.map((o) => o.id)}`);
step(`${id} is planning on ${runnerId} in session ${first.session}`);

// The machine restarts: the socket drops, and the runner comes back with the same id and nothing running.
mac.ws.close();
await new Promise((r) => setTimeout(r, 1500));
step(`${runnerId} went away`);
mac = await runner();
step(`${runnerId} came back with an empty hello (sessions: [], ended: [])`);

const second = await wait("a new session", () => {
  const w = feed.tasks.get(id)?.worker;
  return w && w.session !== first.session && w;
});
await wait("its session.open", () => mac.opens.some((o) => o.id === second.session));
const task = feed.tasks.get(id);
const restarted = task.events.find((e) => /ended \(tmux went away\); starting it again/.test(e.text));
if (!restarted) throw new Error(`no restart on the timeline:\n${task.events.map((e) => e.text).join("\n")}`);
console.log(`  timeline: [${restarted.who}] ${restarted.text}`);
console.log(`  runner after restart got: ${mac.opens.map((o) => `session.open ${o.id}`).join(", ")}`);
step(`${id} opened session ${second.session} by itself (state ${task.state})`);

// A little longer: no hand, and no third session.
await new Promise((r) => setTimeout(r, 3000));
const settled = feed.tasks.get(id);
if (settled.hand) throw new Error(`a hand was raised: ${JSON.stringify(settled.hand)}`);
if (mac.opens.length !== 1) throw new Error(`expected one session.open after the restart, got ${mac.opens.length}`);
step(`no hand raised; worker still ${settled.worker?.session}`);

send({ type: "task.cancel", id });
mac.ws.close();
feed.ws.close();
console.log("e2e-restart: passed");
process.exit(0);

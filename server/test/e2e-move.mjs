// Moving a task off a machine that went offline mid-plan, then the machine coming back:
//   node server/test/e2e-move.mjs http://localhost:8788 <goal prefix> "<stop runner>" "<start runner>"
// The stop and start commands are shell commands for the one real runner (scripted agent). Checks
// that a running task can't be moved, that an offline one can, that it starts again once a machine is
// free, and that the session left behind on the old machine is stopped when it reconnects.

import { execSync } from "node:child_process";

const [base = "http://localhost:8788", prefix = "GRT", stop, start] = process.argv.slice(2);
if (!stop || !start) throw new Error("usage: e2e-move.mjs <server> <goal prefix> <stop runner> <start runner>");
const { token } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();
const feed = new WebSocket(`${base.replace(/^http/, "ws")}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
const tasks = new Map();
const machines = new Map();
let goals = [];
let errors = [];
let poke = null;
feed.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "snapshot") {
    goals = m.goals;
    for (const t of m.tasks) tasks.set(t.id, t);
    for (const x of m.machines) machines.set(x.id, x);
  }
  if (m.type === "task.updated") tasks.set(m.task.id, m.task);
  if (m.type === "machine.updated") machines.set(m.machine.id, m.machine);
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

await new Promise((r) => (feed.onopen = r));
send({ type: "subscribe" });
await wait("snapshot", () => goals.length);
const goal = goals.find((g) => g.prefix === prefix) ?? (() => { throw new Error(`no goal ${prefix}`); })();
const before = new Set(tasks.keys());

send({ type: "task.create", goal: goal.id, title: "Move me", brief: "[slow] Add hello.txt with a greeting.", shareable: false, plan: true, tickets: [], agent: "scripted" });
let t = await wait("planner", () => [...tasks.values()].find((x) => !before.has(x.id) && x.worker?.role === "planner"));
const { id } = t;
const first = t.worker;
step(`${id} planning on ${first.machine}`);

send({ type: "task.move", id });
await wait("refusal", () => errors.length);
if (!/running on/.test(errors[0])) throw new Error(`unexpected: ${errors[0]}`);
step(`refused while it runs: "${errors[0]}"`);
errors = [];

execSync(stop, { stdio: "inherit" });
await wait("machine offline", () => machines.get(first.machine)?.online === false, 20000);
step(`${first.machine} went offline`);

send({ type: "task.move", id });
t = await wait("moved", () => tasks.get(id)?.machine == null && tasks.get(id));
if (t.worker) throw new Error("it still has a worker");
step(`moved: ${t.events.at(-1).text}`);
t = await wait("a waiting reason", () => tasks.get(id)?.waiting && tasks.get(id));
step(`waiting: ${t.waiting}`);

execSync(start, { stdio: "inherit" });
t = await wait("planner again", () => tasks.get(id)?.worker?.session && tasks.get(id).worker.session !== first.session && tasks.get(id), 30000);
step(`started again on ${t.worker.machine} (new session)`);
await wait("old session stopped", () => !machines.get(first.machine)?.sessions.some((s) => s.session.id === first.session), 20000);
step("the session left behind was stopped when its machine came back");

send({ type: "task.cancel", id });
await wait("cancelled", () => tasks.get(id)?.state === "cancelled");
step("cancelled");
feed.close();
process.exit(0);

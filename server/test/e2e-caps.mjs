// Plan-usage caps on a machine, with a fake runner whose Claude account has used 86% of its 5-hour
// session, owned by a person (`capper`) with no other machine:
//   node server/test/e2e-caps.mjs http://localhost:8788 <goal prefix on a local folder>
// Checks: a machine-wide cap below 86% holds their task back; the account's own cap above it lets it
// start; and with caps on teammates' work only, the owner's own task starts past the cap.

import { spawn } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const [base = "http://localhost:8788", prefix = "GRT"] = process.argv.slice(2);
const who = "capper";
const id = `cap-${Date.now() % 10000}`;
const runner = spawn("node", [join(dirname(fileURLToPath(import.meta.url)), "fake-runner.mjs"), base, id, "120", "86", who], { stdio: "ignore" });
const { token } = await (await fetch(`${base}/dev/token?as=${who}`, { method: "POST" })).json();
const feed = new WebSocket(`${base.replace(/^http/, "ws")}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
const tasks = new Map();
let goals = [];
let machines = [];
let errors = [];
let goal;
feed.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "snapshot") { goals = m.goals; machines = m.machines; for (const t of m.tasks) tasks.set(t.id, t); }
  if (m.type === "task.updated") tasks.set(m.task.id, m.task);
  if (m.type === "machine.updated") machines = [...machines.filter((x) => x.id !== m.machine.id), m.machine];
  if (m.type === "error") errors.push(m.message);
};
const send = (m) => feed.send(JSON.stringify(m));
const wait = async (what, test, ms = 20000) => {
  const deadline = Date.now() + ms;
  for (;;) {
    const hit = test();
    if (hit) return hit;
    if (errors.length) throw new Error(`server said: ${errors.join("; ")}`);
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 250));
  }
};
const step = (text) => console.log(`✓ ${text}`);
const settings = (extra) => send({ type: "machine.settings", machine: id, settings: { capacity: 2, teamSlots: 0, lendIdle: false, loadCap: 0.85, paused: false, pausedUntil: null, sessionCap: 0.8, weeklyCap: null, ...extra } });
const capped = (t) => /the cap is \d+%/.test(t?.waiting ?? "");
let n = 0;
const newTask = async () => {
  const before = new Set(tasks.keys());
  send({ type: "task.create", goal: goal.id, title: `Cap check ${++n}`, brief: "Add hello.txt with a greeting.", shareable: false, plan: true, tickets: [], agent: "claude" });
  return (await wait("task", () => [...tasks.values()].find((t) => !before.has(t.id) && t.title === `Cap check ${n}`))).id;
};

try {
  await new Promise((r) => (feed.onopen = r));
  send({ type: "subscribe" });
  await wait("snapshot", () => goals.length && goals);
  goal = goals.find((g) => g.prefix === prefix);
  if (!goal) throw new Error(`no goal ${prefix}`);
  await wait(`${id} with usage`, () => machines.find((m) => m.id === id && m.online && m.usage.length));
  step(`${id} is ${who}'s only machine; its Claude account is at 86% of the 5-hour session`);

  settings({});
  await new Promise((r) => setTimeout(r, 500));
  const a = await newTask();
  const held = await wait(`${a} held back`, () => capped(tasks.get(a)) && tasks.get(a));
  step(`a machine-wide cap of 80% holds ${a} back: "${held.waiting}"`);

  settings({ agentCaps: [{ agent: "claude", session: 0.9, weekly: null }] });
  await wait(`${a} let through`, () => !capped(tasks.get(a)) && tasks.get(a)?.worker);
  step(`Claude's own cap of 90% lets ${a} start (it ignores the machine-wide 80%)`);
  send({ type: "task.cancel", id: a });

  settings({ agentCaps: [{ agent: "claude", session: 0.8, weekly: null }] });
  await new Promise((r) => setTimeout(r, 500));
  const b = await newTask();
  await wait(`${b} held back`, () => capped(tasks.get(b)));
  step(`back at 80% for Claude, ${b} waits`);
  settings({ agentCaps: [{ agent: "claude", session: 0.8, weekly: null }], capsTeamOnly: true });
  await wait(`${b} let through`, () => !capped(tasks.get(b)) && tasks.get(b)?.worker);
  step(`with caps on teammates' work only, ${who}'s own ${b} starts past the cap`);
  send({ type: "task.cancel", id: b });
  await new Promise((r) => setTimeout(r, 500));
} finally {
  runner.kill();
  await fetch(`${base}/api/machines/${id}`, { method: "DELETE", headers: { authorization: `Bearer ${token}`, origin: base } });
}
process.exit(0);

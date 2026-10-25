// Pausing a machine hands its teammates' tasks off: the work so far is committed and pushed, and the
// task carries on from it once a machine is free.
//   node server/test/e2e-handoff.mjs http://localhost:8788 <goal prefix> <repo folder>
// Needs the one real runner (scripted agent) owned by the dev user, and a goal on a local repo whose
// origin is a bare repo. A made-up teammate owns the task, so it runs in one of dev-mac's team slots.

import { execFileSync } from "node:child_process";

const [base = "http://localhost:8788", prefix = "GRT", folder] = process.argv.slice(2);
if (!folder) throw new Error("usage: e2e-handoff.mjs <server> <goal prefix> <repo folder>");
const ws = base.replace(/^http/, "ws");

function connect(login) {
  const c = { tasks: new Map(), machines: new Map(), goals: [], errors: [], poke: null };
  c.ready = (async () => {
    const { token } = await (await fetch(`${base}/dev/token${login ? `?as=${login}` : ""}`, { method: "POST" })).json();
    c.feed = new WebSocket(`${ws}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
    c.feed.onmessage = (e) => {
      const m = JSON.parse(e.data);
      if (m.type === "snapshot") {
        c.goals = m.goals;
        for (const t of m.tasks) c.tasks.set(t.id, t);
        for (const x of m.machines) c.machines.set(x.id, x);
      }
      if (m.type === "task.updated") c.tasks.set(m.task.id, m.task);
      if (m.type === "machine.updated") c.machines.set(m.machine.id, m.machine);
      if (m.type === "error") c.errors.push(m.message);
      c.poke?.();
    };
    await new Promise((r) => (c.feed.onopen = r));
    c.send({ type: "subscribe" });
  })();
  c.send = (m) => c.feed.send(JSON.stringify(m));
  c.wait = async (what, test, ms = 30000) => {
    const deadline = Date.now() + ms;
    for (;;) {
      const hit = test();
      if (hit) return hit;
      if (c.errors.length) throw new Error(`server said: ${c.errors.join("; ")}`);
      if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
      await new Promise((r) => { c.poke = r; setTimeout(r, 250); });
    }
  };
  return c;
}
const step = (text) => console.log(`✓ ${text}`);

const me = connect(null);
const sam = connect("sam-maple");
await me.ready;
await sam.ready;
await me.wait("snapshot", () => me.goals.length && me.machines.size);
const goal = me.goals.find((g) => g.prefix === prefix) ?? (() => { throw new Error(`no goal ${prefix}`); })();
const mac = [...me.machines.values()].find((m) => m.online) ?? (() => { throw new Error("no machine online"); })();
const settings = { ...mac.settings, paused: false, pausedUntil: null, teamSlots: Math.max(1, mac.settings.teamSlots) };
me.send({ type: "machine.settings", machine: mac.id, settings });
step(`${mac.name} lends ${settings.teamSlots} team slot(s)`);

const before = new Set(sam.tasks.keys());
sam.send({ type: "task.create", goal: goal.id, title: "Hand me off", brief: "[slow-build] Add hello.txt with a greeting.", shareable: true, plan: true, tickets: [], agent: "scripted" });
let t = await sam.wait("plan", () => [...sam.tasks.values()].find((x) => !before.has(x.id) && x.state === "awaitingApproval"));
const { id } = t;
step(`${id} (sam's) planned on ${mac.name}`);
sam.send({ type: "task.approvePlan", id });
t = await sam.wait("builder", () => sam.tasks.get(id)?.worker?.role === "builder" && sam.tasks.get(id));
step(`building in a team slot on ${t.worker.machine}`);
await new Promise((r) => setTimeout(r, 4000)); // it writes wip.txt, then thinks

me.send({ type: "machine.settings", machine: mac.id, settings: { ...settings, paused: true }, handOff: true });
t = await sam.wait("hand-off", () => sam.tasks.get(id)?.machine == null && sam.tasks.get(id), 30000);
step(`handed off: ${t.events.at(-1).text}`);
const branch = t.branch;
const origin = execFileSync("git", ["-C", folder, "remote", "get-url", "origin"], { encoding: "utf8" }).trim();
const wip = execFileSync("git", ["-C", origin, "show", `${branch}:wip.txt`], { encoding: "utf8" });
step(`origin's ${branch} has the unfinished work: ${JSON.stringify(wip.trim())}`);
t = await sam.wait("a waiting reason", () => sam.tasks.get(id)?.waiting && sam.tasks.get(id));
step(`waiting: ${t.waiting}`);

me.send({ type: "machine.settings", machine: mac.id, settings });
t = await sam.wait("builder again", () => sam.tasks.get(id)?.worker?.role === "builder" && sam.tasks.get(id), 30000);
step(`resumed on ${t.worker.machine}`);
t = await sam.wait("review", () => sam.tasks.get(id)?.state === "reviewing" && sam.tasks.get(id), 60000);
const log = execFileSync("git", ["-C", origin, "log", "--format=%s", branch], { encoding: "utf8" }).split("\n").slice(0, 3);
step(`finished on top of the hand-off: ${log.join(" ← ")}`);

sam.send({ type: "task.cancel", id });
await sam.wait("cancelled", () => sam.tasks.get(id)?.state === "cancelled");
step("cancelled");
process.exit(0);

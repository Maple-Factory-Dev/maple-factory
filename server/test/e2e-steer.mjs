// Steering a running builder: the change request is typed into its session, it applies it and says
// so, and the pushed change has it.
//   node server/test/e2e-steer.mjs http://localhost:8788 <goal prefix> <repo folder>
// Needs the scripted agent (test/scripted-agent.mjs) and a goal on a local repo whose origin is bare.

import { execFileSync } from "node:child_process";

const [base = "http://localhost:8788", prefix = "GRT", folder] = process.argv.slice(2);
if (!folder) throw new Error("usage: e2e-steer.mjs <server> <goal prefix> <repo folder>");
const { token } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();
const feed = new WebSocket(`${base.replace(/^http/, "ws")}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
const tasks = new Map();
let goals = [];
const errors = [];
let poke = null;
feed.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "snapshot") { goals = m.goals; for (const t of m.tasks) tasks.set(t.id, t); }
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

await new Promise((r) => (feed.onopen = r));
send({ type: "subscribe" });
await wait("snapshot", () => goals.length);
const goal = goals.find((g) => g.prefix === prefix) ?? (() => { throw new Error(`no goal ${prefix}`); })();
const before = new Set(tasks.keys());

send({ type: "task.create", goal: goal.id, title: "Steer me", brief: "[slow-build] Add hello.txt with a greeting.", shareable: false, plan: true, tickets: [], agent: "scripted" });
let t = await wait("plan", () => [...tasks.values()].find((x) => !before.has(x.id) && x.state === "awaitingApproval"));
const { id } = t;
send({ type: "task.approvePlan", id });
await wait("builder", () => tasks.get(id)?.worker?.role === "builder");
step(`${id} building`);
await new Promise((r) => setTimeout(r, 2000));

const text = "Say it in French too: bonjour.";
send({ type: "task.steer", id, text });
t = await wait("applying", () => tasks.get(id)?.changes.at(-1)?.status === "applying" && tasks.get(id));
const change = t.changes.at(-1);
step(`${change.id} typed into the builder's session`);
t = await wait("applied", () => tasks.get(id)?.changes.find((c) => c.id === change.id)?.status === "applied" && tasks.get(id), 120000);
step(`${change.id} applied`);
t = await wait("review", () => tasks.get(id)?.state === "reviewing" && tasks.get(id), 60000);
const origin = execFileSync("git", ["-C", folder, "remote", "get-url", "origin"], { encoding: "utf8" }).trim();
const hello = execFileSync("git", ["-C", origin, "show", `${t.branch}:hello.txt`], { encoding: "utf8" });
if (!hello.includes("bonjour")) throw new Error(`hello.txt is ${JSON.stringify(hello)}`);
step(`the pushed change has it: ${JSON.stringify(hello.trim().split("\n").at(-1))}`);

send({ type: "task.cancel", id });
await wait("cancelled", () => tasks.get(id)?.state === "cancelled");
step("cancelled");
process.exit(0);

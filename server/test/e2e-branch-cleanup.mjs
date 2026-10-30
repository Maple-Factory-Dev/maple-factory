// A merged task's branch on origin: the factory merges a low-risk task (no GitHub App: the runner merges
// into origin's main), the runner deletes agent/<name> on origin and says so, the task's timeline has
// "deleted branch agent/<name> on origin", and after its cleanup origin has no agent/ branch for it.
//   node server/test/e2e-branch-cleanup.mjs http://localhost:8788 <repo folder>
// Needs a real runner whose agents.toml has the `scripted` agent (test/scripted-agent.mjs), a local repo
// whose origin is a bare repo, and a short grace on the server (MERGE_GRACE_MS=1500 scripts/dev-stack.sh up).

import { execFileSync } from "node:child_process";

const [base = "http://localhost:8788", folder] = process.argv.slice(2);
if (!folder) throw new Error("usage: e2e-branch-cleanup.mjs <server> <repo folder>");
const ws = base.replace(/^http/, "ws");
const { token } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();

const feed = new WebSocket(`${ws}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
const tasks = new Map();
let goals = [];
let policy = null;
const errors = [];
let poke = null;
feed.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "snapshot") { goals = m.goals; policy = m.policy; for (const t of m.tasks) tasks.set(t.id, t); }
  if (m.type === "task.updated") tasks.set(m.task.id, m.task);
  if (m.type === "policy.updated") policy = m.policy;
  if (m.type === "goal.updated") goals = [...goals.filter((g) => g.id !== m.goal.id), m.goal];
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
    await new Promise((r) => { poke = r; setTimeout(r, 50); });
  }
};
const step = (text) => console.log(`✓ ${text}`);
const git = (...args) => execFileSync("git", args, { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();

await new Promise((r) => (feed.onopen = r));
send({ type: "subscribe" });
await wait("snapshot", () => policy);
const original = policy;
send({ type: "policy.save", policy: { ...policy, autoMerges: true, autoMerge: { ...policy.autoMerge, low: true } } });
await wait("policy", () => policy.autoMerges !== false && policy.autoMerge.low);

const prefix = `BC${Date.now() % 100000}`.slice(0, 7);
send({ type: "goal.save", goal: { id: "", name: `Branch cleanup ${prefix}`, prefix, color: "#2EA043", summary: "Branch cleanup test", lead: "", folder, base: "main" } });
const goal = await wait("goal", () => goals.find((g) => g.prefix === prefix));
const id = `${prefix}-1`;
send({ type: "task.create", goal: goal.id, title: "Say hello, then tidy up", brief: "Add hello.txt with a greeting.", shareable: false, plan: true, tickets: [], agent: "scripted" });
await wait(`${id} plan`, () => tasks.get(id)?.state === "awaitingApproval", 60000);
send({ type: "task.approvePlan", id });
let t = await wait(`${id} merged`, () => tasks.get(id)?.state === "merged" && tasks.get(id), 240000);
const branch = t.pr.branch;
step(`${id} merged; its branch was ${branch}`);

const deleted = `deleted branch ${branch} on origin`;
t = await wait(`${id} "${deleted}"`, () => tasks.get(id)?.events.some((e) => e.who === "factory" && e.text === deleted) && tasks.get(id));
step(`its timeline says "${deleted}"`);
t = await wait(`${id} cleaned up`, () => tasks.get(id)?.events.find((e) => /^(cleaned up|couldn't clean up)/.test(e.text)) && tasks.get(id), 60000);
const cleaned = t.events.find((e) => /^(cleaned up|couldn't clean up)/.test(e.text));
if (!cleaned.text.startsWith("cleaned up")) throw new Error(cleaned.text);
step(`"${cleaned.text}"`);

const origin = git("-C", folder, "remote", "get-url", "origin");
const left = git("-C", folder, "ls-remote", "--heads", "origin", "agent/*");
if (left.split("\n").some((l) => l.endsWith(`refs/heads/${branch}`))) throw new Error(`origin still has ${branch}:\n${left}`);
if (!git("-C", origin, "show", "main:hello.txt")) throw new Error("origin main doesn't have hello.txt");
step(`git ls-remote --heads origin 'agent/*' → ${JSON.stringify(left)}; origin main has the work`);
console.log(`\n${t.events.map((e) => `  ${e.who}: ${e.text.split("\n")[0]}`).join("\n")}\n`);

send({ type: "policy.save", policy: original });
await wait("policy restored", () => (policy.autoMerges !== false) === (original.autoMerges !== false));
feed.close();
process.exit(0);

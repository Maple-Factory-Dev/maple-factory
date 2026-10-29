// "Merge approved changes automatically" (the policy's autoMerges). Off: a low-risk task whose
// proofs, review and CI all pass stays in reviewing, says it's waiting for a person (an event and a
// toast), doesn't merge on its own, and a person's Merge lands it. Turning it back on merges a task
// that was waiting, and with the field missing (an older policy) the same flow auto-merges as before,
// each after its countdown (run the server with a short MERGE_GRACE_MS, as e2e-merge-countdown does).
//   node server/test/e2e-auto-merge-off.mjs http://localhost:8788 <repo folder>
// Needs a real runner whose agents.toml has the `scripted` agent (test/scripted-agent.mjs), and a
// local repo whose origin is a bare repo.

import { execFileSync } from "node:child_process";

const [base = "http://localhost:8788", folder] = process.argv.slice(2);
if (!folder) throw new Error("usage: e2e-auto-merge-off.mjs <server> <repo folder>");
const ws = base.replace(/^http/, "ws");
const { token } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();

const feed = new WebSocket(`${ws}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
const tasks = new Map();
let goals = [];
let policy = null;
const toasts = [];
const errors = [];
let poke = null;
feed.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "snapshot") { goals = m.goals; policy = m.policy; for (const t of m.tasks) tasks.set(t.id, t); }
  if (m.type === "task.updated") tasks.set(m.task.id, m.task);
  if (m.type === "policy.updated") policy = m.policy;
  if (m.type === "goal.updated") goals = [...goals.filter((g) => g.id !== m.goal.id), m.goal];
  if (m.type === "toast") toasts.push(m);
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
const pause = (ms) => new Promise((r) => setTimeout(r, ms));
const step = (text) => console.log(`✓ ${text}`);
const git = (...args) => execFileSync("git", args, { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
const countedDown = (t) => {
  const texts = t.events.map((e) => e.text);
  const at = texts.findIndex((x) => x.startsWith("will auto-merge"));
  return at >= 0 && at < texts.findIndex((x) => x.startsWith("auto-merged"));
};
const waiting = (t) => t.events.filter((e) => e.who === "factory" && e.text.startsWith("is ready; waiting for a person to merge it"));

await new Promise((r) => (feed.onopen = r));
send({ type: "subscribe" });
await wait("snapshot", () => policy);
const original = policy;
// Low risk auto-merges by its level's checkbox, so only the org-wide switch holds it back.
const save = async (autoMerges, what) => {
  const next = { ...policy, autoMerge: { ...policy.autoMerge, low: true } };
  if (autoMerges === undefined) delete next.autoMerges;
  else next.autoMerges = autoMerges;
  send({ type: "policy.save", policy: next });
  // Saved without the field, it reads back as on (the default fills it in).
  await wait(what, () => policy.autoMerges === (autoMerges ?? true) && policy.autoMerge.low);
  step(`Merge approved changes automatically: ${what}`);
};
await save(false, "off");

const prefix = `AM${Date.now() % 100000}`.slice(0, 7);
send({ type: "goal.save", goal: { id: "", name: `Auto-merge ${prefix}`, prefix, color: "#2EA043", summary: "Auto-merge off test", lead: "", folder, base: "main" } });
const goal = await wait("goal", () => goals.find((g) => g.prefix === prefix));
step(`goal ${goal.name}`);

/** A low-risk task through planning, building and the reviewer's passing round. */
const ready = async (n, title) => {
  const id = `${prefix}-${n}`;
  send({ type: "task.create", goal: goal.id, title, brief: "Add hello.txt with a greeting.", shareable: false, plan: true, tickets: [], agent: "scripted" });
  await wait(`${id} plan`, () => tasks.get(id)?.state === "awaitingApproval", 60000);
  send({ type: "task.approvePlan", id });
  await wait(`${id} builder`, () => tasks.get(id)?.worker?.role === "builder");
  const t = await wait(`${id} review passed`, () => tasks.get(id)?.autoReview?.rounds.at(-1)?.verdict === "passed" && tasks.get(id), 180000);
  if (t.risk.level !== "low" || t.reviewsNeeded !== 0) throw new Error(`${id} is ${t.risk.level} risk needing ${t.reviewsNeeded} reviews`);
  if (t.doneWhen.some((d) => d.status !== "proven")) throw new Error(`${id} isn't proven`);
  if (t.pr.checks.some((c) => c.status !== "passed")) throw new Error(`${id}'s checks: ${JSON.stringify(t.pr.checks)}`);
  step(`${id}: low risk, no reviews needed, ${t.doneWhen.length}/${t.doneWhen.length} proven, review passed (round ${t.autoReview.rounds.length}), ${t.pr.checks.length} checks, all green`);
  return id;
};
const origin = git("-C", folder, "remote", "get-url", "origin");
const onMain = (id) => { try { return git("-C", origin, "show", "main:hello.txt").includes(id); } catch { return false; } };

// 1. Off: it waits in reviewing, says so once, and nothing merges it.
const id1 = await ready(1, "Say hello, merged by a person");
let t = await wait(`${id1} waiting`, () => waiting(tasks.get(id1)).length && tasks.get(id1));
step(`${id1}: "${waiting(t)[0].text}"`);
const toast = await wait("toast", () => toasts.find((m) => m.taskId === id1 && /waiting for you/.test(m.text)));
step(`toast: "${toast.text}"`);
await pause(8000);
t = tasks.get(id1);
if (t.state !== "reviewing" || t.liveLog === "Merging…" || t.events.some((e) => e.text.startsWith("auto-merged"))) throw new Error(`${id1} is ${t.state}: ${t.events.at(-1).text}`);
if (waiting(t).length !== 1) throw new Error(`it said it was waiting ${waiting(t).length} times`);
if (onMain(id1)) throw new Error("origin's main has it already");
step(`8s later: ${id1} is still reviewing, not merged, not on origin main; said it was waiting once`);

// 2. A person's Merge lands it.
send({ type: "task.merge", id: id1 });
t = await wait(`${id1} merged`, () => tasks.get(id1)?.state === "merged" && tasks.get(id1), 60000);
if (!onMain(id1)) throw new Error("origin's main doesn't have it");
const by = t.events.find((e) => e.text === "merged it");
if (!by || by.who === "factory") throw new Error(`merged by ${JSON.stringify(by)}`);
step(`a person merged it (${by.who}: "${by.text}"); origin main has ${id1}'s hello.txt`);

// 3. Turned back on while one waits: the policy change merges it.
const id2 = await ready(2, "Say hello, merged when it's turned on");
await wait(`${id2} waiting`, () => waiting(tasks.get(id2)).length);
step(`${id2} waiting for a person`);
await save(true, "on");
t = await wait(`${id2} merged`, () => tasks.get(id2)?.state === "merged" && tasks.get(id2), 60000);
const auto2 = t.events.find((e) => e.who === "factory" && e.text.startsWith("auto-merged"));
if (!auto2 || !countedDown(t) || !onMain(id2)) throw new Error(`${id2} wasn't auto-merged: ${t.events.at(-1).text}`);
step(`turned on: the factory counted down and ${auto2.text}; origin main has ${id2}`);

// 4. Unset (a policy from before the switch): auto-merges as it always did, without waiting.
await save(undefined, "unset");
const id3 = await ready(3, "Say hello, merged by the factory");
t = await wait(`${id3} merged`, () => tasks.get(id3)?.state === "merged" && tasks.get(id3), 60000);
const auto3 = t.events.find((e) => e.who === "factory" && e.text.startsWith("auto-merged"));
if (!auto3 || !countedDown(t) || waiting(t).length || !onMain(id3)) throw new Error(`${id3}: ${t.events.map((e) => e.text).join(" / ")}`);
step(`unset: the factory counted down and ${auto3.text}, waiting for nobody; origin main has ${id3}`);
console.log(`\n${tasks.get(id1).events.map((e) => `  ${e.who}: ${e.text.split("\n")[0]}`).join("\n")}\n`);

send({ type: "policy.save", policy: original });
await wait("policy restored", () => (policy.autoMerges !== false) === (original.autoMerges !== false));
feed.close();
process.exit(0);

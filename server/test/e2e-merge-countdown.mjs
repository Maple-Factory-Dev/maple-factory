// The auto-merge countdown (task.mergeAt). A low-risk task whose last gate passes isn't merged at once:
// the factory stamps mergeAt (now + MERGE_GRACE_MS), says "will auto-merge in Ns", keeps it reviewing
// until then and merges afterwards. The moment the countdown runs out it says "Merging…" (before its
// dry-run merge check), and a Merge sent then, or again while it merges, is a quiet no-op. Hold (task.holdMerge) stops it for good on that head and a person's
// Merge lands it; Request changes during the countdown clears it, and the next round counts down again.
//   node server/test/e2e-merge-countdown.mjs http://localhost:8788 <repo folder>
// Needs a real runner whose agents.toml has the `scripted` agent (test/scripted-agent.mjs), a local repo
// whose origin is a bare repo, and a short grace on the server (MERGE_GRACE_MS=1500 scripts/dev-stack.sh up).

import { execFileSync } from "node:child_process";

const [base = "http://localhost:8788", folder] = process.argv.slice(2);
if (!folder) throw new Error("usage: e2e-merge-countdown.mjs <server> <repo folder>");
const ws = base.replace(/^http/, "ws");
const { token } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();

const feed = new WebSocket(`${ws}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
const tasks = new Map();
let goals = [];
let policy = null;
let errors = [];
let poke = null;
/** Each toast the feed sent, with its task. */
const toasts = [];
/** Each task's states as the feed reported them, with when it saw each. */
const seen = new Map();
feed.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "snapshot") { goals = m.goals; policy = m.policy; for (const t of m.tasks) tasks.set(t.id, t); }
  if (m.type === "task.updated") {
    tasks.set(m.task.id, m.task);
    seen.set(m.task.id, [...(seen.get(m.task.id) ?? []), { at: Date.now(), state: m.task.state, mergeAt: m.task.mergeAt ?? null, liveLog: m.task.liveLog ?? null }]);
  }
  if (m.type === "policy.updated") policy = m.policy;
  if (m.type === "toast") toasts.push(m);
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
const pause = (ms) => new Promise((r) => setTimeout(r, ms));
const step = (text) => console.log(`✓ ${text}`);
const git = (...args) => execFileSync("git", args, { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
const counting = (t) => t.events.filter((e) => e.who === "factory" && e.text.startsWith("will auto-merge"));
const autoMerged = (t) => t.events.find((e) => e.who === "factory" && e.text.startsWith("auto-merged"));

await new Promise((r) => (feed.onopen = r));
send({ type: "subscribe" });
await wait("snapshot", () => policy);
const original = policy;
send({ type: "policy.save", policy: { ...policy, autoMerges: true, autoMerge: { ...policy.autoMerge, low: true } } });
await wait("policy", () => policy.autoMerges !== false && policy.autoMerge.low);
step("low risk auto-merges");

const prefix = `MC${Date.now() % 100000}`.slice(0, 7);
send({ type: "goal.save", goal: { id: "", name: `Countdown ${prefix}`, prefix, color: "#2EA043", summary: "Merge countdown test", lead: "", folder, base: "main" } });
const goal = await wait("goal", () => goals.find((g) => g.prefix === prefix));
step(`goal ${goal.name}`);

/** A low-risk task through planning and building, up to its countdown starting once the reviewer passes it. */
const counted = async (n, title) => {
  const id = `${prefix}-${n}`;
  send({ type: "task.create", goal: goal.id, title, brief: "Add hello.txt with a greeting.", shareable: false, plan: true, tickets: [], agent: "scripted" });
  await wait(`${id} plan`, () => tasks.get(id)?.state === "awaitingApproval", 60000);
  send({ type: "task.approvePlan", id });
  const t = await wait(`${id} countdown`, () => tasks.get(id)?.mergeAt && tasks.get(id), 180000);
  if (t.risk.level !== "low" || t.reviewsNeeded !== 0 || t.autoReview.rounds.at(-1).verdict !== "passed") throw new Error(`${id}: ${t.risk.level} risk, review ${t.autoReview.rounds.at(-1).verdict}`);
  const started = counting(t).at(-1);
  if (!started) throw new Error(`${id} counts down without saying so: ${t.events.at(-1).text}`);
  return { id, t, started, grace: t.mergeAt - started.at };
};
const origin = git("-C", folder, "remote", "get-url", "origin");
const onMain = (id) => { try { return git("-C", origin, "show", "main:hello.txt").includes(id); } catch { return false; } };

// (a) The countdown: mergeAt ≈ now + grace, reviewing until then, merged after.
const a = await counted(1, "Say hello after a countdown");
// Its passed-review toast says it merges on its own: nobody's review is needed (MF-172).
const passedToast = await wait(`${a.id} passed-review toast`, () => toasts.find((m) => m.taskId === a.id && m.text.includes("passed review")), 5000);
if (!passedToast.text.includes("merges on its own")) throw new Error(`${a.id}'s toast: ${passedToast.text}`);
if (toasts.some((m) => m.taskId === a.id && m.text.includes("ready for yours"))) throw new Error(`${a.id} was toasted ready for yours`);
step(`${a.id} toast: "${passedToast.text}"`);
if (a.grace < 500 || a.grace > 60000) throw new Error(`a grace of ${a.grace}ms`);
if (Math.abs(a.t.mergeAt - Date.now() - a.grace) > 1000) throw new Error(`mergeAt is ${a.t.mergeAt - Date.now()}ms away, the grace is ${a.grace}ms`);
step(`${a.id}: "${a.started.text}", mergeAt = then + ${a.grace}ms`);
await pause(Math.max(0, a.t.mergeAt - Date.now() - 300));
let t = tasks.get(a.id);
if (t.state !== "reviewing" || autoMerged(t) || onMain(a.id)) throw new Error(`${a.id} is ${t.state} 300ms before its mergeAt: ${t.events.at(-1).text}`);
step(`300ms before mergeAt: still reviewing, not merged, not on origin main`);
// A person's late click, right as the countdown ends: no error, no second merge.
await pause(Math.max(0, a.t.mergeAt - Date.now()));
send({ type: "task.merge", id: a.id });
const flipped = await wait(`${a.id} Merging…`, () => seen.get(a.id).find((s) => s.liveLog === "Merging…"), 10000);
// The hub's alarm fires at mergeAt; "within a tick" allows for its scheduling and the feed's hop.
if (flipped.at - a.t.mergeAt > 1000) throw new Error(`Merging… showed ${flipped.at - a.t.mergeAt}ms after mergeAt`);
if (seen.get(a.id).find((s) => s.liveLog === "Merging…" && s.at < a.t.mergeAt)) throw new Error("Merging… before mergeAt");
step(`Merging… showed ${flipped.at - a.t.mergeAt}ms after mergeAt; a Merge sent at 0s was no error`);
if (tasks.get(a.id).state === "reviewing") {
  send({ type: "task.merge", id: a.id });
  send({ type: "task.holdMerge", id: a.id });
  step("Merge and Hold sent again while it's merging");
}
t = await wait(`${a.id} merged`, () => tasks.get(a.id)?.state === "merged" && tasks.get(a.id), 30000);
await pause(1000); // a stray second merge would say so by now
t = tasks.get(a.id);
if (errors.length) throw new Error(`server said: ${errors.join("; ")}`);
const merges = t.events.filter((e) => /merged it/.test(e.text));
if (merges.length !== 1) throw new Error(`${merges.length} merges: ${merges.map((e) => `${e.who}: ${e.text}`).join(" / ")}`);
if (t.liveLog != null) throw new Error(`merged, still saying ${t.liveLog}`);
step(`no errors, exactly one merge ("${merges[0].who}: ${merges[0].text}"), liveLog cleared`);
const merged = seen.get(a.id).find((s) => s.state === "merged");
if (merged.at < a.t.mergeAt) throw new Error(`merged ${a.t.mergeAt - merged.at}ms before its mergeAt`);
const texts = t.events.map((e) => e.text);
if (texts.findIndex((x) => x.startsWith("will auto-merge")) > texts.findIndex((x) => x.startsWith("auto-merged")) || !onMain(a.id)) throw new Error(texts.join(" / "));
if (t.mergeAt != null) throw new Error(`merged with mergeAt ${t.mergeAt}`);
step(`${a.id} merged ${merged.at - a.t.mergeAt}ms after mergeAt ("${autoMerged(t).text}"), mergeAt null; origin main has it`);

// (b) Hold: no auto-merge, even after the grace; a person's Merge lands it.
const b = await counted(2, "Say hello, held");
send({ type: "task.holdMerge", id: b.id });
t = await wait(`${b.id} held`, () => tasks.get(b.id)?.mergeAt == null && tasks.get(b.id));
const held = t.events.find((e) => e.text === "held the auto-merge; a person merges it");
if (!held || held.who === "factory") throw new Error(`held by ${JSON.stringify(held)}`);
step(`${b.id}: ${held.who} "${held.text}", mergeAt null`);
await pause(b.grace + 3000);
t = tasks.get(b.id);
if (t.state !== "reviewing" || t.mergeAt != null || autoMerged(t) || t.liveLog === "Merging…" || onMain(b.id) || counting(t).length !== 1) {
  throw new Error(`${b.id} after its grace: ${t.state}, mergeAt ${t.mergeAt}, ${t.events.map((e) => e.text).join(" / ")}`);
}
step(`${b.grace + 3000}ms later: still reviewing, mergeAt null, no auto-merge, didn't count down again`);
send({ type: "task.holdMerge", id: b.id });
await wait("refusal", () => errors.length);
if (!/isn't counting down/.test(errors[0])) throw new Error(errors[0]);
step(`holding again is refused: "${errors[0]}"`);
errors = [];
send({ type: "task.merge", id: b.id });
t = await wait(`${b.id} merged`, () => tasks.get(b.id)?.state === "merged" && tasks.get(b.id), 60000);
const by = t.events.find((e) => e.text === "merged it");
if (!by || by.who === "factory" || autoMerged(t) || !onMain(b.id)) throw new Error(`${b.id}: ${t.events.map((e) => e.text).join(" / ")}`);
step(`a person merged it (${by.who}: "${by.text}"); origin main has ${b.id}`);

// (c) Request changes during the countdown clears it; the next passing round counts down again.
const c = await counted(3, "Say hello, changed mid-countdown");
send({ type: "task.steer", id: c.id, text: "Make the greeting friendlier." });
t = await wait(`${c.id} back to building`, () => tasks.get(c.id)?.state === "building" && tasks.get(c.id));
if (t.mergeAt != null) throw new Error(`mergeAt ${t.mergeAt} after Request changes`);
step(`${c.id}: Request changes sent it back to building with mergeAt null`);
t = await wait(`${c.id} merged`, () => tasks.get(c.id)?.state === "merged" && tasks.get(c.id), 240000);
if (counting(t).length !== 2 || !autoMerged(t)) throw new Error(`${c.id}: ${t.events.map((e) => e.text).join(" / ")}`);
step(`its next round counted down again and the factory ${autoMerged(t).text}`);

// (d) Turning auto-merge off mid-countdown clears it, even on a head that already said it's waiting for a
// person; turning it back on counts down afresh instead of merging at once.
send({ type: "policy.save", policy: { ...policy, autoMerges: false } });
await wait("auto-merge off", () => policy.autoMerges === false);
const d = `${prefix}-4`;
send({ type: "task.create", goal: goal.id, title: "Say hello, policy flipped", brief: "Add hello.txt with a greeting.", shareable: false, plan: true, tickets: [], agent: "scripted" });
await wait(`${d} plan`, () => tasks.get(d)?.state === "awaitingApproval", 60000);
send({ type: "task.approvePlan", id: d });
await wait(`${d} waiting for a person`, () => tasks.get(d)?.events.some((e) => e.text.startsWith("is ready; waiting for a person")), 180000);
const on = () => send({ type: "policy.save", policy: { ...policy, autoMerges: true } });
on();
await wait(`${d} countdown`, () => tasks.get(d)?.mergeAt);
send({ type: "policy.save", policy: { ...policy, autoMerges: false } });
t = await wait(`${d} countdown cleared`, () => policy.autoMerges === false && tasks.get(d)?.mergeAt == null && tasks.get(d));
if (t.state !== "reviewing" || autoMerged(t)) throw new Error(`${d}: ${t.state}, ${t.events.map((e) => e.text).join(" / ")}`);
step(`${d}: auto-merge off mid-countdown cleared mergeAt (the head had already said it's waiting for a person)`);
on();
t = await wait(`${d} counts down again`, () => policy.autoMerges !== false && tasks.get(d)?.mergeAt && tasks.get(d));
if (counting(t).length !== 2 || autoMerged(t)) throw new Error(`${d}: ${t.events.map((e) => e.text).join(" / ")}`);
t = await wait(`${d} merged`, () => tasks.get(d)?.state === "merged" && tasks.get(d), 30000);
step(`back on, it counted down afresh and the factory ${autoMerged(t).text}`);
console.log(`\n${tasks.get(b.id).events.map((e) => `  ${e.who}: ${e.text.split("\n")[0]}`).join("\n")}\n`);

send({ type: "policy.save", policy: original });
await wait("policy restored", () => (policy.autoMerges !== false) === (original.autoMerges !== false));
feed.close();
process.exit(0);

// A merge that fails. With "Fix merges automatically" off: the task raises a "didn't merge" hand
// instead of getting stuck, the factory doesn't retry on its own, "Try the merge again" retries once,
// Request changes with the hand open hands it to a builder, and "Send it back to fix" starts a
// new builder in the same worktree that merges the base in, after which review runs again and it merges.
// With it on: a conflicting merge goes straight back to a builder (no hand) and then merges, and one
// that keeps failing raises the hand after 2 automatic tries (the dry-run merge before an auto-merge
// catches the conflict first, and counts as a try).
// Merge forecasts: two tasks in review that both add hello.txt overlap; when the first merges, the
// second gets a dry-run merge right away and goes back to its builder before anyone tries to merge it.
//   node server/test/e2e-merge-conflict.mjs http://localhost:8788 <repo folder>
// Needs a real runner whose agents.toml has the `scripted` agent (test/scripted-agent.mjs), and a
// local repo whose origin is a bare repo.

import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const [base = "http://localhost:8788", folder] = process.argv.slice(2);
if (!folder) throw new Error("usage: e2e-merge-conflict.mjs <server> <repo folder>");
const ws = base.replace(/^http/, "ws");
const { token } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();

const feed = new WebSocket(`${ws}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
const tasks = new Map();
const cwds = new Map(); // session id → its folder, from the machines' live sessions
let goals = [];
let policy = null;
const errors = [];
let poke = null;
const firstConflict = new Map(); // task id → its first merge forecast with conflicts, as broadcast
const sessions = (m) => { for (const s of m.sessions ?? []) cwds.set(s.session.id, s.session.cwd); };
feed.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "snapshot") { goals = m.goals; policy = m.policy; for (const t of m.tasks) tasks.set(t.id, t); m.machines.forEach(sessions); }
  if (m.type === "task.updated") {
    tasks.set(m.task.id, m.task);
    if (m.task.mergeForecast?.conflicts.length && !firstConflict.has(m.task.id)) firstConflict.set(m.task.id, { forecast: m.task.mergeForecast, state: m.task.state, changes: m.task.changes });
  }
  if (m.type === "policy.updated") policy = m.policy;
  if (m.type === "goal.updated") goals = [...goals.filter((g) => g.id !== m.goal.id), m.goal];
  if (m.type === "machine.updated") sessions(m.machine);
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
const failedMerges = (t) => t.events.filter((e) => e.text.startsWith("couldn't merge")).length;
const git = (...args) => execFileSync("git", args, { encoding: "utf8" }).trim();

await new Promise((r) => (feed.onopen = r));
send({ type: "subscribe" });
await wait("snapshot", () => policy);
const original = policy;
const autoFix = async (on) => {
  send({ type: "policy.save", policy: { ...policy, autoFixMerges: on } });
  await wait(`autoFixMerges ${on}`, () => policy.autoFixMerges === on);
  step(`Fix merges automatically: ${on ? "on" : "off"}`);
};
await autoFix(false);

const prefix = `M${Date.now() % 100000}`.slice(0, 6);
send({ type: "goal.save", goal: { id: "", name: `Merge ${prefix}`, prefix, color: "#2EA043", summary: "Merge conflict test", lead: "", folder, base: "main" } });
const goal = await wait("goal", () => goals.find((g) => g.prefix === prefix));
step(`goal ${goal.name}`);

// Low risk: the factory merges it on its own, so a failed auto-merge is what's tested first.
send({ type: "task.create", goal: goal.id, title: "Say hello", brief: "Add hello.txt with a greeting.", shareable: false, plan: true, tickets: [], agent: "scripted" });
const id = `${prefix}-1`;
let t = await wait("plan", () => tasks.get(id)?.state === "awaitingApproval" && tasks.get(id), 60000);
send({ type: "task.approvePlan", id });
t = await wait("builder", () => tasks.get(id)?.worker?.role === "builder" && tasks.get(id));
const worktree = await wait("builder's folder", () => cwds.get(t.worker.session));
step(`${id} building in ${worktree}`);

// Someone else lands a hello.txt on main meanwhile: the task's branch no longer merges cleanly.
const origin = git("-C", folder, "remote", "get-url", "origin");
const conflict = (text) => {
  const other = mkdtempSync(join(tmpdir(), "mf-conflict-"));
  git("clone", "--quiet", origin, other);
  writeFileSync(join(other, "hello.txt"), text);
  git("-C", other, "add", "hello.txt");
  git("-C", other, "-c", "user.name=Other", "-c", "user.email=other@maple.invalid", "commit", "--quiet", "-m", "Someone else's hello.txt");
  git("-C", other, "push", "--quiet", "origin", "HEAD:main");
  rmSync(other, { recursive: true, force: true });
};
conflict(`hello from main (${prefix})\n`);
step("pushed a conflicting hello.txt to origin main");

t = await wait("review passed", () => tasks.get(id)?.autoReview?.rounds.at(-1)?.verdict === "passed" && tasks.get(id), 120000);
const rounds = t.autoReview.rounds.length;
step(`review passed (round ${rounds}); the factory tries to merge it`);

// 1. The failed merge raises a hand (not just a toast), and nothing retries it.
t = await wait("mergeFailed hand", () => tasks.get(id)?.hand?.reason === "mergeFailed" && tasks.get(id));
step(`hand raised (${t.hand.reason}): ${t.hand.summary.split("\n")[0]}`);
step(`its options: ${t.hand.options.map((o) => o.title + (o.recommended ? " (recommended)" : "")).join(" · ")}`);
if (t.state !== "reviewing" || t.worker) throw new Error(`it's ${t.state} with ${t.worker ? "a" : "no"} worker`);
send({ type: "task.merge", id });
await wait("merge refused", () => errors.length);
step(`Merge while the hand is open is refused: ${errors.splice(0).join("; ")}`);
await pause(5000);
if (failedMerges(tasks.get(id)) !== 1) throw new Error(`it tried ${failedMerges(tasks.get(id))} merges on its own`);
step("5s later: still 1 failed merge; auto-merge didn't retry");

// 2. "Try the merge again" retries once; it fails again and a new hand is raised.
const firstHand = t.hand.at;
send({ type: "task.resolveHand", id, option: "Try the merge again", note: "" });
t = await wait("second hand", () => tasks.get(id)?.hand?.reason === "mergeFailed" && tasks.get(id).hand.at !== firstHand && tasks.get(id));
step(`retried once; it failed again and a new hand is up (${failedMerges(t)} failed merges)`);
await pause(5000);
if (failedMerges(tasks.get(id)) !== 2) throw new Error(`it tried ${failedMerges(tasks.get(id))} merges`);
step("5s later: still 2 failed merges; nothing loops");

// 3. Request changes with the hand open: the hand clears and a builder takes it, rather than the
// task sitting in building behind a stale hand. What it pushes still doesn't merge: a new hand.
const secondHand = t.hand.at;
send({ type: "task.steer", id, text: "Add a sign-off line.", anchor: null });
t = await wait("steered to building", () => tasks.get(id)?.state === "building" && tasks.get(id));
if (t.hand) throw new Error(`it's building with a ${t.hand.reason} hand still up`);
step(`Request changes with the hand open: building, hand cleared ("${t.events.at(-1).text}")`);
t = await wait("steered builder", () => tasks.get(id)?.worker?.role === "builder" && tasks.get(id));
step(`a builder started on it (${t.worker.session.slice(0, 8)})`);
t = await wait("third hand", () => tasks.get(id)?.hand?.reason === "mergeFailed" && tasks.get(id).hand.at !== secondHand && tasks.get(id), 120000);
const steerRounds = t.autoReview.rounds.length;
step(`it pushed, review passed again (round ${steerRounds}), the merge failed again and a new hand is up (${failedMerges(t)} failed merges)`);

// 4. "Send it back to fix": a new builder in the same worktree, with the change request.
send({ type: "task.resolveHand", id, option: "Send it back to fix", note: "" });
t = await wait("back to building", () => tasks.get(id)?.state === "building" && tasks.get(id));
const change = t.changes.at(-1);
step(`back to building with ${change.id}: ${change.text.split(" (")[0]}… [${change.anchor}]`);
t = await wait("new builder", () => tasks.get(id)?.worker?.role === "builder" && tasks.get(id));
const again = await wait("new builder's folder", () => cwds.get(t.worker.session));
if (again !== worktree) throw new Error(`the new builder is in ${again}, not ${worktree}`);
step(`new builder session ${t.worker.session.slice(0, 8)} in the same worktree (${again})`);

t = await wait("applied", () => tasks.get(id)?.changes.find((c) => c.id === change.id)?.status === "applied" && tasks.get(id), 60000);
step(`${change.id} applied`);

// 5. Review runs again on what it pushed, and then it merges.
t = await wait("review again", () => (tasks.get(id)?.autoReview?.rounds.length ?? 0) > steerRounds && tasks.get(id), 60000);
const merge = git("-C", origin, "log", "-1", "--format=%s", t.branch);
if (!merge.includes(change.id) || !merge.includes("doesn't merge into main")) throw new Error(`the branch's last commit is ${JSON.stringify(merge)}`);
step(`pushed the merge, made from ${change.id} in its prompt: ${JSON.stringify(merge.slice(0, 90))}`);
step(`review restarted: round ${t.autoReview.rounds.length}`);
t = await wait("merged", () => tasks.get(id)?.state === "merged" && tasks.get(id), 120000);
const hello = git("-C", origin, "show", "main:hello.txt");
if (!hello.includes(id) || !hello.includes("hello from main")) throw new Error(`origin's main has ${JSON.stringify(hello)}`);
step(`merged; origin main hello.txt keeps both sides: ${JSON.stringify(hello.split("\n"))}`);
console.log(`\n${t.events.map((e) => `  ${e.who}: ${e.text.split("\n")[0]}`).join("\n")}\n`);

// 6. Fix merges automatically, on: a task whose branch won't merge goes back to a builder with no hand.
await autoFix(true);
const build = async (n, what) => {
  const id = `${prefix}-${n}`;
  send({ type: "task.create", goal: goal.id, title: what, brief: "Add hello.txt with a greeting.", shareable: false, plan: true, tickets: [], agent: "scripted" });
  await wait(`${id} plan`, () => tasks.get(id)?.state === "awaitingApproval", 60000);
  send({ type: "task.approvePlan", id });
  await wait(`${id} builder`, () => tasks.get(id)?.worker?.role === "builder");
  return id;
};
const autoFixed = (t) => t.events.filter((e) => /^(couldn't|won't) merge: .*; sent it back to fix the merge \(try \d of 2\)$/.test(e.text));
const id2 = await build(2, "Say hello, fixed automatically");
conflict(`hello from main again (${prefix}-2)\n`);
step(`${id2} building; pushed a conflicting hello.txt to origin main`);
t = await wait(`${id2} sent back`, () => { const t = tasks.get(id2); return t && autoFixed(t).length === 1 && t.state === "building" && t; }, 180000);
if (t.hand) throw new Error(`it's building with a ${t.hand.reason} hand up`);
const fix = t.changes.at(-1);
if (fix.author !== "factory" || fix.anchor !== "Didn't merge into main") throw new Error(`its change request is ${JSON.stringify(fix)}`);
step(`the merge failed and it went back to building on its own, no hand: "${autoFixed(t)[0].text.slice(0, 110)}…"`);
step(`with ${fix.id} from ${fix.author}: ${fix.text.split(" (")[0]}… [${fix.anchor}]`);
t = await wait(`${id2} merged`, () => tasks.get(id2)?.state === "merged" && tasks.get(id2), 180000);
if (t.events.some((e) => e.text.startsWith("stopped and needs a hand"))) throw new Error("a hand was raised on the way");
step(`${id2} merged after 1 automatic fix, with no hand raised`);
console.log(`\n${t.events.map((e) => `  ${e.who}: ${e.text.split("\n")[0]}`).join("\n")}\n`);

// 7. A merge that keeps failing (main moves again each time the builder fixes it): 2 automatic tries, then the hand.
const id3 = await build(3, "Say hello, never merging");
let pushes = 1;
conflict(`hello from main, take ${pushes} (${prefix}-3)\n`);
step(`${id3} building; pushed a conflicting hello.txt to origin main`);
for (let n = 1; n <= 2; n++) {
  t = await wait(`${id3} try ${n}`, () => { const t = tasks.get(id3); return t && autoFixed(t).length === n && t.state === "building" && t.changes.length === n && t; }, 180000);
  if (t.hand) throw new Error(`try ${n} came with a ${t.hand.reason} hand`);
  const c = t.changes.at(-1);
  step(`try ${n}: sent back to fix the merge with ${c.id}, no hand`);
  await wait(`${c.id} applied`, () => tasks.get(id3)?.changes.find((x) => x.id === c.id)?.status === "applied", 120000);
  // The builder has merged main in; main moves again before the factory merges.
  conflict(`hello from main, take ${++pushes} (${prefix}-3)\n`);
  step(`${c.id} applied; pushed another conflicting hello.txt to origin main`);
}
t = await wait(`${id3} hand`, () => tasks.get(id3)?.hand?.reason === "mergeFailed" && tasks.get(id3), 180000);
if (autoFixed(t).length !== 2) throw new Error(`it tried ${autoFixed(t).length} automatic fixes`);
if (!t.hand.summary.endsWith("(after 2 tries)")) throw new Error(`the hand says ${JSON.stringify(t.hand.summary)}`);
step(`after 2 automatic tries the hand is up: ${t.hand.summary.split("\n")[0]}`);
step(`its options: ${t.hand.options.map((o) => o.title + (o.recommended ? " (recommended)" : "")).join(" · ")}`);
await pause(5000);
if (tasks.get(id3).state !== "reviewing" || autoFixed(tasks.get(id3)).length !== 2) throw new Error(`it's ${tasks.get(id3).state} after ${autoFixed(tasks.get(id3)).length} tries`);
step("5s later: still reviewing with the hand up; no third try");
console.log(`\n${t.events.map((e) => `  ${e.who}: ${e.text.split("\n")[0]}`).join("\n")}\n`);
send({ type: "task.cancel", id: id3 });

// 8. Merge forecasts. Two tasks both add hello.txt and both wait in review (auto-merge off, so a
// person merges). Merging the first sends the second back to its builder at once, from a dry-run
// merge, with a merge change request; its forecast lists hello.txt; its own merge never fails.
send({ type: "policy.save", policy: { ...policy, autoMerges: false } });
await wait("autoMerges off", () => policy.autoMerges === false);
step("auto-merge: off (a person merges)");
const [a, b] = [await build(4, "Say hello first"), await build(5, "Say hello second")];
const ready = (id) => { const t = tasks.get(id); return t?.state === "reviewing" && t.autoReview?.rounds.at(-1)?.verdict === "passed" && t.events.some((e) => e.text.startsWith("is ready; waiting for a person")) && t; };
await wait(`${a} and ${b} ready`, () => ready(a) && ready(b), 300000);
t = await wait(`${b} overlaps ${a}`, () => { const t = tasks.get(b); return t.mergeForecast?.overlaps.some((o) => o.task === a && o.files.includes("hello.txt")) && t; });
const ta = tasks.get(a);
if (!ta.mergeForecast?.overlaps.some((o) => o.task === b)) throw new Error(`${a}'s forecast is ${JSON.stringify(ta.mergeForecast)}`);
step(`both ready to merge; their forecasts overlap both ways: ${b} ${JSON.stringify(t.mergeForecast.overlaps)}, ${a} ${JSON.stringify(ta.mergeForecast.overlaps)}`);
send({ type: "task.merge", id: a });
await wait(`${a} merged`, () => tasks.get(a)?.state === "merged");
step(`${a} merged into main`);
t = await wait(`${b} sent back`, () => { const t = tasks.get(b); return t.state === "building" && t.changes.at(-1)?.anchor === "Didn't merge into main" && t; }, 60000);
const seen = firstConflict.get(b);
if (!seen || !seen.forecast.conflicts.includes("hello.txt") || seen.forecast.since !== a) throw new Error(`${b}'s first conflicted forecast is ${JSON.stringify(seen)}`);
const sentBack = t.events.find((e) => e.text.startsWith(`${a} merged into main and now it conflicts in`));
if (!sentBack) throw new Error(`no merge-check event on ${b}: ${JSON.stringify(t.events.slice(-5))}`);
if (failedMerges(t) || autoFixed(t).length || t.hand) throw new Error(`${b} had ${failedMerges(t)} failed merges, ${autoFixed(t).length} counted tries, hand ${t.hand?.reason}`);
step(`${b}'s forecast after the check: conflicts ${JSON.stringify(seen.forecast.conflicts)} since ${seen.forecast.since} (checked against ${seen.forecast.base})`);
step(`${b} went back to building with no merge attempted: "${sentBack.text}"`);
step(`with ${t.changes.at(-1).id} [${t.changes.at(-1).anchor}]: ${t.changes.at(-1).text.slice(0, 120)}…`);
if (t.mergeForecast.overlaps.length) throw new Error(`${b} still overlaps ${JSON.stringify(t.mergeForecast.overlaps)} after ${a} merged`);
step(`${b} no longer lists ${a} as an overlap (it's merged)`);
t = await wait(`${b} ready again`, () => ready(b) && tasks.get(b).changes.at(-1).status === "applied" && !tasks.get(b).mergeForecast?.conflicts.length && tasks.get(b), 300000);
step(`${b}'s builder merged main in, review passed again; its forecast has no conflicts`);
send({ type: "task.merge", id: b });
t = await wait(`${b} merged`, () => tasks.get(b)?.state === "merged" && tasks.get(b), 60000);
if (failedMerges(t)) throw new Error(`${b}'s own merge failed ${failedMerges(t)} times`);
step(`${b} merged on its first try: ${failedMerges(t)} failed merges`);
console.log(`\n${t.events.map((e) => `  ${e.who}: ${e.text.split("\n")[0]}`).join("\n")}\n`);

send({ type: "policy.save", policy: original });
await wait("policy restored", () => (policy.autoFixMerges !== false) === (original.autoFixMerges !== false));
feed.close();
process.exit(0);

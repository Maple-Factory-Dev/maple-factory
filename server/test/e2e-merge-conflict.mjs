// A merge that fails: the task raises a "didn't merge" hand instead of getting stuck, the factory
// doesn't retry on its own, "Try the merge again" retries once, and "Send it back to fix" starts a
// new builder in the same worktree that merges the base in, after which review runs again and it merges.
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
const errors = [];
let poke = null;
const sessions = (m) => { for (const s of m.sessions ?? []) cwds.set(s.session.id, s.session.cwd); };
feed.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "snapshot") { goals = m.goals; for (const t of m.tasks) tasks.set(t.id, t); m.machines.forEach(sessions); }
  if (m.type === "task.updated") tasks.set(m.task.id, m.task);
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
await wait("snapshot", () => tasks.size >= 0 && goals);

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
const other = mkdtempSync(join(tmpdir(), "mf-conflict-"));
git("clone", "--quiet", origin, other);
writeFileSync(join(other, "hello.txt"), `hello from main (${prefix})\n`);
git("-C", other, "add", "hello.txt");
git("-C", other, "-c", "user.name=Other", "-c", "user.email=other@maple.invalid", "commit", "--quiet", "-m", "Someone else's hello.txt");
git("-C", other, "push", "--quiet", "origin", "HEAD:main");
rmSync(other, { recursive: true, force: true });
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

// 3. "Send it back to fix": a new builder in the same worktree, with the change request.
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

// 4. Review runs again on what it pushed, and then it merges.
t = await wait("review again", () => (tasks.get(id)?.autoReview?.rounds.length ?? 0) > rounds && tasks.get(id), 60000);
const merge = git("-C", origin, "log", "-1", "--format=%s", t.branch);
if (!merge.includes(change.id) || !merge.includes("doesn't merge into main")) throw new Error(`the branch's last commit is ${JSON.stringify(merge)}`);
step(`pushed the merge, made from ${change.id} in its prompt: ${JSON.stringify(merge.slice(0, 90))}`);
step(`review restarted: round ${t.autoReview.rounds.length}`);
t = await wait("merged", () => tasks.get(id)?.state === "merged" && tasks.get(id), 120000);
const hello = git("-C", origin, "show", "main:hello.txt");
if (!hello.includes(id) || !hello.includes("hello from main")) throw new Error(`origin's main has ${JSON.stringify(hello)}`);
step(`merged; origin main hello.txt keeps both sides: ${JSON.stringify(hello.split("\n"))}`);
console.log(`\n${t.events.map((e) => `  ${e.who}: ${e.text.split("\n")[0]}`).join("\n")}`);
feed.close();
process.exit(0);

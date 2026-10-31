// Moving a task to another goal (`task.moveGoal`), against `wrangler dev` and a runner with the scripted agent:
//   node server/test/e2e-move-goal.mjs http://localhost:8788
// It makes its own local repo (a bare origin and a clone) under $TMPDIR; give the server a short grace
// (MERGE_GRACE_MS=1500 scripts/dev-stack.sh up) so the moved task's auto-merge doesn't keep it waiting.
// Checks: a draft moves with its id, lands at the bottom of the new goal's drafts, leaves its effort and
// says "moved it from … to …"; a repo the target doesn't work in, its own goal, an archived target and a
// merged task are refused; a high-risk task in review moves with its plan and branch, and the target's
// accepted risk is applied (no final review), so it auto-merges there.

import { execFileSync } from "node:child_process";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const [base = "http://localhost:8788"] = process.argv.slice(2);
const ws = base.replace(/^http/, "ws");
const { token } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();
const feed = new WebSocket(`${ws}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
const tasks = new Map();
let goals = [];
let policy = null;
let errors = [];
let poke = null;
feed.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "snapshot") { goals = m.goals; policy = m.policy; for (const t of m.tasks) tasks.set(t.id, t); }
  if (m.type === "goal.updated") goals = [...goals.filter((g) => g.id !== m.goal.id), m.goal];
  if (m.type === "task.updated") tasks.set(m.task.id, m.task);
  if (m.type === "policy.updated") policy = m.policy;
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
    await new Promise((r) => { poke = r; setTimeout(r, 100); });
  }
};
const step = (text) => console.log(`✓ ${text}`);
const check = (ok, why) => { if (!ok) throw new Error(why); };
/** Sends `m` and resolves to the error it's refused with; the task is left as it was. */
const refused = async (m, like) => {
  const before = JSON.stringify(tasks.get(m.id));
  errors = [];
  send(m);
  const deadline = Date.now() + 5000;
  while (!errors.length && Date.now() < deadline) await new Promise((r) => setTimeout(r, 50));
  const said = errors.shift() ?? fail(`${JSON.stringify(m)} wasn't refused`);
  check(like.test(said), `refused with "${said}"`);
  await new Promise((r) => setTimeout(r, 300));
  check(JSON.stringify(tasks.get(m.id)) === before, `${m.id} changed although it was refused`);
  return said;
};
const fail = (why) => { throw new Error(why); };
const git = (...args) => execFileSync("git", args, { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
const eventsOf = (id) => tasks.get(id).events.map((e) => e.text);

await new Promise((r) => (feed.onopen = r));
send({ type: "subscribe" });
await wait("snapshot", () => policy);

// A local repo the folder goals share: a bare origin with main, and its clone.
const dir = mkdtempSync(join(tmpdir(), "mf-move-goal-"));
git("init", "-q", "--bare", "-b", "main", join(dir, "origin.git"));
git("clone", "-q", join(dir, "origin.git"), join(dir, "repo"));
const folder = join(dir, "repo");
git("-C", folder, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init");
git("-C", folder, "push", "-q", "origin", "HEAD:main");

const n = Date.now() % 10000;
const saveGoal = async (prefix, extra) => {
  send({ type: "goal.save", goal: { id: "", name: `Move ${prefix}`, prefix, color: "#8B5CF6", summary: "", lead: "", repos: [], base: "main", ...extra } });
  return wait(prefix, () => goals.find((g) => g.prefix === prefix));
};
const from = await saveGoal(`MA${n}`, { folder });
const to = await saveGoal(`MB${n}`, { folder });
const archived = await saveGoal(`MZ${n}`, { folder });
send({ type: "goal.archive", id: archived.id, archived: true });
await wait("archived", () => goals.find((g) => g.id === archived.id)?.archived);
const elsewhere = await saveGoal(`MX${n}`, { folder: join(dir, "other") });
const multi = await saveGoal(`MR${n}`, { repos: ["acme/one", "acme/two"] });
const two = await saveGoal(`MT${n}`, { repos: ["acme/two"] });
step(`goals ${from.prefix} and ${to.prefix} on ${folder}, ${archived.prefix} archived, ${elsewhere.prefix} on another folder, ${multi.prefix} (acme/one, acme/two) and ${two.prefix} (acme/two)`);

const create = async (goal, title, extra = {}) => {
  const before = new Set(tasks.keys());
  send({ type: "task.create", goal: goal.id, title, brief: "Add hello.txt with a greeting.", shareable: false, plan: false, tickets: [], agent: "scripted", ...extra });
  return wait(title, () => [...tasks.values()].find((x) => !before.has(x.id) && x.title === title));
};

// (a) A draft moves: same id, the bottom of the target's drafts, out of its effort.
const already = await create(to, "Already there");
const draft = await create(from, "Move me", { effort: "Greetings" });
check(draft.effort === "Greetings", "no effort to leave");
send({ type: "task.moveGoal", id: draft.id, goal: to.id });
let t = await wait("moved draft", () => tasks.get(draft.id)?.goal === to.id && tasks.get(draft.id));
check(t.state === "drafting" && t.effort == null, `${t.id}: ${t.state}, effort ${t.effort}`);
check(t.draftRank > tasks.get(already.id).draftRank, `${t.id} isn't below ${already.id} in the drafts`);
const drafts = [...tasks.values()].filter((x) => x.goal === to.id && x.state === "drafting").sort((a, b) => a.draftRank - b.draftRank).map((x) => x.id);
check(drafts.at(-1) === draft.id, `${to.prefix}'s drafts: ${drafts}`);
check(eventsOf(draft.id).at(-1) === `moved it from ${from.name} to ${to.name}`, eventsOf(draft.id).join(" / "));
check(![...tasks.values()].some((x) => x.goal === from.id && x.id === draft.id), "still in the old goal");
step(`draft ${draft.id} kept its id, is last of ${to.prefix}'s drafts (${drafts.join(", ")}), left its effort: "${eventsOf(draft.id).at(-1)}"`);

// (b) Refusals.
step(`its own goal: "${await refused({ type: "task.moveGoal", id: draft.id, goal: to.id }, /already in that goal/)}"`);
step(`an archived goal: "${await refused({ type: "task.moveGoal", id: draft.id, goal: archived.id }, /archived/)}"`);
step(`a goal on another folder: "${await refused({ type: "task.moveGoal", id: draft.id, goal: elsewhere.id }, /doesn't work in/)}"`);
step(`a goal with repos: "${await refused({ type: "task.moveGoal", id: draft.id, goal: multi.id }, /doesn't work in/)}"`);
step(`a goal that doesn't exist: "${await refused({ type: "task.moveGoal", id: draft.id, goal: "nope" }, /doesn't exist/)}"`);
const one = await create(multi, "On acme/one");
check(one.repo == null, "it picked a repo");
step(`${one.id} (the goal's first repo, acme/one) to ${two.prefix}: "${await refused({ type: "task.moveGoal", id: one.id, goal: two.id }, /doesn't work in acme\/one; add it to the goal's repos first/)}"`);
const onTwo = await create(multi, "On acme/two", { repo: "acme/two" });
send({ type: "task.moveGoal", id: onTwo.id, goal: two.id });
t = await wait("moved on acme/two", () => tasks.get(onTwo.id)?.goal === two.id && tasks.get(onTwo.id));
check(t.repo === "acme/two", `repo ${t.repo}`);
step(`${onTwo.id} on acme/two moved to ${two.prefix}, which works in it`);

// (c) A high-risk task in review moves with its plan and branch; the target's accepted risk drops its final review.
send({ type: "goal.acceptRisk", goal: to.id, upTo: "high", note: "e2e" });
await wait("accepted", () => true);
const busy = await create(from, "Risky greeting", { brief: "[risky] Add hello.txt with a greeting.", plan: true });
await wait("plan", () => tasks.get(busy.id)?.state === "awaitingApproval", 60000);
// It needs more approvals than one person's: everyone it asks for.
for (let i = 0; i < tasks.get(busy.id).approvalsNeeded; i++) {
  const as = i === 0 ? null : `appr${i}`;
  if (!as) { send({ type: "task.approvePlan", id: busy.id }); continue; }
  const { token: tk } = await (await fetch(`${base}/dev/token?as=${as}`, { method: "POST" })).json();
  const sock = new WebSocket(`${ws}/client/connect`, { headers: { authorization: `Bearer ${tk}` } });
  await new Promise((r) => (sock.onopen = r));
  sock.send(JSON.stringify({ type: "task.approvePlan", id: busy.id }));
  await new Promise((r) => setTimeout(r, 500));
  sock.close();
}
const passed = (x) => x?.state === "reviewing" && x.autoReview?.rounds.at(-1)?.verdict === "passed";
t = await wait("review passed", () => passed(tasks.get(busy.id)) && tasks.get(busy.id), 240000);
check(t.risk.level === "high" && t.reviewsNeeded >= 1 && t.mergeAt == null, `${t.id}: ${t.risk.level}, ${t.reviewsNeeded} reviews, mergeAt ${t.mergeAt}`);
const kept = { plan: JSON.stringify(t.plan), pr: JSON.stringify(t.pr), branch: t.branch, approvals: t.approvals.join() };
step(`${t.id} in review on ${t.branch}: high risk, ${t.approvalsNeeded} approvals, ${t.reviewsNeeded} final review(s) needed`);
send({ type: "task.moveGoal", id: busy.id, goal: to.id });
t = await wait("moved in review", () => tasks.get(busy.id)?.goal === to.id && tasks.get(busy.id));
check(JSON.stringify(t.plan) === kept.plan && JSON.stringify(t.pr) === kept.pr && t.branch === kept.branch && t.approvals.join() === kept.approvals, "lost its plan, pull request, branch or approvals");
check(t.reviewsNeeded === 0 && t.approvalsNeeded === policy.planApprovals.high, `${t.reviewsNeeded} reviews, ${t.approvalsNeeded} approvals after the move`);
check(t.risk.factors.some((f) => f.source === "acceptance"), "no acceptance factor");
check(eventsOf(busy.id).includes(`moved it from ${from.name} to ${to.name}`), eventsOf(busy.id).join(" / "));
step(`${busy.id} moved in review with its plan, branch ${t.branch} and approvals; ${to.prefix}'s accepted risk: ${t.reviewsNeeded} final reviews, ${t.approvalsNeeded} approvals`);
t = await wait("auto-merged in its new goal", () => tasks.get(busy.id)?.state === "merged" && tasks.get(busy.id), 60000);
step(`${busy.id} auto-merged in ${to.prefix}: "${t.events.filter((e) => e.who === "factory").at(-1)?.text}"`);
step(`a merged task: "${await refused({ type: "task.moveGoal", id: busy.id, goal: from.id }, /merged/)}"`);

// A fresh snapshot agrees.
const fresh = await (async () => {
  const s = new WebSocket(`${ws}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
  await new Promise((r) => (s.onopen = r));
  const snap = new Promise((r) => (s.onmessage = (e) => { const m = JSON.parse(e.data); if (m.type === "snapshot") r(m); }));
  s.send(JSON.stringify({ type: "subscribe" }));
  const m = await snap;
  s.close();
  return new Map(m.tasks.map((x) => [x.id, x]));
})();
check(fresh.get(draft.id).goal === to.id && fresh.get(busy.id).goal === to.id && fresh.get(onTwo.id).goal === two.id, "the snapshot has them in their old goals");
step("a new snapshot has them in their new goals");

for (const x of [draft.id, already.id, one.id, onTwo.id]) send({ type: "task.cancel", id: x });
send({ type: "goal.acceptRisk", goal: to.id });
await new Promise((r) => setTimeout(r, 500));
process.exit(0);

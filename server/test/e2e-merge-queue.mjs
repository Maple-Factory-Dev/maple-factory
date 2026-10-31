// Merging through GitHub's merge queue, against the fake GitHub (test/fake-github.mjs):
//   node server/test/e2e-merge-queue.mjs http://localhost:8788 <repo folder> [fake GitHub URL]
// Set up as for e2e-github.mjs (the server's GitHub App vars, the runner's MAPLE_TASK_PUSH_URL /
// MAPLE_TASK_FETCH_URL, origin https://github.com/acme/greeter.git, the fake with `--ci test`).
// Checks: when main requires a merge queue (/_queue), an approved task is added to the queue with
// GraphQL enqueuePullRequest pinned to its head rather than squash-merged (no PUT /merge), says "In merge
// queue…" and becomes merged when the queue merges it (the pull_request closed webhook). A queue that
// takes it out (`dequeued`, CI_FAILURE) leaves it reviewing with a "didn't merge" hand carrying GitHub's
// reason. With the queue off again, a task squash-merges as before.

import { execFileSync } from "node:child_process";
import { dirname } from "node:path";

const [base = "http://localhost:8788", folder = "/tmp/mfgh/greeter", gh = "http://localhost:18803"] = process.argv.slice(2);
const ws = base.replace(/^http/, "ws");
const { token } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();
const feed = new WebSocket(`${ws}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
const tasks = new Map();
const logs = new Map(); // task id → every liveLog it showed
let goals = [];
let errors = [];
let poke = null;
feed.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "snapshot") { goals = m.goals; for (const t of m.tasks) tasks.set(t.id, t); }
  if (m.type === "goal.updated") goals = [...goals.filter((g) => g.id !== m.goal.id), m.goal];
  if (m.type === "task.updated") {
    tasks.set(m.task.id, m.task);
    if (m.task.liveLog) logs.set(m.task.id, [...(logs.get(m.task.id) ?? []), m.task.liveLog]);
  }
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
const fake = async () => (await fetch(`${gh}/_log`)).json();
const queue = (then, extra = {}) => fetch(`${gh}/_queue`, { method: "POST", body: JSON.stringify({ owner: "acme", repo: "greeter", branch: "main", then, ...extra }) });
const origin = `${dirname(folder)}/remotes/acme/greeter.git`;
const timeline = (t) => console.log(`\n${t.events.map((e) => `  ${e.who}: ${e.text.split("\n")[0]}`).join("\n")}\n`);

await new Promise((r) => (feed.onopen = r));
send({ type: "subscribe" });
await wait("snapshot", () => true);
const prefix = `MQ${Date.now() % 1000}`;
send({ type: "goal.save", goal: { id: "", name: `Merge queue ${prefix}`, prefix, color: "#8B5CF6", summary: "Through GitHub's merge queue", lead: "", folder, base: "main" } });
const goal = await wait("goal", () => goals.find((g) => g.prefix === prefix));
step(`goal ${goal.name} on ${folder} (origin github.com/acme/greeter)`);

/** A task that passes review and CI, so the factory merges it on its own. */
const ready = async (n, title, file) => {
  const id = `${prefix}-${n}`;
  send({ type: "task.create", goal: goal.id, title, brief: `Add ${file} with a greeting.`, shareable: false, plan: true, tickets: [], agent: "scripted" });
  await wait(`${id} plan`, () => tasks.get(id)?.state === "awaitingApproval", 60000);
  send({ type: "task.approvePlan", id });
  await wait(`${id} pull request`, () => tasks.get(id)?.pr?.url, 90000);
  const t = await wait(`${id} review passed`, () => tasks.get(id)?.autoReview?.rounds.at(-1)?.verdict === "passed" && tasks.get(id), 120000);
  const before = (await fake()).log.length;
  await fetch(`${gh}/_checks`, { method: "POST", body: JSON.stringify({ owner: "acme", repo: "greeter", sha: t.pr.head, runs: [{ name: "test", conclusion: "success" }] }) });
  step(`${id} opened #${t.pr.number}, passed review and CI`);
  return { id, pr: t.pr, before };
};
const calls = async (since, number) => (await fake()).log.slice(since).filter((l) =>
  (l.method === "PUT" && l.path === `/repos/acme/greeter/pulls/${number}/merge`) || (l.path === "/graphql" && /enqueuePullRequest/.test(l.body?.query ?? "")) || l.path.startsWith("/repos/acme/greeter/rules/"));

// 1. main requires a merge queue: the task is queued, not merged, and lands when the queue merges it.
await queue("merge", { delayMs: 2500 });
step("main requires a merge queue; the fake's queue merges what's added to it");
const a = await ready(1, "Say hello through the queue", "hello.txt");
let t = await wait(`${a.id} in merge queue`, () => tasks.get(a.id)?.liveLog === "In merge queue…" && tasks.get(a.id), 30000);
const added = t.events.find((e) => e.text.startsWith(`added pull request #${a.pr.number} to GitHub's merge queue`));
if (!added) throw new Error(`no merge-queue event: ${t.events.map((e) => e.text).join(" / ")}`);
step(`${a.id} says "${t.liveLog}"; timeline: "${added.text}"`);
send({ type: "task.merge", id: a.id });
t = await wait(`${a.id} merged`, () => tasks.get(a.id)?.state === "merged" && tasks.get(a.id), 30000);
const seenA = await calls(a.before, a.pr.number);
const enqueued = seenA.find((l) => l.path === "/graphql");
if (!seenA.some((l) => l.path === "/repos/acme/greeter/rules/branches/main")) throw new Error(`the rules weren't read: ${JSON.stringify(seenA)}`);
if (!enqueued || enqueued.body.variables.head !== a.pr.head) throw new Error(`enqueuePullRequest: ${JSON.stringify(enqueued)}`);
if (seenA.some((l) => l.method === "PUT")) throw new Error(`it was merged with PUT /merge: ${JSON.stringify(seenA)}`);
if (seenA.filter((l) => l.path === "/graphql").length !== 1) throw new Error(`enqueued ${seenA.filter((l) => l.path === "/graphql").length} times (a Merge click while queued should do nothing)`);
step(`GitHub got rules/branches/main and one enqueuePullRequest pinned to ${a.pr.head.slice(0, 7)}, and no PUT /merge (a Merge click while queued did nothing)`);
const hello = execFileSync("git", ["--git-dir", origin, "show", "main:hello.txt"], { encoding: "utf8" });
if (!hello.includes(a.id)) throw new Error(`main has ${JSON.stringify(hello)}`);
if (t.liveLog) throw new Error(`merged but still says ${t.liveLog}`);
step(`${a.id} merged when the queue merged it (webhook); main has its hello.txt; it showed ${[...new Set(logs.get(a.id))].join(" → ")}`);
timeline(t);

// 2. The queue takes it out: a "didn't merge" hand with GitHub's reason, still reviewing.
await queue("dequeue", { reason: "CI_FAILURE" });
step("the fake's queue now takes pull requests out (CI_FAILURE)");
const b = await ready(2, "Wave through the queue", "wave.txt");
t = await wait(`${b.id} hand`, () => tasks.get(b.id)?.hand?.reason === "mergeFailed" && tasks.get(b.id), 60000);
if (t.state !== "reviewing" || t.liveLog) throw new Error(`${b.id} is ${t.state}, saying ${t.liveLog}`);
if (t.hand.summary !== "GitHub took it out of the merge queue: the checks on its merge group failed.") throw new Error(`the hand says ${JSON.stringify(t.hand.summary)}`);
if (!t.events.some((e) => e.text.startsWith(`added pull request #${b.pr.number} to GitHub's merge queue`))) throw new Error("it wasn't queued first");
if ((await calls(b.before, b.pr.number)).some((l) => l.method === "PUT")) throw new Error("it was merged with PUT /merge");
step(`${b.id} was queued, then taken out: reviewing, hand "${t.hand.summary}"`);
step(`its options: ${t.hand.options.map((o) => o.title + (o.recommended ? " (recommended)" : "")).join(" · ")}`);
timeline(t);
send({ type: "task.cancel", id: b.id });

// 3. No queue: squash-merged with PUT /merge, as before.
await queue("off");
step("main no longer requires a merge queue");
const c = await ready(3, "Say hi without a queue", "hi.txt");
t = await wait(`${c.id} merged`, () => tasks.get(c.id)?.state === "merged" && tasks.get(c.id), 30000);
const seenC = await calls(c.before, c.pr.number);
if (!seenC.some((l) => l.method === "PUT") || seenC.some((l) => l.path === "/graphql")) throw new Error(`without a queue GitHub got: ${JSON.stringify(seenC.map((l) => `${l.method} ${l.path}`))}`);
if (t.events.some((e) => /merge queue/.test(e.text)) || (logs.get(c.id) ?? []).includes("In merge queue…")) throw new Error("it mentions the merge queue");
step(`${c.id} squash-merged with PUT /merge, no enqueue, never "In merge queue…"`);
process.exit(0);

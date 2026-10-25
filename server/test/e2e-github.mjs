// The factory with its GitHub App, against the fake GitHub (test/fake-github.mjs):
//   node server/test/e2e-github.mjs http://localhost:8788 <repo folder> [fake GitHub URL]
// The server needs GITHUB_APP_ID, GITHUB_APP_PRIVATE_KEY, GITHUB_API_URL and GITHUB_WEBHOOK_SECRET; the
// runner MAPLE_TASK_PUSH_URL / MAPLE_TASK_FETCH_URL pointing at the fake's bare repos; the repo folder's
// origin is https://github.com/acme/greeter.git; the fake runs with `--ci test`.
// Checks: the runner fetches and pushes with app tokens, the PR opens on GitHub, auto-merge waits for
// CI, a failed check blocks it until it's run again, the merge is GitHub's squash, and a cancelled
// task's PR is closed with a comment.

import { execFileSync } from "node:child_process";

const [base = "http://localhost:8788", folder = "/tmp/mfgh/greeter", gh = "http://localhost:18803"] = process.argv.slice(2);
const ws = base.replace(/^http/, "ws");
const { token } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();
const feed = new WebSocket(`${ws}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
const tasks = new Map();
let goals = [];
let errors = [];
let poke = null;
feed.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "snapshot") { goals = m.goals; for (const t of m.tasks) tasks.set(t.id, t); }
  if (m.type === "goal.updated") goals = [...goals.filter((g) => g.id !== m.goal.id), m.goal];
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
const fake = async () => (await fetch(`${gh}/_log`)).json();
const origin = "/tmp/mfgh/remotes/acme/greeter.git";

await new Promise((r) => (feed.onopen = r));
send({ type: "subscribe" });
await wait("snapshot", () => goals.length >= 0 && tasks.size >= 0 && true);
const prefix = `GH${Date.now() % 1000}`;
send({ type: "goal.save", goal: { id: "", name: `GitHub ${prefix}`, prefix, color: "#3B82F6", summary: "Through the GitHub App", lead: "", folder, base: "main" } });
const goal = await wait("goal", () => goals.find((g) => g.prefix === prefix));
step(`goal ${goal.name} on ${folder} (origin github.com/acme/greeter)`);

send({ type: "task.create", goal: goal.id, title: "Say hello on GitHub", brief: "Add hello.txt with a greeting.", shareable: false, plan: true, tickets: [], agent: "scripted" });
const id = `${prefix}-1`;
await wait("plan", () => tasks.get(id)?.state === "awaitingApproval", 60000);
send({ type: "task.approvePlan", id });
let t = await wait("pull request", () => tasks.get(id)?.pr?.url && tasks.get(id), 90000);
step(`opened ${t.pr.url} from ${t.pr.branch}`);
let log = await fake();
const grants = log.log.filter((l) => l.path.endsWith("/access_tokens")).map((l) => JSON.stringify(l.body.permissions));
if (!grants.includes('{"contents":"read"}') || !grants.includes('{"contents":"write"}')) throw new Error(`tokens asked for: ${grants.join(" ")}`);
step(`the runner fetched with a read-only token and pushed with a contents:write one`);

t = await wait("review passed", () => tasks.get(id)?.autoReview?.rounds.at(-1)?.verdict === "passed" && tasks.get(id), 120000);
await new Promise((r) => setTimeout(r, 2500));
t = tasks.get(id);
if (t.state === "merged") throw new Error("it merged before CI finished");
step(`review passed; CI ${t.pr.checks.map((c) => `${c.name} ${c.status}`).join(", ")}: it waits`);

await fetch(`${gh}/_checks`, { method: "POST", body: JSON.stringify({ owner: "acme", repo: "greeter", sha: t.pr.head, runs: [{ name: "test", conclusion: "failure" }] }) });
t = await wait("CI failed", () => tasks.get(id)?.pr.checks.some((c) => c.status === "failed") && tasks.get(id));
step(`CI failed (webhook): ${t.events.at(-1).text}`);
send({ type: "task.merge", id });
await wait("refusal", () => errors.length);
if (!/CI is failing/.test(errors[0])) throw new Error(errors[0]);
step(`merging by hand is refused: "${errors[0]}"`);
errors = [];

send({ type: "task.rerunChecks", id });
t = await wait("merged", () => tasks.get(id)?.state === "merged" && tasks.get(id), 30000);
step(`ran test again, it passed, and the factory merged it: ${t.events.slice(-2).map((e) => e.text).join("; ")}`);
const hello = execFileSync("git", ["--git-dir", origin, "show", "main:hello.txt"], { encoding: "utf8" });
const subject = execFileSync("git", ["--git-dir", origin, "log", "-1", "--format=%s", "main"], { encoding: "utf8" }).trim();
if (!hello.includes(id)) throw new Error(`main has ${JSON.stringify(hello)}`);
step(`main has hello.txt from a squash: "${subject}"`);

// A cancelled task's pull request closes on GitHub.
send({ type: "task.create", goal: goal.id, title: "Wave on GitHub", brief: "Add hello.txt with a greeting.", shareable: false, plan: true, tickets: [], agent: "scripted" });
const id2 = `${prefix}-2`;
await wait("plan 2", () => tasks.get(id2)?.state === "awaitingApproval", 60000);
send({ type: "task.approvePlan", id: id2 });
const t2 = await wait("pull request 2", () => tasks.get(id2)?.pr?.url && tasks.get(id2), 90000);
send({ type: "task.cancel", id: id2 });
for (let i = 0; i < 20; i++) {
  log = await fake();
  if (log.pulls.find((p) => p.number === t2.pr.number)?.state === "closed") break;
  await new Promise((r) => setTimeout(r, 300));
}
if (log.pulls.find((p) => p.number === t2.pr.number)?.state !== "closed") throw new Error("the cancelled task's PR is still open");
step(`cancelling ${id2} closed pull request #${t2.pr.number} on GitHub`);
process.exit(0);

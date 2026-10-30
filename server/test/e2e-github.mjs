// The factory with its GitHub App, against the fake GitHub (test/fake-github.mjs):
//   node server/test/e2e-github.mjs http://localhost:8788 <repo folder> [fake GitHub URL]
// The server needs GITHUB_APP_ID, GITHUB_APP_PRIVATE_KEY, GITHUB_API_URL and GITHUB_WEBHOOK_SECRET; the
// runner MAPLE_TASK_PUSH_URL / MAPLE_TASK_FETCH_URL pointing at the fake's bare repos; the repo folder's
// origin is https://github.com/acme/greeter.git; the fake runs with `--ci test`.
// Checks: the runner fetches and pushes with app tokens, the PR opens on GitHub, auto-merge waits for
// CI, a failed check blocks it until it's run again, it counts down (a short MERGE_GRACE_MS) and the merge is GitHub's squash and deletes the
// task's branch on GitHub (but not one that moved after the merge), and a cancelled task's PR is
// closed with a comment. Each check links to its job on GitHub; `task.checkLog` reads a failed job's log
// (the failing step marked) for the asker alone, and `task.rerunCheck` asks GitHub for that one job again.

import { execFileSync } from "node:child_process";
import { dirname } from "node:path";

const [base = "http://localhost:8788", folder = "/tmp/mfgh/greeter", gh = "http://localhost:18803"] = process.argv.slice(2);
const ws = base.replace(/^http/, "ws");
const { token } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();
const feed = new WebSocket(`${ws}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
const tasks = new Map();
let goals = [];
let errors = [];
let errorIds = [];
let poke = null;
let checkLogs = [];
feed.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "snapshot") { goals = m.goals; for (const t of m.tasks) tasks.set(t.id, t); }
  if (m.type === "goal.updated") goals = [...goals.filter((g) => g.id !== m.goal.id), m.goal];
  if (m.type === "task.updated") tasks.set(m.task.id, m.task);
  if (m.type === "error") errors.push(m.message), errorIds.push(m.requestId ?? null);
  if (m.type === "checkLog") checkLogs.push(m);
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
const origin = `${dirname(folder)}/remotes/acme/greeter.git`;

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
const told = t.events.map((e) => e.text);
const countdown = told.findIndex((x) => x.startsWith("will auto-merge"));
if (countdown < 0 || countdown > told.findIndex((x) => x.startsWith("auto-merged"))) throw new Error(`no countdown before the merge: ${told.join(" / ")}`);
step(`ran test again, it passed, and the factory counted down and merged it: ${t.events.slice(countdown, countdown + 3).map((e) => e.text).join("; ")}`);
const hello = execFileSync("git", ["--git-dir", origin, "show", "main:hello.txt"], { encoding: "utf8" });
const subject = execFileSync("git", ["--git-dir", origin, "log", "-1", "--format=%s", "main"], { encoding: "utf8" }).trim();
if (!hello.includes(id)) throw new Error(`main has ${JSON.stringify(hello)}`);
step(`main has hello.txt from a squash: "${subject}"`);
const branchOnGitHub = (branch) => execFileSync("git", ["--git-dir", origin, "for-each-ref", "--format=%(refname)", `refs/heads/${branch}`], { encoding: "utf8" }).trim();
t = await wait("branch deleted", () => tasks.get(id)?.events.find((e) => /branch .* on GitHub/.test(e.text)) && tasks.get(id));
const deleted = t.events.find((e) => /branch .* on GitHub/.test(e.text)).text;
if (deleted !== `deleted branch ${t.pr.branch} on GitHub`) throw new Error(`after the merge: ${deleted}`);
if (branchOnGitHub(t.pr.branch)) throw new Error(`${t.pr.branch} is still on GitHub`);
step(`${deleted}, and the remote has no ${t.pr.branch} now`);

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
// Work that was already under way (a push, a review) mustn't bring it back.
await new Promise((r) => setTimeout(r, 15000));
if (tasks.get(id2).state !== "cancelled") throw new Error(`${id2} came back as ${tasks.get(id2).state} after it was cancelled`);
step(`${id2} stayed cancelled`);

// A branch someone pushes to after the merge stays on GitHub; the task is merged all the same.
send({ type: "task.create", goal: goal.id, title: "Wave again on GitHub", brief: "Add wave.txt with a greeting.", shareable: false, plan: true, tickets: [], agent: "scripted" });
const id3 = `${prefix}-3`;
await wait("plan 3", () => tasks.get(id3)?.state === "awaitingApproval", 60000);
send({ type: "task.approvePlan", id: id3 });
let t3 = await wait("pull request 3", () => tasks.get(id3)?.pr?.url && tasks.get(id3), 90000);
await fetch(`${gh}/_moveOnMerge`, { method: "POST", body: JSON.stringify({ owner: "acme", repo: "greeter", branch: t3.pr.branch }) });
t3 = await wait("review 3 passed", () => tasks.get(id3)?.autoReview?.rounds.at(-1)?.verdict === "passed" && tasks.get(id3), 120000);

// A failed check: its link, its log, and running that one job again.
await fetch(`${gh}/_checks`, { method: "POST", body: JSON.stringify({ owner: "acme", repo: "greeter", sha: t3.pr.head, runs: [{ name: "test", conclusion: "failure" }] }) });
t3 = await wait("CI 3 failed", () => tasks.get(id3)?.pr.checks.some((c) => c.status === "failed") && tasks.get(id3));
const failedCheck = t3.pr.checks.find((c) => c.name === "test");
if (!/^https:\/\/github\.com\/acme\/greeter\/actions\/runs\/\d+\/job\/\d+$/.test(failedCheck.url ?? "")) throw new Error(`test's url is ${failedCheck.url}`);
step(`the failed check links to its job: ${failedCheck.url}`);
send({ type: "task.checkLog", id: id3, check: "test" });
const got = await wait("check log", () => checkLogs.find((l) => l.id === id3));
if (got.check !== "test" || got.url !== failedCheck.url) throw new Error(`checkLog for ${got.check} at ${got.url}`);
if (got.failedStep !== "Process completed with exit code 1.") throw new Error(`failed step: ${got.failedStep}`);
if (!got.text.includes("not ok 1 - says hello") || /^\d{4}-\d\d-\d\dT/m.test(got.text) || got.text.startsWith("\uFEFF")) throw new Error(`log text: ${JSON.stringify(got.text.slice(0, 200))}`);
step(`task.checkLog read test's job log from the redirect, without the token (${got.text.split("\n").length} lines, timestamps stripped), failed step "${got.failedStep}"`);
send({ type: "task.checkLog", id: id3, check: "lint" });
await wait("no such check", () => errors.length).catch(() => {});
if (!/no check lint/.test(errors[0] ?? "")) throw new Error(`asking for a missing check's log: ${errors[0]}`);
// Tagged with the log it's about, so the apps show it there and not as some other command's refusal.
if (errorIds.at(-1) !== `checkLog:${id3}/lint`) throw new Error(`the refusal's requestId: ${errorIds.at(-1)}`);
errors = [];
step(`asking for a check that isn't there is refused (requestId checkLog:${id3}/lint)`);
const before3 = (await fake()).log.length;
send({ type: "task.rerunCheck", id: id3, check: "test" });
t3 = await wait("check queued", () => tasks.get(id3)?.pr.checks.find((c) => c.name === "test")?.status === "queued" && tasks.get(id3));
if (!t3.events.some((e) => e.text === "ran test again")) throw new Error(`events: ${t3.events.map((e) => e.text).join(" / ")}`);
const asked = (await fake()).log.slice(before3).filter((l) => l.method === "POST" && /rerun|rerequest/.test(l.path)).map((l) => l.path);
if (asked.length !== 1 || asked[0] !== `/repos/acme/greeter/actions/jobs/${failedCheck.url.split("/").at(-1)}/rerun`) throw new Error(`rerunCheck asked GitHub for: ${asked.join(", ")}`);
step(`task.rerunCheck re-ran only that job (${asked[0]}) and test is queued`);
t3 = await wait("kept branch", () => tasks.get(id3)?.events.find((e) => /branch .* on GitHub/.test(e.text)) && tasks.get(id3), 30000);
const kept = t3.events.find((e) => /branch .* on GitHub/.test(e.text)).text;
if (t3.state !== "merged" || kept !== `kept branch ${t3.pr.branch} on GitHub (it moved after the merge)`) throw new Error(`${id3} is ${t3.state}: ${kept}`);
if (!branchOnGitHub(t3.pr.branch)) throw new Error(`${t3.pr.branch} was deleted though it moved`);
step(`${id3} merged; ${kept}`);
process.exit(0);

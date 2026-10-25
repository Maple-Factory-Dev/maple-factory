// A goal across two repos, against the fake GitHub (test/fake-github.mjs, with --installed acme/api
// --installed acme/web and bare remotes for both, --ci test):
//   node server/test/e2e-repos.mjs http://localhost:8788 [fake GitHub URL]
// Checks: the org's repos come from the app's installations; a goal picks two of them; a task in the
// first plans a part for the second, which becomes its own task once the plan is approved, waits for
// the first to merge, then builds and merges its own pull request in the other repo.

import { execFileSync } from "node:child_process";

const [base = "http://localhost:8788", gh = "http://localhost:18803"] = process.argv.slice(2);
const { token } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();
const feed = new WebSocket(`${base.replace(/^http/, "ws")}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
const tasks = new Map();
let goals = [];
let repos = [];
let errors = [];
let poke = null;
feed.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "snapshot") { goals = m.goals; repos = m.repos; for (const t of m.tasks) tasks.set(t.id, t); }
  if (m.type === "goal.updated") goals = [...goals.filter((g) => g.id !== m.goal.id), m.goal];
  if (m.type === "task.updated") tasks.set(m.task.id, m.task);
  if (m.type === "repos.updated") repos = m.repos;
  if (m.type === "error") errors.push(m.message);
  poke?.();
};
const send = (m) => feed.send(JSON.stringify(m));
const wait = async (what, test, ms = 60000) => {
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
/** Finishes the PR's CI the way the fake's CI would, passing. */
const passCI = async (t) => {
  const [owner, repo] = t.pr.url.split("/").slice(3, 5);
  await fetch(`${gh}/_checks`, { method: "POST", body: JSON.stringify({ owner, repo, sha: t.pr.head, runs: [{ name: "test", conclusion: "success" }] }) });
};
const passed = (t) => t?.state === "reviewing" && t.autoReview?.rounds.at(-1)?.verdict === "passed" && t.pr?.head;

await new Promise((r) => (feed.onopen = r));
send({ type: "subscribe" });
await wait("snapshot", () => goals);
send({ type: "repos.refresh" });
await wait("repos", () => ["acme/api", "acme/web"].every((n) => repos.some((r) => r.name === n && r.source === "github")));
step(`the org's repos come from the app: ${repos.map((r) => r.name).join(", ")}`);

const prefix = `MR${Date.now() % 1000}`;
send({ type: "goal.save", goal: { id: "", name: `Multi ${prefix}`, prefix, color: "#14B8A6", summary: "Across api and web", lead: "", repo: "acme/api", repos: ["acme/api", "acme/web"], folder: null, base: "main" } });
const goal = await wait("goal", () => goals.find((g) => g.prefix === prefix));
step(`goal ${goal.name} spans ${goal.repos.join(" and ")}`);

send({ type: "task.create", goal: goal.id, title: "Greet from the API", brief: "[cross-repo] Add hello.txt with a greeting.", shareable: false, plan: true, tickets: [], agent: "scripted" });
const api = `${prefix}-1`;
let t = await wait("plan", () => tasks.get(api)?.state === "awaitingApproval" && tasks.get(api), 90000);
if (t.followUps.length !== 1 || t.followUps[0].repo !== "acme/web") throw new Error(`follow-ups: ${JSON.stringify(t.followUps)}`);
step(`${api}'s plan has a part for acme/web: "${t.followUps[0].title}"`);

send({ type: "task.approvePlan", id: api });
t = await wait("follow-up task", () => tasks.get(api)?.followUps[0].task && tasks.get(api));
const web = t.followUps[0].task;
const w = tasks.get(web);
if (w.repo !== "acme/web" || w.after.join() !== api) throw new Error(`${web}: repo ${w.repo}, after ${w.after}`);
step(`approving made ${web} in acme/web, after ${api}`);

await wait("web plan", () => tasks.get(web)?.state === "awaitingApproval", 90000);
send({ type: "task.approvePlan", id: web });
t = await wait("web waits", () => /Waiting for .* to merge first/.test(tasks.get(web)?.waiting ?? "") && tasks.get(web), 90000);
if (tasks.get(api).state === "merged") throw new Error(`${api} merged before ${web} was seen waiting`);
step(`${web} waits: "${t.waiting}"`);

t = await wait(`${api} review`, () => passed(tasks.get(api)) && tasks.get(api), 180000);
if (!t.pr.url.includes("/acme/api/")) throw new Error(`${api}'s PR is ${t.pr.url}`);
await passCI(t);
await wait(`${api} merged`, () => tasks.get(api)?.state === "merged", 30000);
step(`${api} merged (${t.pr.url})`);

t = await wait(`${web} review`, () => passed(tasks.get(web)) && tasks.get(web), 180000);
if (!t.pr.url.includes("/acme/web/")) throw new Error(`${web}'s PR is ${t.pr.url}`);
await passCI(t);
await wait(`${web} merged`, () => tasks.get(web)?.state === "merged", 30000);
const hello = execFileSync("git", ["--git-dir", "/tmp/mfgh/remotes/acme/web.git", "show", "main:hello.txt"], { encoding: "utf8" });
if (!hello.includes(web)) throw new Error(`acme/web main has ${JSON.stringify(hello)}`);
step(`then ${web} built and merged in acme/web (${t.pr.url}); its main has ${JSON.stringify(hello.trim().split("\n")[0])}`);
process.exit(0);

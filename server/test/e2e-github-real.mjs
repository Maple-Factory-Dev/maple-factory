// The factory against real GitHub, through a real GitHub App (server .dev.vars: GITHUB_APP_ID and
// GITHUB_APP_PRIVATE_KEY, no GITHUB_API_URL) and a runner with no MAPLE_TASK_* overrides:
//   node server/test/e2e-github-real.mjs http://localhost:8788 <owner/name of a public sandbox repo>
// It leaves a squash-merged hello.txt commit and a closed pull request in that repo. Webhooks can't
// reach localhost, so CI is whatever the factory reads when the PR opens.

const [base = "http://localhost:8788", repo] = process.argv.slice(2);
if (!repo) throw new Error("usage: e2e-github-real.mjs <server> <owner/name>");
const { token } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();
const feed = new WebSocket(`${base.replace(/^http/, "ws")}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
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
const wait = async (what, test, ms = 120000, id = null) => {
  const deadline = Date.now() + ms;
  for (;;) {
    const hit = test();
    if (hit) return hit;
    if (errors.length) throw new Error(`server said: ${errors.join("; ")}`);
    if (Date.now() > deadline) {
      const t = id && tasks.get(id);
      throw new Error(`timed out waiting for ${what}${t ? `\n${t.state} ${t.waiting ?? ""}\n${t.events.slice(-6).map((e) => `  ${e.who}: ${e.text}`).join("\n")}` : ""}`);
    }
    await new Promise((r) => { poke = r; setTimeout(r, 500); });
  }
};
const step = (text) => console.log(`✓ ${text}`);
const github = async (path) => (await fetch(`https://api.github.com/repos/${repo}${path}`, { headers: { "user-agent": "maple-factory-e2e", accept: "application/vnd.github+json" } })).json();

await new Promise((r) => (feed.onopen = r));
send({ type: "subscribe" });
await wait("snapshot", () => goals.length >= 0 && goals);
const prefix = `RG${Date.now() % 1000}`;
send({ type: "goal.save", goal: { id: "", name: `Real GitHub ${prefix}`, prefix, color: "#3B82F6", summary: `The factory on ${repo}`, lead: "", repo, repos: [repo], folder: null, base: null } });
const goal = await wait("goal", () => goals.find((g) => g.prefix === prefix));
step(`goal ${goal.name} on ${repo}`);

send({ type: "task.create", goal: goal.id, title: "Say hello on real GitHub", brief: "Add hello.txt with a greeting.", shareable: false, plan: true, tickets: [], agent: "scripted" });
const id = `${prefix}-1`;
await wait("plan", () => tasks.get(id)?.state === "awaitingApproval", 180000, id);
send({ type: "task.approvePlan", id });
let t = await wait("pull request", () => tasks.get(id)?.pr?.url && tasks.get(id), 240000, id);
step(`the runner pushed with an app token and the factory opened ${t.pr.url}`);
t = await wait("merged", () => tasks.get(id)?.state === "merged" && tasks.get(id), 300000, id);
const pr = await github(`/pulls/${t.pr.number}`);
if (!pr.merged) throw new Error(`GitHub says #${t.pr.number} isn't merged (${pr.state})`);
step(`reviewed and squash-merged on GitHub: ${pr.merge_commit_sha?.slice(0, 7)} "${pr.title}"`);

send({ type: "task.create", goal: goal.id, title: "Wave on real GitHub", brief: "Add hello.txt with a greeting.", shareable: false, plan: true, tickets: [], agent: "scripted" });
const id2 = `${prefix}-2`;
await wait("plan 2", () => tasks.get(id2)?.state === "awaitingApproval", 180000, id2);
send({ type: "task.approvePlan", id: id2 });
const t2 = await wait("pull request 2", () => tasks.get(id2)?.pr?.url && tasks.get(id2), 240000, id2);
send({ type: "task.cancel", id: id2 });
let state = "";
for (let i = 0; i < 30 && state !== "closed"; i++) {
  await new Promise((r) => setTimeout(r, 1000));
  state = (await github(`/pulls/${t2.pr.number}`)).state;
}
if (state !== "closed") throw new Error(`#${t2.pr.number} is still ${state} on GitHub`);
step(`cancelling ${id2} closed ${t2.pr.url}`);
// Work that was already under way (a push, a review) mustn't bring it back.
await new Promise((r) => setTimeout(r, 15000));
if (tasks.get(id2).state !== "cancelled") throw new Error(`${id2} came back as ${tasks.get(id2).state} after it was cancelled`);
step(`${id2} stayed cancelled`);
send({ type: "goal.archive", id: goal.id, archived: true });
await new Promise((r) => setTimeout(r, 500));
process.exit(0);

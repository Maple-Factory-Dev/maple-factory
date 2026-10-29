// Cancel and Retry in every unmerged state, with the GitHub App against the fake GitHub (set up as
// for test/e2e-github.mjs, `--ci test`):
//   node server/test/e2e-cancel.mjs http://localhost:8788 <repo folder> [fake GitHub URL]
// Checks: cancelling in planning, awaitingApproval, building and reviewing ends the session (and
// closes the pull request); Retry starts a new planner or builder in place of a running one, runs
// review again in reviewing, and brings a cancelled task back where it was, reopening its pull
// request (or building again, when GitHub won't reopen it); a merged task can't be retried or
// cancelled, queued or forced.

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
const pullState = async (number) => (await fake()).pulls.find((p) => p.number === number)?.state;
const refused = async (what, msg, pattern) => {
  send(msg);
  await new Promise((r) => setTimeout(r, 1500));
  const said = errors.shift();
  if (!said || !pattern.test(said)) throw new Error(`${what} wasn't refused (got ${JSON.stringify(said)})`);
  errors = [];
  return said;
};

await new Promise((r) => (feed.onopen = r));
send({ type: "subscribe" });
await wait("snapshot", () => goals.length >= 0 && tasks.size >= 0 && true);
const prefix = `CX${Date.now() % 1000}`;
send({ type: "goal.save", goal: { id: "", name: `Cancel ${prefix}`, prefix, color: "#3B82F6", summary: "Cancel and retry", lead: "", folder, base: "main" } });
const goal = await wait("goal", () => goals.find((g) => g.prefix === prefix));
step(`goal ${goal.name} on ${folder}`);
let n = 0;
const create = (title, brief) => {
  send({ type: "task.create", goal: goal.id, title, brief, shareable: false, plan: true, tickets: [], agent: "scripted" });
  return `${prefix}-${++n}`;
};
/** Cancels `id` and waits until it reads Cancelled with no session. */
const cancel = async (id) => {
  send({ type: "task.cancel", id });
  return wait(`${id} cancelled`, () => { const t = tasks.get(id); return t?.state === "cancelled" && !t.worker && t; });
};
/** Retries `id` and waits for a new `role` session (not `old`) in `state`. */
const retry = async (id, state, role, old) => {
  // A session that's only just starting hasn't said where its worktree is yet.
  if (old) await new Promise((r) => setTimeout(r, 4000));
  send({ type: "task.retry", id });
  return wait(`${id} retried into ${state}`, () => {
    const t = tasks.get(id);
    return t?.state === state && t.worker?.role === role && t.worker.session !== old && t;
  }, 60000);
};

// ---- planning ----
const a = create("Plan slowly", "Add hello.txt with a greeting. [slow]");
let t = await wait("planner", () => tasks.get(a)?.state === "planning" && tasks.get(a).worker && tasks.get(a), 60000);
const p1 = t.worker.session;
t = await retry(a, "planning", "planner", p1);
step(`${a}: Retry in planning ended planner ${p1.slice(0, 8)} and started ${t.worker.session.slice(0, 8)}`);
t = await cancel(a);
step(`${a}: cancelled in planning; its planner ended`);
t = await retry(a, "planning", "planner", null);
if (t.plan.length) throw new Error(`${a} came back with a plan`);
step(`${a}: Retry on the cancelled task started planning again`);
await cancel(a);

// ---- awaitingApproval and building ----
const b = create("Build slowly", "Add hello.txt with a greeting. [slow-build]");
await wait("plan", () => tasks.get(b)?.state === "awaitingApproval", 60000);
t = await cancel(b);
step(`${b}: cancelled awaiting approval`);
send({ type: "task.retry", id: b });
t = await wait(`${b} back`, () => tasks.get(b)?.state === "awaitingApproval" && tasks.get(b));
if (!t.plan.length || t.worker) throw new Error(`${b} came back without its plan, or running`);
step(`${b}: Retry brought it back awaiting approval of its plan (v${t.planVersion}), nothing running`);
step(`${b}: Retry while it awaits approval is refused: "${await refused("retry", { type: "task.retry", id: b }, /waiting for approval/)}"`);
send({ type: "task.approvePlan", id: b });
t = await wait("builder", () => tasks.get(b)?.state === "building" && tasks.get(b).worker && tasks.get(b), 60000);
const b1 = t.worker.session;
t = await retry(b, "building", "builder", b1);
step(`${b}: Retry in building ended builder ${b1.slice(0, 8)} and started ${t.worker.session.slice(0, 8)}`);
t = await cancel(b);
if (t.pr) throw new Error(`${b} has a pull request`);
step(`${b}: cancelled in building; its builder ended`);
t = await retry(b, "building", "builder", null);
step(`${b}: Retry on the cancelled task started building its approved plan again`);
await cancel(b);

// ---- reviewing ----
const c = create("Review slowly", "Add hello.txt with a greeting. [slow-review]");
await wait("plan", () => tasks.get(c)?.state === "awaitingApproval", 60000);
send({ type: "task.approvePlan", id: c });
t = await wait("reviewer", () => { const x = tasks.get(c); return x?.state === "reviewing" && x.pr?.url && x.worker?.role === "reviewer" && x; }, 120000);
const r1 = t.worker.session;
const rounds = t.autoReview.rounds.length;
step(`${c}: reviewing ${t.pr.url}, round ${rounds}`);
t = await retry(c, "reviewing", "reviewer", r1);
if (t.autoReview.rounds.length !== rounds || t.autoReview.rounds.at(-1).verdict !== "inProgress") throw new Error(`rounds: ${JSON.stringify(t.autoReview.rounds)}`);
step(`${c}: Retry in reviewing ended reviewer ${r1.slice(0, 8)} and ran round ${rounds} again with ${t.worker.session.slice(0, 8)}`);
const number = t.pr.number;
t = await cancel(c);
for (let i = 0; i < 20 && (await pullState(number)) !== "closed"; i++) await new Promise((r) => setTimeout(r, 300));
if ((await pullState(number)) !== "closed") throw new Error(`#${number} is still open`);
step(`${c}: cancelled in reviewing; its reviewer ended and pull request #${number} closed`);
t = await retry(c, "reviewing", "reviewer", null);
for (let i = 0; i < 20 && (await pullState(number)) !== "open"; i++) await new Promise((r) => setTimeout(r, 300));
if ((await pullState(number)) !== "open") throw new Error(`#${number} wasn't reopened`);
if (t.pr.state !== "open" || t.pr.number !== number) throw new Error(`task's PR: ${JSON.stringify(t.pr)}`);
const said = (await fake()).log.filter((l) => l.path.endsWith(`/issues/${number}/comments`)).map((l) => l.body.body);
if (!/picked .* back up/.test(said.at(-1) ?? "")) throw new Error(`comments on #${number}: ${JSON.stringify(said)}`);
step(`${c}: Retry reopened #${number} ("${said.at(-1)}") and started review round ${t.autoReview.rounds.length}`);
await cancel(c);
for (let i = 0; i < 20 && (await pullState(number)) !== "closed"; i++) await new Promise((r) => setTimeout(r, 300));
// Its branch deleted on GitHub: the pull request can't be reopened, so it builds again and opens a new one.
await fetch(`${gh}/_deleteBranch`, { method: "POST", body: JSON.stringify({ owner: "acme", repo: "greeter", branch: t.pr.branch }) });
send({ type: "task.retry", id: c });
t = await wait(`${c} building again`, () => { const x = tasks.get(c); return x?.state === "building" && x.worker?.role === "builder" && x; }, 60000);
if (t.pr) throw new Error(`${c} kept the pull request GitHub wouldn't reopen: ${JSON.stringify(t.pr)}`);
if ((await pullState(number)) !== "closed") throw new Error(`#${number} isn't closed`);
step(`${c}: GitHub wouldn't reopen #${number} (its branch was deleted), so Retry sent it back to building`);
t = await wait(`${c} new pull request`, () => { const x = tasks.get(c); return x?.state === "reviewing" && x.pr?.url && x.pr.number !== number && x; }, 120000);
if ((await pullState(t.pr.number)) !== "open") throw new Error(`#${t.pr.number} isn't open`);
step(`${c}: its builder pushed again and opened #${t.pr.number}`);
await cancel(c);

// ---- merged ----
const d = create("Merge it", "Add hello.txt with a greeting.");
await wait("plan", () => tasks.get(d)?.state === "awaitingApproval", 60000);
send({ type: "task.approvePlan", id: d });
t = await wait("review passed", () => tasks.get(d)?.autoReview?.rounds.at(-1)?.verdict === "passed" && tasks.get(d).pr?.head && tasks.get(d), 180000);
await fetch(`${gh}/_checks`, { method: "POST", body: JSON.stringify({ owner: "acme", repo: "greeter", sha: t.pr.head, runs: [{ name: "test", conclusion: "success" }] }) });
await wait("merged", () => tasks.get(d)?.state === "merged", 60000);
step(`${d}: merged`);
step(`${d}: Retry is refused: "${await refused("retry", { type: "task.retry", id: d }, /merged/)}"`);
step(`${d}: Cancel is refused: "${await refused("cancel", { type: "task.cancel", id: d }, /finished/)}"`);
step(`${d}: Queueing it is refused: "${await refused("queue", { type: "task.queue", id: d, before: "top" }, /finished/)}"`);
step(`${d}: Forcing it is refused: "${await refused("force", { type: "task.queue", id: d, force: true }, /finished/)}"`);

// ---- archived ----
send({ type: "goal.archive", id: goal.id, archived: true });
await wait("archived", () => goals.find((g) => g.id === goal.id)?.archived);
step(`${a}: Retry in an archived goal is refused: "${await refused("retry", { type: "task.retry", id: a }, /archived/)}"`);
process.exit(0);

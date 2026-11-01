// A policy that needs 0 plan approvals and 0 final reviews at every risk level: a planned task goes
// from planning straight to building with nobody's task.approvePlan, its events say "queued it for
// building (its risk level needs no plan approval)", and in review it waits on no person's review.
// The policy is put back after.
//   node server/test/e2e-no-approvals.mjs http://localhost:8788 <repo folder>
// Needs a real runner whose agents.toml has the `scripted` agent (test/scripted-agent.mjs), and a
// local repo whose origin is a bare repo.

const [base = "http://localhost:8788", folder] = process.argv.slice(2);
if (!folder) throw new Error("usage: e2e-no-approvals.mjs <server> <repo folder>");
const ws = base.replace(/^http/, "ws");
const { token } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();
const feed = new WebSocket(`${ws}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
const tasks = new Map();
let goals = null;
let policy = null;
const errors = [];
let poke = null;
/** Every state each task was seen in, in order. */
const seen = new Map();
feed.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "snapshot") { goals = m.goals; policy = m.policy; for (const t of m.tasks) tasks.set(t.id, t); }
  if (m.type === "task.updated") {
    tasks.set(m.task.id, m.task);
    const states = seen.get(m.task.id) ?? [];
    if (states.at(-1) !== m.task.state) states.push(m.task.state);
    seen.set(m.task.id, states);
  }
  if (m.type === "goal.updated") goals = [...goals.filter((g) => g.id !== m.goal.id), m.goal];
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
    await new Promise((r) => { poke = r; setTimeout(r, 250); });
  }
};
const step = (text) => console.log(`✓ ${text}`);
const check = (ok, why) => { if (!ok) throw new Error(why); };

await new Promise((r) => (feed.onopen = r));
send({ type: "subscribe" });
await wait("snapshot", () => goals && policy);
const original = policy;
const none = { low: 0, medium: 0, high: 0 };
send({ type: "policy.save", policy: { ...policy, planApprovals: none, finalReviews: none, autoMerge: { low: false, medium: false, high: false } } });
await wait("policy saved", () => Object.values(policy.planApprovals).every((n) => n === 0) && Object.values(policy.finalReviews).every((n) => n === 0));
step(`policy: plan approvals ${JSON.stringify(policy.planApprovals)}, final reviews ${JSON.stringify(policy.finalReviews)}`);

try {
  const prefix = `NA${Date.now() % 100000}`.slice(0, 7);
  send({ type: "goal.save", goal: { id: "", name: `No approvals ${prefix}`, prefix, color: "#8B949E", summary: "0 approvals test", lead: "", folder, base: "main" } });
  const goal = await wait("goal", () => goals.find((g) => g.prefix === prefix));
  step(`goal ${goal.name}`);

  // "[risky]": the scripted planner rates it high, so even high risk builds without approval.
  for (const [n, brief, level] of [[1, "Add hello.txt with a greeting.", "low"], [2, "Add risky.txt. [risky]", "high"]]) {
    const id = `${prefix}-${n}`;
    send({ type: "task.create", goal: goal.id, title: `Say hello ${n}`, brief, shareable: false, plan: true, tickets: [], agent: "scripted" });
    let t = await wait(`${id} builder`, () => tasks.get(id)?.worker?.role === "builder" && tasks.get(id), 90000);
    check(t.risk?.level === level, `${id}: risk ${t.risk?.level}, expected ${level}`);
    check(t.approvalsNeeded === 0 && t.approvals.length === 0, `${id}: ${t.approvals.length} of ${t.approvalsNeeded} approvals`);
    check(!seen.get(id).includes("awaitingApproval"), `${id} waited for approval: ${seen.get(id).join(" → ")}`);
    const queued = t.events.find((e) => e.text === "queued it for building (its risk level needs no plan approval)");
    check(queued?.who === "factory", `${id}: no "queued it for building" event: ${t.events.map((e) => e.text).join(" / ")}`);
    check(!t.events.some((e) => e.text === "approved the plan"), `${id}: someone approved the plan`);
    step(`${id} (${level} risk): ${seen.get(id).join(" → ")}, ${t.approvals.length} of ${t.approvalsNeeded} approvals, event "${queued.text}"`);

    t = await wait(`${id} reviewed`, () => {
      const x = tasks.get(id);
      return x && (x.state === "merged" || (x.state === "reviewing" && x.autoReview?.rounds.at(-1)?.verdict === "passed" && !x.worker)) && x;
    }, 240000);
    check(t.reviewsNeeded === 0, `${id}: needs ${t.reviewsNeeded} reviews`);
    step(`${id}: built and reviewed → ${t.state}, ${t.reviewsNeeded} human reviews needed${t.waiting ? `, waiting: ${JSON.stringify(t.waiting)}` : ""}`);
    console.log(t.events.map((e) => `    ${e.who}: ${e.text.split("\n")[0]}`).join("\n"));
  }
} finally {
  send({ type: "policy.save", policy: original });
  await wait("policy restored", () => JSON.stringify(policy.planApprovals) === JSON.stringify(original.planApprovals));
  step("policy restored");
}
feed.close();
process.exit(0);

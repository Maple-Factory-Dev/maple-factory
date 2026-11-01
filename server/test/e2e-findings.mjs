// Research tasks (MF-317), with this script as the runner:
//   node server/test/e2e-findings.mjs http://localhost:8788
// Enrolls a runner, makes a goal and a question-shaped task, and in the planner's session does what a
// planner answering a research question does: uploads report.md, shares it with share_artifact, then
// calls submit_findings with the short answer, the report's title and two ordered follow-ups.
// Checks: the task closes with its findings (answer, the report's artifact id, the follow-up drafts in
// order, `after` honoured), and an unknown report title is refused first. The task is left closed with
// its findings, to look at in the web app (#/t/<id>).

const [base = "http://localhost:8788"] = process.argv.slice(2);
const ws = base.replace(/^http/, "ws");
let failures = 0;
const check = (ok, what) => { console.log(`${ok ? "ok  " : "FAIL"} ${what}`); if (!ok) failures++; };

const { token } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();
const member = { authorization: `Bearer ${token}` };

const { code } = await (await fetch(`${base}/api/machines/enroll`, { method: "POST", headers: member })).json();
const runnerId = `findings-${Date.now().toString(36)}`;
const enrolled = await (await fetch(`${base}/runner/enroll`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ code, runnerId, hostname: runnerId, os: "macos", arch: "arm64", version: "0.0.0-fake" }),
})).json();
const runner = new WebSocket(`${ws}/runner/connect?runner=${runnerId}`, { headers: { authorization: `Bearer ${enrolled.token}` } });
await new Promise((r, j) => { runner.onopen = r; runner.onerror = j; });
const sessions = [];
const replies = new Map();
runner.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "ping") runner.send(JSON.stringify({ type: "pong" }));
  if (m.type === "session.open") sessions.push(m);
  if (m.type === "mcp.response") replies.get(m.reqId)?.(m);
};
runner.send(JSON.stringify({ type: "hello", runnerId, hostname: runnerId, os: "macos", arch: "arm64", version: "0.0.0-fake", sessions: [], ended: [] }));
const call = (session, tool, args) => new Promise((resolve) => {
  const reqId = crypto.randomUUID();
  replies.set(reqId, resolve);
  runner.send(JSON.stringify({ type: "mcp.request", reqId, session, tool, args }));
});
const putArtifact = (task, name, body, type) =>
  fetch(`${base}/runner/artifact/${task}?runner=${runnerId}&name=${encodeURIComponent(name)}`, { method: "PUT", headers: { "content-type": type, authorization: `Bearer ${enrolled.token}` }, body });

const feed = new WebSocket(`${ws}/client/connect`, { headers: member });
const tasks = new Map();
let goals = [];
let poke = null;
feed.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "snapshot") { goals = m.goals; for (const t of m.tasks) tasks.set(t.id, t); }
  if (m.type === "goal.updated") goals = [...goals.filter((g) => g.id !== m.goal.id), m.goal];
  if (m.type === "task.updated") tasks.set(m.task.id, m.task);
  if (m.type === "error") console.log(`server said: ${m.message}`);
  poke?.();
};
const send = (m) => feed.send(JSON.stringify(m));
const wait = async (what, test, ms = 20000) => {
  const deadline = Date.now() + ms;
  for (;;) {
    const hit = test();
    if (hit) return hit;
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((r) => { poke = r; setTimeout(r, 200); });
  }
};
await new Promise((r) => (feed.onopen = r));
send({ type: "subscribe" });

const prefix = `RS${Date.now() % 1000}`;
send({ type: "goal.save", goal: { id: "", name: `Research ${prefix}`, prefix, color: "#7C5CE0", summary: "Questions about the codebase", lead: "", folder: "/tmp/mf-research", base: "main" } });
const goal = await wait("goal", () => goals.find((g) => g.prefix === prefix));
send({ type: "task.create", goal: goal.id, title: "How does the merge queue decide what merges next?", brief: "How does the merge queue decide what merges next, and how could we let a P0 jump it?", shareable: false, plan: true, tickets: [], agent: "scripted" });
const id = `${prefix}-1`;
const planner = await wait("planner", () => sessions.find((s) => s.taskId === id));

const report = `# How the merge queue picks what merges next

## Today
The engine keeps every approved task's place in \`queueRank\`; lower starts first. A task's rank is its
\`createdAt\` unless someone moved it ("Move to top" sets it below the current first).

## Letting a P0 jump it
A P0 that enters the queue already goes to its front (\`priority\` on Task). For merges, the same rank could
order the auto-merge countdowns, so a P0 in review merges before older P2s.

## Follow-ups
1. Order auto-merge by queueRank.
2. Show the merge order on the Tasks page.
`;
const up = await (await putArtifact(id, "report.md", Buffer.from(report), "text/markdown")).json();
const shared = await call(planner.id, "share_artifact", { title: "Research report", file: up, summary: "The full write-up." });
check(!shared.error, `the planner shares the report (${shared.error ?? "ok"})`);

const unknown = await call(planner.id, "submit_findings", { answer: "x", report: "Not shared" });
check(/isn't one of this task's artifacts/.test(unknown.error ?? ""), `an unknown report title is refused (${unknown.error})`);

const answered = await call(planner.id, "submit_findings", {
  answer: "Approved tasks wait in **`queueRank`** order (lower first), and a P0 already jumps to the front of that queue.\n\nMerges don't use it yet: each task in review auto-merges on its own countdown. Ordering the countdowns by the same rank would let a P0 merge first. See the full report for where that lives in `engine.ts`.",
  report: "Research report",
  followUps: [
    { title: "Order auto-merges by queueRank", brief: "Let a P0 in review merge before older tasks.", effort: "Merge order" },
    { title: "Show the merge order on the Tasks page", brief: "List what merges next.", after: ["#1"], effort: "Merge order" },
  ],
});
check(!answered.error, `the planner submits its findings (${answered.error ?? "ok"})`);
const t = await wait("closed", () => tasks.get(id)?.state === "closed" && tasks.get(id).findings && tasks.get(id));
const art = t.artifacts.find((a) => a.title === "Research report");
check(t.findings.report === art?.id, "the findings link the report artifact");
check(t.findings.followUps.length === 2, `two follow-up drafts (${t.findings.followUps.join(", ")})`);
const [a, b] = t.findings.followUps.map((x) => tasks.get(x));
check(a?.state === "drafting" && b?.state === "drafting", "the follow-ups are drafts");
check(JSON.stringify(b?.after) === JSON.stringify([a?.id]), "the second waits on the first");

console.log(`\n${base}/app/#/t/${id}`);
console.log(failures ? `${failures} FAILED` : "all ok");
process.exit(failures ? 1 : 0);

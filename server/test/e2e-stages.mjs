// Stage spans (MF-302), against a local server: a fake runner plays planner, builder (who raises a
// hand that a person answers) and reviewer, and a person approves and merges. Prints the task's
// `stages` from GET /api/tasks/<id> and checks there's one span per phase, in order, end to end.
//   node server/test/e2e-stages.mjs http://localhost:8788

const [base = "http://localhost:8788"] = process.argv.slice(2);
const ws = base.replace(/^http/, "ws");
const step = (t) => console.log(`✓ ${t}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const post = (path, body, headers = {}) => fetch(`${base}${path}`, { method: "POST", headers: { "content-type": "application/json", ...headers }, body: JSON.stringify(body) });
const errors = [];
async function until(what, ok, ms = 20_000) {
  for (const end = Date.now() + ms; Date.now() < end; await sleep(100)) {
    if (errors.length) throw new Error(`server said: ${errors.splice(0).join("; ")}`);
    const hit = ok();
    if (hit) return hit;
  }
  throw new Error(`timed out waiting for ${what}`);
}

const { token } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();
const auth = { authorization: `Bearer ${token}` };
const feed = new WebSocket(`${ws}/client/connect`, { headers: auth });
const tasks = new Map();
let goals = [];
let snapshot = false;
feed.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "snapshot") { goals = m.goals; snapshot = true; for (const t of m.tasks) tasks.set(t.id, t); }
  if (m.type === "goal.updated") goals = [...goals.filter((g) => g.id !== m.goal.id), m.goal];
  if (m.type === "task.updated") tasks.set(m.task.id, m.task);
  if (m.type === "error") errors.push(m.message);
};
await new Promise((r) => (feed.onopen = r));
const send = (m) => feed.send(JSON.stringify(m));
send({ type: "subscribe" });
await until("the snapshot", () => snapshot);

// The fake machine.
const runnerId = `stages-mac-${Date.now()}`;
const { code } = await (await post("/api/machines/enroll", {}, auth)).json();
const enrolled = await (await post("/runner/enroll", { code, runnerId, hostname: runnerId, os: "macos", arch: "arm64", version: "0.0.0-fake" })).json();
const runner = new WebSocket(`${ws}/runner/connect?runner=${runnerId}`, { headers: { authorization: `Bearer ${enrolled.token}` } });
await new Promise((r, j) => { runner.onopen = r; runner.onerror = j; });
const toHub = (m) => runner.send(JSON.stringify(m));
toHub({ type: "hello", runnerId, hostname: runnerId, os: "macos", arch: "arm64", version: "0.0.0-fake", sessions: [], ended: [] });
toHub({ type: "health", health: { cpu: 1, cores: 16, load1: 0.1, memUsed: 1e9, memTotal: 32e9, diskUsed: 1e11, diskTotal: 1e12, uptime: 10, battery: null, agents: [{ name: "claude", version: "2.1.0", loggedIn: true }] } });

const replies = new Map();
const call = (session, tool, args = {}) => new Promise((resolve, reject) => {
  const reqId = crypto.randomUUID();
  replies.set(reqId, (m) => (m.error ? reject(new Error(`${tool}: ${m.error}`)) : resolve(m.result)));
  toHub({ type: "mcp.request", reqId, session, tool, args });
});
const ended = (id) => toHub({ type: "session.ended", end: { id, cause: "exited", code: 0, signal: null, detail: null, at: Date.now(), lastOutput: [], by: null } });
const PAUSE = 1500; // so each phase lasts long enough to read
const prefix = `ST${String(Date.now()).slice(-4)}`;
let builderSession = null;

runner.onmessage = async (e) => {
  if (typeof e.data !== "string") return; // terminal input (the hand's answer typed in)
  const m = JSON.parse(e.data);
  if (m.type === "ping") return toHub({ type: "pong" });
  if (m.type === "mcp.response") return replies.get(m.reqId)?.(m);
  if (m.type === "session.kill") return ended(m.id);
  if (m.type === "task.finish") return toHub({ type: "task.finished", taskId: m.taskId, ok: true, branch: m.branch, base: m.base ?? "main", commit: "abc1234def" });
  if (m.type === "task.diff") return toHub({ type: "task.diff", taskId: m.taskId, ok: true, files: [{ path: "hello.txt", added: 1, removed: 0 }], patch: "+hello\n", truncated: false });
  if (m.type === "task.merge_check") return toHub({ type: "task.merge_check", taskId: m.taskId, ok: true, clean: true, conflicts: [] });
  if (m.type === "task.merge") return toHub({ type: "task.merged", taskId: m.taskId, ok: true, commit: "fedcba98" });
  if (m.type !== "session.open" || !m.taskId?.startsWith(`${prefix}-`)) return;
  toHub({ type: "task.started", taskId: m.taskId, repo: null, repoDir: "/tmp/stages-e2e/repo", base: "main", project: null });
  toHub({ type: "session.opened", session: { id: m.id, agent: m.agent, cwd: `/tmp/stages-e2e/${m.taskId}`, pid: 1, startedAt: Date.now(), taskId: m.taskId } });
  await sleep(PAUSE);
  try {
    if (/You are the planner/.test(m.prompt)) {
      await call(m.id, "submit_plan", {
        summary: "Add a greeting file.",
        steps: [{ text: "Write hello.txt", file: "hello.txt" }],
        doneWhen: [{ text: "hello.txt says hello", proof: "terminal" }],
        risk: { level: "low", reasons: ["One new text file."], areas: [] },
        footprint: { files: 1, lines: 1 },
        mockups: [],
      });
    } else if (/You are the builder/.test(m.prompt)) {
      builderSession = m.id;
      await call(m.id, "raise_hand", { reason: "needsInput", summary: "File or README?", options: [{ title: "A new file", detail: "hello.txt", recommended: true }, { title: "The README", detail: "README.md" }] });
    } else if (/You are the review/.test(m.prompt)) {
      await call(m.id, "submit_review", { verdict: "passed", summary: "Good to go.", ask: [{ text: "Add a greeting file", verdict: "met" }], proofs: [{ text: "hello.txt says hello", verdict: "met" }], findings: [], fixed: [] });
    }
  } catch (err) { errors.push(String(err)); }
};
await sleep(500);

send({ type: "goal.save", goal: { id: "", name: `Stages ${prefix}`, prefix, color: "#6B7280", summary: "Time breakdown e2e.", lead: "", repos: [], folder: "/tmp/stages-e2e/repo", base: null } });
const goal = await until("the goal", () => goals.find((g) => g.prefix === prefix));
send({ type: "task.create", goal: goal.id, title: "Add a greeting file", brief: "Add hello.txt with a greeting.", shareable: false, plan: true, tickets: [], agent: "claude" });
const id = (await until("the task", () => [...tasks.values()].find((t) => t.goal === goal.id))).id;
step(`${id} created`);
await until("awaiting approval", () => tasks.get(id).state === "awaitingApproval");
step("plan written: awaiting approval");
await sleep(PAUSE);
send({ type: "task.approvePlan", id });
await until("the hand", () => tasks.get(id).hand);
step("building: the builder raised a hand");
await sleep(PAUSE);
send({ type: "task.resolveHand", id, option: "A new file", note: "Go with hello.txt" });
await until("the hand down", () => !tasks.get(id).hand);
step("hand answered");
await sleep(PAUSE);
await call(builderSession, "prove", { item: 1, kind: "terminal", summary: "hello.txt has the greeting", command: "cat hello.txt", output: ["hello"] });
await call(builderSession, "finish", { summary: "Added hello.txt." });
await until("reviewing", () => tasks.get(id).state === "reviewing", 30_000);
step("finished: reviewing");
await until("the review passed", () => tasks.get(id).autoReview?.rounds?.some((r) => r.verdict === "passed"), 30_000);
await sleep(PAUSE);
if (tasks.get(id).state !== "merged") {
  send({ type: "task.approveChanges", id });
  await sleep(300);
  send({ type: "task.merge", id });
}
await until("merged", () => tasks.get(id).state === "merged", 30_000);
step("merged");

const res = await fetch(`${base}/api/tasks/${id}`, { headers: auth });
const task = await res.json();
console.log(`\nGET /api/tasks/${id} → ${res.status}, stages:`);
const t0 = task.createdAt;
for (const s of task.stages) {
  console.log(`  ${s.stage.padEnd(16)} ${(s.wait ?? "").padEnd(8)} from +${((s.from - t0) / 1000).toFixed(1)}s  to ${s.to == null ? "open" : `+${((s.to - t0) / 1000).toFixed(1)}s`}  (${s.to == null ? "…" : `${((s.to - s.from) / 1000).toFixed(1)}s`})`);
}
const phases = task.stages.map((s) => s.stage + (s.wait ? `+${s.wait}` : ""));
const want = ["planning", "awaitingApproval", "building", "building+hand", "building", "reviewing", "merged"];
const seq = phases.filter((p, i) => want.includes(p) && (i === 0 || p !== phases[i - 1]));
for (const w of want) if (!phases.includes(w)) throw new Error(`no ${w} span in ${phases.join(" → ")}`);
for (let i = 1; i < task.stages.length; i++) {
  if (task.stages[i].from !== task.stages[i - 1].to) throw new Error(`span ${i} starts at ${task.stages[i].from}, not where ${i - 1} ended (${task.stages[i - 1].to})`);
}
console.log(`\nphases: ${seq.join(" → ")}; each span starts where the last ended`);
console.log(`TASK=${id}`);
console.log("e2e-stages passed");
process.exit(0);

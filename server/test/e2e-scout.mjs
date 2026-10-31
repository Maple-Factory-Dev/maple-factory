// Scout, against a local server with no other machines: a fake runner plays a task's planner,
// builder and reviewer over the wire (`mcp.request`, the same `maple` tools a real agent calls) so
// the task merges with two minor findings left open, and a third task is parked in the backlog. Then
// `goal.scout` sends the runner a `draft.run` under a `scout-` id; it picks every leftover it was
// shown, and the factory trims them to the policy's scoutItems (2 here), makes them tasks in the goal
// and sends them to planning, each with `scoutedFrom`, while `scout.updated` goes running → done.
// It does that for two folder goals: a plain folder, and one whose origin is on GitHub (acme/greeter),
// where the run asks for a read-only token to fetch it, as the runner does, and must get one (or,
// with no GitHub App on the server, be told there's none: never refused for not being the goal's).
//   node server/test/e2e-scout.mjs http://localhost:8788
//   node server/test/e2e-scout.mjs http://localhost:8788 serve 120 ["Goal name"]   # set up, then answer the app's Scout runs (slowly) for 120s
// Run the server with a short MERGE_GRACE_MS (scripts/dev-stack.sh does, with MERGE_GRACE_MS=1500).

const [base = "http://localhost:8788", mode = "test", serveSecs = "120", serveName = "Greeting page"] = process.argv.slice(2);
const ws = base.replace(/^http/, "ws");
const step = (t) => console.log(`✓ ${t}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const post = (path, body, headers = {}) => fetch(`${base}${path}`, { method: "POST", headers: { "content-type": "application/json", ...headers }, body: JSON.stringify(body) });
async function until(what, ok, ms = 20_000) {
  for (const end = Date.now() + ms; Date.now() < end; await sleep(100)) if (ok()) return;
  throw new Error(`timed out waiting for ${what}`);
}

const { token } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();
const feed = new WebSocket(`${ws}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
const tasks = new Map();
const runs = [];
let goals = [];
let policy = null;
const errors = [];
feed.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "snapshot") { goals = m.goals; policy = m.policy; for (const t of m.tasks) tasks.set(t.id, t); }
  if (m.type === "goal.updated") goals = [...goals.filter((g) => g.id !== m.goal.id), m.goal];
  if (m.type === "task.updated") tasks.set(m.task.id, m.task);
  if (m.type === "policy.updated") policy = m.policy;
  if (m.type === "scout.updated") runs.push(m.run);
  if (m.type === "error") errors.push(m.message);
};
await new Promise((r) => (feed.onopen = r));
/** The snapshot a newly connected app gets. */
async function snapshotOf() {
  const other = new WebSocket(`${ws}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
  const got = await new Promise((resolve, reject) => {
    other.onmessage = (e) => { const m = JSON.parse(e.data); if (m.type === "snapshot") resolve(m); };
    other.onerror = reject;
    other.onopen = () => other.send(JSON.stringify({ type: "subscribe" }));
  });
  other.close();
  return got;
}
const send = (m) => feed.send(JSON.stringify(m));
send({ type: "subscribe" });
await until("the snapshot", () => policy);

// The fake machine: the only one, so every session and the Scout run come to it.
const runnerId = `scout-mac-${Date.now()}`;
const { code } = await (await post("/api/machines/enroll", {}, { authorization: `Bearer ${token}` })).json();
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
let draftRun = null;
let tokenReply = null;
const tokenReplies = new Map();
const askToken = (taskId, purpose) => new Promise((resolve) => {
  const reqId = crypto.randomUUID();
  tokenReplies.set(reqId, resolve);
  toHub({ type: "task.token_request", reqId, taskId, owner: "acme", repo: "greeter", purpose });
});
// The task that plays the loop out; sessions for any other (an earlier run's) just open.
let first = null;
const roles = {
  async planner(s) {
    await call(s, "submit_plan", {
      summary: "Add a greeting file.", steps: [{ text: "Write hello.txt", file: "hello.txt" }],
      doneWhen: [{ text: "hello.txt says hello", proof: "terminal" }],
      risk: { level: "low", reasons: ["One new text file."], areas: [] }, footprint: { files: 1, lines: 1 }, otherRepos: [], mockups: [],
    });
  },
  async builder(s) {
    await call(s, "prove", { item: 1, kind: "terminal", summary: "It says hello", command: "cat hello.txt", output: ["hello"] });
    await call(s, "finish", { summary: "Added hello.txt." });
  },
  async reviewer(s) {
    await call(s, "submit_review", {
      verdict: "passed", summary: "Good, with two small things for later.",
      ask: [{ text: "Add a greeting file", verdict: "met" }], proofs: [{ text: "hello.txt says hello", verdict: "met" }],
      findings: [
        { kind: "code", severity: "minor", text: "hello.txt has no trailing newline.", file: "hello.txt:1" },
        { kind: "code", severity: "minor", text: "The greeting isn't capitalised.", file: "hello.txt:1" },
      ],
      fixed: [],
    });
  },
};
runner.onmessage = async (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "ping") return toHub({ type: "pong" });
  if (m.type === "mcp.response") return replies.get(m.reqId)?.(m);
  if (m.type === "task.token") return tokenReplies.get(m.reqId)?.(m);
  if (m.type === "session.open" && m.taskId) {
    const cwd = `/tmp/scout-e2e/${m.taskId}`;
    toHub({ type: "task.started", taskId: m.taskId, repo: null, repoDir: "/tmp/scout-e2e/repo", base: "main", project: null });
    toHub({ type: "session.opened", session: { id: m.id, agent: m.agent, cwd, pid: 1, startedAt: Date.now(), taskId: m.taskId } });
    const role = /You are the planner/.test(m.prompt) ? "planner" : /You are the builder/.test(m.prompt) ? "builder" : "reviewer";
    await sleep(200);
    // Only the first task plays its roles out; Scout's tasks just need to reach planning.
    if (m.taskId === first) roles[role](m.id).catch((err) => errors.push(String(err)));
    return;
  }
  if (m.type === "task.finish") return toHub({ type: "task.finished", taskId: m.taskId, ok: true, pushed: "fallback", owner: null, repo: null, branch: m.branch, base: "main", commit: "abc1234def", reason: null, message: null });
  if (m.type === "task.merge_check") return toHub({ type: "task.merge_check", taskId: m.taskId, ok: true, clean: true, conflicts: [], message: null });
  if (m.type === "task.merge") return toHub({ type: "task.merged", taskId: m.taskId, ok: true, commit: "fedcba9", message: null });
  if (m.type === "draft.run") {
    draftRun = m;
    // A folder whose origin is on GitHub: fetch it with a read-only token first, as the runner does.
    if (m.folder === GITHUB_FOLDER) tokenReply = { fetch: await askToken(m.id, "fetch"), push: await askToken(m.id, "push") };
    // Every leftover it was shown, and more than the cap.
    const shown = [...m.prompt.matchAll(/^- from (\S+) .*\n  (.*)$/gm)].map((x) => ({ from: x[1], text: x[2].replace(/^\w+ \w+ in \S+: /, "") }));
    const items = shown.map((c) => ({ from: c.from, title: c.from.includes("#") ? `Fix: ${c.text.replace(/\.$/, "")}`.slice(0, 70) : c.text.slice(0, 70), brief: `Still real: ${c.text}`, doneWhen: ["A test shows it's fixed"] }));
    await sleep(mode === "serve" ? 8_000 : 500);
    toHub({ type: "draft.done", id: m.id, output: `Checked them.\n${JSON.stringify({ items })}`, error: null });
  }
};
await sleep(500);

const GITHUB_FOLDER = "/tmp/scout-e2e/greeter";

/** Scout on a goal set to `folder`, start to finish. */
async function scenario(folder) {
  first = null;
  draftRun = null;
  // A goal with a folder (no repos): a plain one, or one whose origin is on GitHub.
  const prefix = `SC${String(Date.now()).slice(-4)}`;
  send({ type: "goal.save", goal: { id: "", name: mode === "serve" ? serveName : `Scout ${prefix}`, prefix, color: "#2EA043", summary: "A friendly greeting, and the leftovers its reviews left behind.", lead: "", repos: [], folder, base: null } });
  await until("the goal", () => goals.some((g) => g.prefix === prefix));
  const goal = goals.find((g) => g.prefix === prefix);
  send({ type: "policy.save", policy: { ...policy, scoutItems: 2 } });
  await until("scoutItems 2", () => policy.scoutItems === 2);
  step(`goal ${goal.name} on ${folder}; the policy's scoutItems is ${policy.scoutItems}`);

  const inGoal = () => [...tasks.values()].filter((t) => t.goal === goal.id);
  send({ type: "task.create", goal: goal.id, title: "Add a greeting", brief: "Add hello.txt.", shareable: false, plan: true, tickets: [], agent: "claude" });
  await until("the task", () => (first = inGoal()[0]?.id));
  await until("its plan", () => tasks.get(first).state === "awaitingApproval");
  send({ type: "task.approvePlan", id: first });
  await until(`${first} to merge`, () => tasks.get(first).state === "merged", 30_000);
  const left = tasks.get(first).autoReview.findings.filter((f) => f.status === "open");
  step(`${first} merged with ${left.length} findings left open: ${left.map((f) => `${f.id} (${f.severity})`).join(", ")}`);

  send({ type: "task.create", goal: goal.id, title: "Parked idea", brief: "Later.", shareable: false, plan: false, tickets: [], agent: "claude" });
  await until("the parked task", () => inGoal().length === 2);
  const parked = inGoal().find((t) => t.id !== first).id;
  send({ type: "task.backlog", id: parked });
  await until(`${parked} in the backlog`, () => tasks.get(parked).state === "backlog");
  step(`${parked} parked in the backlog`);

  if (mode === "serve") {
    send({ type: "policy.save", policy: { ...policy, scoutItems: 3 } });
    step(`serving Scout runs for ${goal.name} (${goal.prefix}) for ${serveSecs}s`);
    await sleep(Number(serveSecs) * 1000);
    process.exit(0);
  }

  tokenReply = null;
  draftRun = null;
  send({ type: "goal.scout", goal: goal.id });
  // An app that connects while it runs finds it in its snapshot, running.
  await until("the draft.run", () => draftRun);
  const later = await snapshotOf();
  const inSnapshot = (later.scoutRuns ?? []).find((r) => r.goal === goal.id);
  if (inSnapshot?.state !== "running") throw new Error(`a new app's snapshot has ${JSON.stringify(later.scoutRuns)}`);
  step(`a new app's snapshot has the run in scoutRuns: ${inSnapshot.state}, by ${inSnapshot.by}`);
  await until("the Scout run", () => runs.some((r) => r.goal === goal.id && r.state !== "running"), 20_000);
  if (!draftRun?.id.startsWith("scout-")) throw new Error(`no scout- draft.run: ${draftRun?.id}`);
  const shown = [...draftRun.prompt.matchAll(/^- from (\S+)/gm)].map((x) => x[1]);
  step(`draft.run ${draftRun.id} (${draftRun.agent}, folder ${draftRun.folder}) shown ${shown.length} leftovers: ${shown.join(", ")}`);
  if (folder === GITHUB_FOLDER) {
    const { fetch: got, push } = tokenReply ?? {};
    // Granted, or (no app on this server) not installed; never refused as outside the goal.
    if (!got || !(got.token || got.code === "not_installed")) throw new Error(`the fetch token for acme/greeter: ${JSON.stringify(got)}`);
    if (push?.token || (push?.code !== "not_installed" && !/can only fetch, not push/.test(push?.error ?? ""))) throw new Error(`a push token for acme/greeter: ${JSON.stringify(push)}`);
    step(got.token ? `a read-only token to fetch acme/greeter (the folder's origin): granted` : `a token to fetch acme/greeter: the server has no GitHub App ("${got.error}"), not refused`);
    step(`a push token: refused ("${push.error}")`);
  }
  const mine = runs.filter((r) => r.goal === goal.id);
  step(`scout.updated: ${mine.map((r) => r.state).join(" → ")}`);
  const run = mine.at(-1);
  if (mine[0].state !== "running" || run.state !== "done") throw new Error(`the run went ${mine.map((r) => r.state).join(" → ")}: ${run.error}`);
  if (run.tasks.length !== 2) throw new Error(`expected 2 tasks (scoutItems), got ${run.tasks.length}`);
  await sleep(300);
  for (const id of run.tasks) {
    const t = tasks.get(id);
    // A backlog pick is that task, picked up in place; a finding becomes a new task that says where it came from.
    const backlog = id === parked;
    if (t.goal !== goal.id || t.state !== "planning" || (!backlog && !t.scoutedFrom?.startsWith(`${first}#`))) throw new Error(`${id}: ${JSON.stringify({ goal: t.goal, state: t.state, scoutedFrom: t.scoutedFrom })}`);
    const event = t.events.find((ev) => /^Scout(ed from| picked it up)/.test(ev.text))?.text;
    step(backlog ? `${id} "${t.title}" (from the backlog): ${t.state}, event "${event}"` : `${id} "${t.title}": ${t.state}, scoutedFrom ${t.scoutedFrom}, event "${event}"`);
  }

  // Again: what the first run made isn't shown a second time.
  draftRun = null;
  send({ type: "goal.scout", goal: goal.id });
  await until("the second run", () => runs.filter((r) => r.goal === goal.id).length > mine.length && runs.at(-1).state !== "running");
  const again = [...(draftRun?.prompt ?? "").matchAll(/^- from (\S+)/gm)].map((x) => x[1]);
  if (again.some((f) => run.tasks.some((id) => tasks.get(id).scoutedFrom === f))) throw new Error(`the second run was shown ${again.join(", ")} again`);
  step(`a second run is shown only ${again.join(", ") || "nothing"}; made ${runs.at(-1).tasks.join(", ") || "nothing"}`);
}

for (const folder of mode === "serve" ? ["/tmp/scout-e2e/repo"] : ["/tmp/scout-e2e/repo", GITHUB_FOLDER]) {
  console.log(`— a goal on ${folder === GITHUB_FOLDER ? "a folder whose origin is github.com/acme/greeter" : "a plain local folder"}`);
  await scenario(folder);
}

send({ type: "policy.save", policy: { ...policy, scoutItems: 3 } });
if (errors.length) throw new Error(`errors: ${errors.join("; ")}`);
step("Scout works end to end");
process.exit(0);

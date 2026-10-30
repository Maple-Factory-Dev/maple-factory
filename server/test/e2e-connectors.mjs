// The factory's MCP connectors (MF-63), with this script as the runner:
//   node server/test/e2e-connectors.mjs http://localhost:8788
// An admin saves a Jira connector (stdio, with a token) and a disabled one; then checks: the
// connectors.updated broadcast and a fresh snapshot carry no token value, only the key; a member's
// connectors.save is refused; saving the list back with the token blank keeps the stored token; a
// bad name (maple, a duplicate) is refused; a factory builder's session.open on this runner carries
// the enabled connector with its token (and not the disabled one); so does a session opened by hand.

const [base = "http://localhost:8788"] = process.argv.slice(2);
const ws = base.replace(/^http/, "ws");
const run = Date.now() % 100000;
let failures = 0;
const check = (ok, what) => { console.log(`${ok ? "ok  " : "FAIL"} ${what}`); if (!ok) failures++; };
const wait = async (what, test, ms = 20000) => {
  const deadline = Date.now() + ms;
  for (;;) {
    const hit = test();
    if (hit) return hit;
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 100));
  }
};

const connect = async (as) => {
  const { token, member } = await (await fetch(`${base}/dev/token${as ? `?as=${as}` : ""}`, { method: "POST" })).json();
  const feed = new WebSocket(`${ws}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
  const app = { feed, token, member, raw: [], seen: [], errors: [], goals: [], tasks: new Map() };
  feed.onmessage = (e) => {
    app.raw.push(e.data);
    const m = JSON.parse(e.data);
    app.seen.push(m);
    if (m.type === "snapshot") { app.goals = m.goals; for (const t of m.tasks) app.tasks.set(t.id, t); }
    if (m.type === "goal.updated") app.goals = [...app.goals.filter((g) => g.id !== m.goal.id), m.goal];
    if (m.type === "task.updated") app.tasks.set(m.task.id, m.task);
    if (m.type === "error") app.errors.push(m.message);
  };
  app.send = (m) => feed.send(JSON.stringify(m));
  app.last = (type) => app.seen.findLast((m) => m.type === type);
  await new Promise((r) => (feed.onopen = r));
  app.send({ type: "subscribe" });
  await wait("snapshot", () => app.last("snapshot"));
  return app;
};
const refused = async (app, what, msg, pattern) => {
  app.errors = [];
  app.send(msg);
  const said = await wait(`${what} refused`, () => app.errors[0]);
  check(pattern.test(said), `${what} is refused: "${said}"`);
  app.errors = [];
};

const admin = await connect(null);
const member = await connect(`mf63-member${run}`);
check(admin.member.role === "admin" && member.member.role !== "admin", `signed in as ${admin.member.login} (admin) and ${member.member.login} (${member.member.role})`);

// ---- saving ----
const token = `jira-secret-${run}-${crypto.randomUUID()}`;
const jira = {
  name: `jira-${run}`, transport: "stdio", command: "npx", args: ["-y", "mcp-atlassian"], url: null,
  env: { JIRA_URL: "https://acme.atlassian.net", JIRA_API_TOKEN: token }, headers: {}, enabled: true, autoAllow: true,
};
const off = { name: `off-${run}`, transport: "http", command: null, args: [], url: "https://mcp.example.com/mcp", env: {}, headers: { Authorization: "Bearer off-secret" }, enabled: false, autoAllow: false };
admin.send({ type: "connectors.save", connectors: [jira, off] });
const updated = await wait("connectors.updated", () => member.seen.find((m) => m.type === "connectors.updated" && m.connectors.some((c) => c.name === jira.name)));
const shown = updated.connectors.find((c) => c.name === jira.name);
check(shown.env.JIRA_API_TOKEN === "" && "JIRA_API_TOKEN" in shown.env, `connectors.updated shows the token's key with a blank value: ${JSON.stringify(shown.env)}`);
check(!member.raw.some((r) => r.includes(token) || r.includes("off-secret")), "no message to the member's app contains a secret value");

const fresh = await connect(null);
const snap = fresh.last("snapshot").connectors;
check(snap?.find((c) => c.name === jira.name)?.args.join(" ") === "-y mcp-atlassian", `a fresh snapshot lists the connectors: ${snap?.map((c) => c.name).join(", ")}`);
check(!fresh.raw.some((r) => r.includes(token) || r.includes("off-secret")), "the snapshot contains no secret value");
fresh.close?.();

await refused(member, "a member's connectors.save", { type: "connectors.save", connectors: [] }, /Only admins/);
await refused(admin, "a connector named maple", { type: "connectors.save", connectors: [{ ...jira, name: "maple" }] }, /maple/);
await refused(admin, "two connectors with one name", { type: "connectors.save", connectors: [jira, { ...off, name: jira.name }] }, /two connectors/);
await refused(admin, "a new key with a blank value", { type: "connectors.save", connectors: [{ ...jira, env: { ...shown.env, NEW_KEY: "" } }] }, /NEW_KEY needs a value/);

// Saved back as the app has it (token blank), with a rename of nothing and autoAllow off: the token stays.
admin.seen.length = 0;
admin.send({ type: "connectors.save", connectors: [{ ...shown, autoAllow: false }, ...updated.connectors.filter((c) => c.name !== jira.name)] });
await wait("second connectors.updated", () => admin.seen.find((m) => m.type === "connectors.updated" && m.connectors.some((c) => c.name === jira.name && !c.autoAllow)));

// ---- the runner ----
const { code } = await (await fetch(`${base}/api/machines/enroll`, { method: "POST", headers: { authorization: `Bearer ${admin.token}` } })).json();
const runnerId = `connectors-${run}`;
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

const prefix = `MC${run % 1000}`;
admin.send({ type: "goal.save", goal: { id: "", name: `Connectors ${prefix}`, prefix, color: "#0EA5E9", summary: "MCP connectors", lead: "", folder: "/tmp/mf-connectors", base: "main" } });
const goal = await wait("goal", () => admin.goals.find((g) => g.prefix === prefix));
admin.send({ type: "task.create", goal: goal.id, title: "Read a Jira ticket", brief: "Use the Jira connector.", shareable: false, plan: true, tickets: [], agent: "scripted" });
const id = `${prefix}-1`;
const planner = await wait("planner", () => sessions.find((s) => s.taskId === id));
const planned = await call(planner.id, "submit_plan", {
  summary: "Read it.",
  steps: [{ text: "Read the ticket", file: "README.md" }],
  doneWhen: [{ text: "It's read", proof: "terminal" }],
  risk: { level: "low", reasons: ["Nothing changes."], areas: [] },
  footprint: { files: 1, lines: 1 },
});
check(!planned.error, `the planner submits a plan (${planned.error ?? "ok"})`);
await wait("plan", () => ["awaitingApproval", "building"].includes(admin.tasks.get(id)?.state));
if (admin.tasks.get(id).state === "awaitingApproval") admin.send({ type: "task.approvePlan", id });
const builder = await wait("builder", () => sessions.find((s) => s.taskId === id && s.id !== planner.id));
const sent = builder.connectors ?? [];
const sentJira = sent.find((c) => c.name === jira.name);
check(sentJira?.env.JIRA_API_TOKEN === token, `the builder's session.open carries ${jira.name} with its token (kept through the blank save)`);
check(sentJira?.command === "npx" && sentJira.args.join(" ") === "-y mcp-atlassian" && sentJira.autoAllow === false, `…and its command, args and autoAllow: ${sentJira?.command} ${sentJira?.args.join(" ")}, autoAllow ${sentJira?.autoAllow}`);
check(!sent.some((c) => c.name === off.name), "the disabled connector isn't sent");
admin.send({ type: "task.cancel", id });

// A session opened by hand gets them too.
admin.send({ type: "session.open", machine: runnerId, agent: "claude", cwd: "/tmp", cols: 80, rows: 24 });
const byHand = await wait("hand-opened session", () => sessions.find((s) => !s.taskId));
check(byHand.connectors?.find((c) => c.name === jira.name)?.env.JIRA_API_TOKEN === token, "a session opened by hand carries the connector with its token");
check(!admin.raw.some((r) => r.includes(token)), "nothing the admin's app received contains the token");

// Leave the factory as it was.
admin.send({ type: "connectors.save", connectors: [] });
await new Promise((r) => setTimeout(r, 300));
console.log(failures ? `${failures} FAILED` : "all passed");
process.exit(failures ? 1 : 0);

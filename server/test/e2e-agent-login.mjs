// Signing a machine's agent in from the app (`codex login --device-auth`), against `wrangler dev` and a
// talking-only runner enrolled here (like test/fake-runner.mjs) that plays the login itself:
//   node server/test/e2e-agent-login.mjs http://localhost:8788
// Checks: another member and an admin (DEV_LOGIN) are refused and the runner is asked nothing; the owner's
// machine.agent_login reaches the runner as agent.login; the runner's waiting status, with its link and
// code, goes to the owner's app only (not the other member's, nor the admin's); done follows, and the next
// health shows Codex signed in. A cancel reaches the runner as agent.login with cancel set.

const [base = "http://localhost:8788"] = process.argv.slice(2);
const ws = base.replace(/^http/, "ws");
const tokenFor = async (as) => (await (await fetch(`${base}/dev/token${as ? `?as=${as}` : ""}`, { method: "POST" })).json()).token;
const suffix = Date.now() % 100000;
const ownerLogin = `owner-${suffix}`;
const [ownerToken, otherToken, adminToken] = await Promise.all([tokenFor(ownerLogin), tokenFor(`other-${suffix}`), tokenFor(null)]);

const wait = async (what, test, ms = 10000) => {
  const deadline = Date.now() + ms;
  for (;;) {
    const hit = test();
    if (hit) return hit;
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 100));
  }
};
const step = (text) => console.log(`✓ ${text}`);
const fail = (text) => { throw new Error(text); };

// The runner, enrolled by the owner: records what the hub asks of it.
const runnerId = `login-${suffix}`;
const { code: enrollCode } = await (await fetch(`${base}/api/machines/enroll`, { method: "POST", headers: { authorization: `Bearer ${ownerToken}` } })).json();
const enrolled = await (await fetch(`${base}/runner/enroll`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ code: enrollCode, runnerId, hostname: runnerId, os: "linux", arch: "arm64", version: "0.0.0-fake" }),
})).json();
const runner = new WebSocket(`${ws}/runner/connect?runner=${runnerId}`, { headers: { authorization: `Bearer ${enrolled.token}` } });
await new Promise((r, j) => { runner.onopen = r; runner.onerror = j; });
const asked = [];
runner.onmessage = (e) => {
  if (typeof e.data !== "string") return;
  const m = JSON.parse(e.data);
  if (m.type === "agent.login") asked.push(m);
  if (m.type === "ping") runner.send(JSON.stringify({ type: "pong" }));
};
const toHub = (m) => runner.send(JSON.stringify(m));
const health = (loggedIn) => ({
  cpu: 5, cores: 8, load1: 0.5, memUsed: 4e9, memTotal: 16e9, diskUsed: 1e11, diskTotal: 5e11, uptime: 100, battery: null,
  agents: [{ name: "codex", version: "0.166.0", loggedIn }],
});
toHub({ type: "hello", runnerId, hostname: runnerId, os: "linux", arch: "arm64", version: "0.0.0-fake", sessions: [], ended: [] });
toHub({ type: "health", health: health(false) });

// An app: its machine as last told, its sign-in statuses and errors.
const connectApp = async (token) => {
  const sock = new WebSocket(`${ws}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
  const app = { snapshot: null, machine: null, logins: [], errors: [] };
  sock.onmessage = (e) => {
    const m = JSON.parse(e.data);
    if (m.type === "snapshot") { app.snapshot = m; app.machine = m.machines.find((x) => x.id === runnerId) ?? null; }
    if (m.type === "machine.updated" && m.machine.id === runnerId) app.machine = m.machine;
    if (m.type === "machine.agent_login") app.logins.push(m);
    if (m.type === "error") app.errors.push(m.message);
  };
  await new Promise((r) => (sock.onopen = r));
  sock.send(JSON.stringify({ type: "subscribe" }));
  await wait("snapshot", () => app.snapshot);
  app.send = (m) => sock.send(JSON.stringify(m));
  app.close = () => sock.close();
  return app;
};
const [owner, other, admin] = await Promise.all([connectApp(ownerToken), connectApp(otherToken), connectApp(adminToken)]);
await wait("the machine online and signed out of Codex", () => owner.machine?.online && owner.machine.health?.agents?.[0]?.loggedIn === false);
if (owner.machine.owner !== ownerLogin) fail(`machine owner is ${owner.machine.owner}`);
if (admin.snapshot.me.role !== "admin") fail(`DEV_LOGIN isn't an admin: ${admin.snapshot.me.role}`);
step(`${runnerId} is online, owned by ${ownerLogin}, Codex signed out`);

// Nobody but its owner may start a sign-in: not another member, not an admin.
for (const [who, app] of [["another member", other], ["an admin", admin]]) {
  app.send({ type: "machine.agent_login", machine: runnerId, agent: "codex" });
  const err = await wait(`${who}'s refusal`, () => app.errors.find((e) => e.includes("sign")));
  if (!err.includes(ownerLogin)) fail(`refusal doesn't name the owner: ${err}`);
  step(`${who} is refused: "${err}"`);
}
await new Promise((r) => setTimeout(r, 500));
if (asked.length) fail(`the runner was asked ${JSON.stringify(asked)}`);
step("the runner was asked nothing");

// The owner's request reaches the runner.
owner.send({ type: "machine.agent_login", machine: runnerId, agent: "codex" });
const ask = await wait("agent.login on the runner", () => asked[0]);
if (ask.agent !== "codex" || ask.cancel !== false) fail(`runner got ${JSON.stringify(ask)}`);
step(`the runner got ${JSON.stringify(ask)}`);

// The code goes to the owner only.
const expiresAt = Date.now() + 15 * 60e3;
toHub({ type: "agent.login_status", status: { agent: "codex", state: "starting" } });
toHub({ type: "agent.login_status", status: { agent: "codex", state: "waiting", url: "https://auth.openai.com/codex/device", code: "PCJL-K5RMO", expiresAt } });
const waiting = await wait("the owner's waiting status", () => owner.logins.find((m) => m.status.state === "waiting"));
if (waiting.machine !== runnerId || waiting.status.code !== "PCJL-K5RMO" || waiting.status.url !== "https://auth.openai.com/codex/device" || waiting.status.expiresAt !== expiresAt) {
  fail(`owner got ${JSON.stringify(waiting)}`);
}
step(`the owner sees ${waiting.status.url} and ${waiting.status.code}`);

toHub({ type: "agent.login_status", status: { agent: "codex", state: "done" } });
toHub({ type: "health", health: health(true) });
await wait("the owner's done status", () => owner.logins.find((m) => m.status.state === "done"));
await wait("health with Codex signed in", () => owner.machine.health?.agents?.[0]?.loggedIn === true);
step("done, and health shows Codex loggedIn: true");
if (other.logins.length || admin.logins.length) fail(`others got sign-in statuses: ${JSON.stringify([...other.logins, ...admin.logins])}`);
const leaked = JSON.stringify([other, admin].map((a) => a.machine));
if (leaked.includes("PCJL-K5RMO")) fail("the code reached another member's machine view");
step("the other member and the admin got no sign-in status, and never the code");

// A cancel reaches the runner too.
owner.send({ type: "machine.agent_login", machine: runnerId, agent: "codex", cancel: true });
const cancel = await wait("the cancel on the runner", () => asked[1]);
if (cancel.cancel !== true) fail(`runner got ${JSON.stringify(cancel)}`);
step("a cancel reaches the runner as agent.login with cancel: true");

for (const a of [owner, other, admin]) a.close();
runner.close();
console.log("all agent sign-in checks passed");
process.exit(0);

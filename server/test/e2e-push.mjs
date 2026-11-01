// Mobile push against `wrangler dev` and a fake push relay on localhost:
//   node server/test/e2e-push.mjs http://localhost:8788 8799
// Start the server with the fake relay: wrangler dev --var PUSH_RELAY_URL:http://localhost:8799
// Checks: off by default and a member's PUT /api/push gets 403; an admin turns it on (the factory enrolls
// with the relay); a member registers an APNs and an FCM token over the feed; a task's raised hand makes
// one signed /push/send per device whose body holds only token, platform, environment, ref, reason and
// factory id; turning it off revokes the credential at the relay, and a later hand sends nothing.

import { createServer } from "node:http";
import { createHash, createHmac } from "node:crypto";

const [base = "http://localhost:8788", relayPort = "8799"] = process.argv.slice(2);
const ws = base.replace(/^http/, "ws");
const step = (text) => console.log(`✓ ${text}`);

// The fake relay: enroll, revoke and send, checking signatures the way apps/site/push.js does.
const factories = new Map(); // id → sha256(secret)
const sends = [];
const relay = createServer(async (req, res) => {
  let raw = "";
  for await (const chunk of req) raw += chunk;
  const reply = (status, body) => { res.writeHead(status, { "content-type": "application/json" }); res.end(body == null ? "" : JSON.stringify(body)); };
  if (req.url === "/push/enroll") {
    const id = `pf_e2e${factories.size + 1}xxxxx`;
    const secret = `pfs_${crypto.randomUUID()}`;
    factories.set(id, createHash("sha256").update(secret).digest("hex"));
    return reply(200, { id, secret });
  }
  const id = req.headers["x-maple-factory"];
  const key = factories.get(id);
  const want = key && createHmac("sha256", key).update(`${req.headers["x-maple-timestamp"]}.${raw}`).digest("hex");
  if (!key || want !== req.headers["x-maple-signature"]) return reply(401, { error: "bad signature or revoked" });
  if (req.url === "/push/revoke") { factories.delete(id); return reply(204); }
  if (req.url === "/push/send") { sends.push(JSON.parse(raw)); return reply(200, { sent: true }); }
  reply(404);
});
await new Promise((r) => relay.listen(Number(relayPort), r));

const token = async (as) => (await (await fetch(`${base}/dev/token${as ? `?as=${as}` : ""}`, { method: "POST" })).json()).token;
const admin = await token();
const memberLogin = `push-member-${Date.now() % 100000}`;
const member = await token(memberLogin);
const api = (bearer, method, body) => fetch(`${base}/api/push`, { method, body: body && JSON.stringify(body), headers: { authorization: `Bearer ${bearer}`, ...(body ? { "content-type": "application/json" } : {}) } });

// The runner: plays the planner and builder; the builder's raise_hand goes to the task's owner (the member, by then).
const runnerId = `push-${Date.now() % 100000}`;
const auth = { authorization: `Bearer ${admin}` };
const { code } = await (await fetch(`${base}/api/machines/enroll`, { method: "POST", headers: auth })).json();
const enrolled = await (await fetch(`${base}/runner/enroll`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ code, runnerId, hostname: runnerId, os: "macos", arch: "arm64", version: "0.0.0-fake" }) })).json();
const runner = new WebSocket(`${ws}/runner/connect?runner=${runnerId}`, { headers: { authorization: `Bearer ${enrolled.token}` } });
await new Promise((r, j) => { runner.onopen = r; runner.onerror = j; });
const toServer = (m) => runner.send(JSON.stringify(m));
const sessions = new Map();
const replies = new Map();
runner.onmessage = (e) => {
  if (typeof e.data !== "string") return;
  const m = JSON.parse(e.data);
  if (m.type === "session.open" && m.taskId) {
    sessions.set(m.taskId, m.id);
    toServer({ type: "session.opened", session: { id: m.id, agent: m.agent, cwd: m.worktree?.path ?? m.cwd, pid: 1, startedAt: Date.now(), taskId: m.taskId } });
    toServer({ type: "task.started", taskId: m.taskId, repo: null, repoDir: "/tmp/push-repo", base: "main", project: null });
  }
  if (m.type === "session.kill") toServer({ type: "session.ended", end: { id: m.id, cause: "killed", code: null, signal: null, detail: null, at: Date.now(), lastOutput: [], by: null } });
  if (m.type === "mcp.response") replies.get(m.reqId)?.(m);
};
toServer({ type: "hello", runnerId, hostname: runnerId, os: "macos", arch: "arm64", version: "0.0.0-fake", sessions: [], ended: [] });
toServer({ type: "health", health: { cpu: 5, cores: 10, load1: 0.5, memUsed: 8e9, memTotal: 32e9, diskUsed: 2e11, diskTotal: 1e12, uptime: 1000, battery: null, agents: [{ name: "claude", version: "2.1.0", loggedIn: true }] } });
let n = 0;
const tool = (taskId, name, args = {}) => new Promise((resolve, reject) => {
  const reqId = `r${++n}`;
  replies.set(reqId, (m) => (m.error ? reject(new Error(`${name}: ${m.error}`)) : resolve(m.result)));
  toServer({ type: "mcp.request", reqId, session: sessions.get(taskId), tool: name, args });
});

function app(bearer) {
  const feed = new WebSocket(`${ws}/client/connect`, { headers: { authorization: `Bearer ${bearer}` } });
  const c = { feed, tasks: new Map(), goals: [], machines: [], errors: [], devices: null, poke: null };
  feed.onmessage = (e) => {
    const m = JSON.parse(e.data);
    if (m.type === "snapshot") { c.goals = m.goals; c.machines = m.machines; for (const t of m.tasks) c.tasks.set(t.id, t); }
    if (m.type === "goal.updated") c.goals = [...c.goals.filter((g) => g.id !== m.goal.id), m.goal];
    if (m.type === "machine.updated") c.machines = [...c.machines.filter((x) => x.id !== m.machine.id), m.machine];
    if (m.type === "task.updated") c.tasks.set(m.task.id, m.task);
    if (m.type === "push.devices") c.devices = m.devices;
    if (m.type === "error") c.errors.push(m.message);
    c.poke?.();
  };
  c.send = (m) => feed.send(JSON.stringify(m));
  c.wait = async (what, test, ms = 30000) => {
    const deadline = Date.now() + ms;
    for (;;) {
      const hit = test();
      if (hit) return hit;
      if (c.errors.length) throw new Error(`server said: ${c.errors.join("; ")}`);
      if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
      await new Promise((r) => { c.poke = r; setTimeout(r, 250); });
    }
  };
  c.open = new Promise((r) => (feed.onopen = r));
  return c;
}

const me = app(admin);
const phone = app(member);
await Promise.all([me.open, phone.open]);
me.send({ type: "subscribe" });
phone.send({ type: "subscribe" });
const machine = await me.wait("the runner", () => me.machines.find((x) => x.id === runnerId && x.online));
const settings = (paused) => ({ capacity: null, teamSlots: 0, lendIdle: false, loadCap: 0.85, paused, pausedUntil: null });
const others = me.machines.filter((x) => x.id !== runnerId && x.owner === machine.owner && !x.settings?.paused);
for (const o of others) me.send({ type: "machine.settings", machine: o.id, settings: settings(true) });
me.send({ type: "machine.settings", machine: runnerId, settings: { ...settings(false), capacity: 2, teamSlots: 2 } });

const expect = async (res, status, what) => {
  const body = await res.text();
  if (res.status !== status) throw new Error(`${what}: expected ${status}, got ${res.status} ${body}`);
  return body;
};

/** A task built to the point where its builder raises a hand, then handed to the member (so the hand is theirs). */
async function handTask(prefix) {
  me.send({ type: "goal.save", goal: { id: "", name: `Push ${prefix}`, prefix, color: "#14B8A6", summary: "", lead: "", repos: [], folder: "/tmp/push-repo", base: "main" } });
  const goal = await me.wait("the goal", () => me.goals.find((g) => g.prefix === prefix));
  me.send({ type: "task.create", goal: goal.id, title: "Wake my phone", brief: "A task for the push e2e.", shareable: false, plan: true, tickets: [] });
  const id = (await me.wait("the task", () => [...me.tasks.values()].find((t) => t.goal === goal.id))).id;
  const task = () => me.tasks.get(id);
  await me.wait("the planner", () => task()?.worker?.role === "planner" && sessions.get(id) === task().worker.session);
  await tool(id, "submit_plan", { summary: "One step.", steps: [{ text: "Do it", file: "a.txt" }], doneWhen: [{ text: "Done", proof: "terminal" }], risk: { level: "low", reasons: [], areas: [] }, footprint: { files: 1, lines: 3 } });
  await me.wait("awaiting approval", () => task()?.state === "awaitingApproval");
  me.send({ type: "task.approvePlan", id });
  await me.wait("the builder", () => task()?.worker?.role === "builder" && sessions.get(id) === task().worker.session);
  me.send({ type: "task.assign", id, owner: memberLogin });
  await me.wait("the member owns it", () => task()?.owner === memberLogin);
  return { id, task };
}

try {
  // A run cut short can leave it on: start from off (this fake relay never knew that credential).
  if (JSON.parse(await expect(await api(admin, "GET"), 200, "GET")).enrolled) await expect(await api(admin, "PUT", { on: false }), 200, "reset");
  const start = JSON.parse(await expect(await api(admin, "GET"), 200, "GET"));
  if (start.on || start.enrolled) throw new Error(`expected off: ${JSON.stringify(start)}`);
  step(`off: GET /api/push → ${JSON.stringify(start)}`);
  step(`member's PUT → 403: "${await expect(await api(member, "PUT", { on: true }), 403, "member's PUT")}"`);

  phone.send({ type: "push.register", platform: "apns", token: "apns0123456789abcdef", environment: "sandbox" });
  phone.send({ type: "push.register", platform: "fcm", token: "fcm:APA91b-e2e-token", environment: "production" });
  await phone.wait("two devices", () => phone.devices?.length === 2);
  if (JSON.stringify(phone.devices).includes("apns0123456789abcdef")) throw new Error("push.devices echoed a token");
  step(`member registered an APNs and an FCM token (relay still off): push.devices → ${phone.devices.map((d) => `${d.platform}/${d.environment} id ${d.id}`).join(", ")}`);

  const on = JSON.parse(await expect(await api(admin, "PUT", { on: true }), 200, "admin's PUT on"));
  if (!on.on || on.devices < 2  || factories.size !== 1) throw new Error(`on: ${JSON.stringify(on)}, relay factories ${factories.size}`);
  step(`admin turned it on: ${JSON.stringify(on)}; the relay enrolled ${[...factories.keys()][0]}`);

  const prefix = `PU${String(Date.now() % 10000).padStart(4, "0")}`.slice(0, 6);
  const a = await handTask(prefix);
  await tool(a.id, "raise_hand", { reason: "needsInput", summary: "Which file should I change?", options: [{ title: "a.txt", detail: "The usual one", recommended: true }] });
  await me.wait("the hand", () => a.task()?.hand);
  const deadline = Date.now() + 10000;
  const hands = () => sends.filter((s) => s.ref === a.id && s.reason === "hand");
  while (hands().length < 2 && Date.now() < deadline) await new Promise((r) => setTimeout(r, 200));
  const got = hands();
  await new Promise((r) => setTimeout(r, 1000));
  if (hands().length !== 2) throw new Error(`more than one hand push per device: ${JSON.stringify(hands())}`);
  if (got.length !== 2) throw new Error(`expected 2 sends for ${a.id}, got ${JSON.stringify(sends)}`);
  for (const s of got) {
    const keys = Object.keys(s).sort().join(",");
    if (keys !== "environment,factory,platform,reason,ref,token") throw new Error(`unexpected fields: ${keys}`);
    console.log(`  /push/send (signature checked) ${JSON.stringify(s)}`);
  }
  step(`${a.id}'s raised hand → one signed /push/send per device (${got.map((s) => s.platform).join(", ")}), reason ${got[0].reason}`);

  const off = JSON.parse(await expect(await api(admin, "PUT", { on: false }), 200, "admin's PUT off"));
  if (off.on || off.enrolled || factories.size !== 0) throw new Error(`off: ${JSON.stringify(off)}, relay still has ${factories.size}`);
  step(`admin turned it off: ${JSON.stringify(off)}; the relay revoked the credential (0 factories enrolled)`);

  const b = await handTask(`PV${prefix.slice(2)}`);
  const beforeB = sends.length;
  await tool(b.id, "raise_hand", { reason: "needsInput", summary: "Again?", options: [{ title: "yes", detail: "", recommended: true }] });
  await me.wait("the second hand", () => b.task()?.hand);
  await new Promise((r) => setTimeout(r, 3000));
  if (sends.length !== beforeB) throw new Error(`sent after off: ${JSON.stringify(sends.slice(beforeB))}`);
  step(`${b.id}'s raised hand after off → no /push/send (total sends still ${sends.length})`);
  console.log("all good");
} finally {
  for (const o of others) me.send({ type: "machine.settings", machine: o.id, settings: settings(false) });
  await new Promise((r) => setTimeout(r, 300));
  runner.close(); me.feed.close(); phone.feed.close(); relay.close();
}

// Reassigning a task, against `wrangler dev` and a talking-only runner of bob's (enrolled here, like
// test/fake-runner.mjs) set to one session at a time:
//   node server/test/e2e-assign.mjs http://localhost:8788
// alice, bob and carol are fresh members with no other machines; the DEV_LOGIN is an admin.
// Checks: alice's planned task waits for alice's machines; bob can't hand it to carol, but takes it
// over himself, and it starts on his machine with a "took it over" event; a second task bob takes
// over while his slot is busy waits naming his machine; a hand raised on a third (its session's
// login expired) moves to bob with the task; bob can't give alice's task away, an admin can (and
// the hand follows); a finished task and the same owner are refused.

const [base = "http://localhost:8788"] = process.argv.slice(2);
const ws = base.replace(/^http/, "ws");
const run = Date.now() % 100000;
const login = (name) => `${name}${run}`;

const connect = async (as) => {
  const { token, member } = await (await fetch(`${base}/dev/token${as ? `?as=${as}` : ""}`, { method: "POST" })).json();
  const feed = new WebSocket(`${ws}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
  const app = { feed, token, login: member.login, goals: [], tasks: new Map(), errors: [] };
  feed.onmessage = (e) => {
    const m = JSON.parse(e.data);
    if (m.type === "snapshot") { app.goals = m.goals; for (const t of m.tasks) app.tasks.set(t.id, t); }
    if (m.type === "goal.updated") app.goals = [...app.goals.filter((g) => g.id !== m.goal.id), m.goal];
    if (m.type === "task.updated") app.tasks.set(m.task.id, m.task);
    if (m.type === "error") app.errors.push(m.message);
  };
  await new Promise((r) => (feed.onopen = r));
  feed.send(JSON.stringify({ type: "subscribe" }));
  return app;
};
const wait = async (what, test, ms = 15000) => {
  const deadline = Date.now() + ms;
  for (;;) {
    const hit = test();
    if (hit) return hit;
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 100));
  }
};
const step = (text) => console.log(`✓ ${text}`);
const send = (app, m) => app.feed.send(JSON.stringify(m));
const refused = async (app, what, msg, pattern) => {
  app.errors = [];
  send(app, msg);
  const said = await wait(`${what} refused`, () => app.errors[0]);
  if (!pattern.test(said)) throw new Error(`${what}: expected ${pattern}, got ${JSON.stringify(said)}`);
  app.errors = [];
  step(`${what}: "${said}"`);
};

const admin = await connect(null);
const alice = await connect(login("alice"));
const bob = await connect(login("bob"));
const carol = await connect(login("carol"));

// bob's runner: one session at a time. It opens the sessions it's sent and, for a task titled
// "Expire", ends it at once with an expired login (which raises a hand); the rest it keeps.
const runnerId = `assign-${run}`;
const { code } = await (await fetch(`${base}/api/machines/enroll`, { method: "POST", headers: { authorization: `Bearer ${bob.token}` } })).json();
const enrolled = await (await fetch(`${base}/runner/enroll`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ code, runnerId, hostname: runnerId, os: "macos", arch: "arm64", version: "0.0.0-fake" }),
})).json();
const runner = new WebSocket(`${ws}/runner/connect?runner=${runnerId}`, { headers: { authorization: `Bearer ${enrolled.token}` } });
await new Promise((r, j) => { runner.onopen = r; runner.onerror = j; });
const toServer = (m) => runner.send(JSON.stringify(m));
const opened = [];
runner.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "session.open" && m.taskId) {
    opened.push(m.taskId);
    toServer({ type: "session.opened", session: { id: m.id, agent: m.agent, cwd: `/tmp/assign/${m.taskId}`, pid: 1, startedAt: Date.now(), taskId: m.taskId } });
    if (bob.tasks.get(m.taskId)?.title === "Expire" || alice.tasks.get(m.taskId)?.title === "Expire") {
      setTimeout(() => toServer({ type: "session.ended", end: { id: m.id, cause: "authExpired", code: null, signal: null, detail: null, at: Date.now(), lastOutput: [], by: null } }), 300);
    }
  }
  if (m.type === "session.kill") toServer({ type: "session.ended", end: { id: m.id, cause: "killed", code: null, signal: null, detail: null, at: Date.now(), lastOutput: [], by: null } });
};
toServer({ type: "hello", runnerId, hostname: runnerId, os: "macos", arch: "arm64", version: "0.0.0-fake", sessions: [], ended: [] });
toServer({ type: "health", health: { cpu: 5, cores: 10, load1: 0.5, memUsed: 8e9, memTotal: 32e9, diskUsed: 2e11, diskTotal: 1e12, uptime: 1000, battery: null, agents: [{ name: "claude", version: "2.1.0", loggedIn: true }] } });
await new Promise((r) => setTimeout(r, 500));
send(bob, { type: "machine.settings", machine: runnerId, settings: { capacity: 1, teamSlots: 0, lendIdle: false, loadCap: 0.85, paused: false, pausedUntil: null } });
await new Promise((r) => setTimeout(r, 500));
step(`${bob.login}'s ${runnerId} connected, one session at a time`);

const prefix = `AS${run % 1000}`;
send(alice, { type: "goal.save", goal: { id: "", name: `Assign ${prefix}`, prefix, color: "#F59E0B", summary: "", lead: "", team: "", repos: [], folder: "/tmp/assign", base: "main" } });
const goal = await wait("goal", () => alice.goals.find((g) => g.prefix === prefix));
const create = async (title) => {
  const before = new Set(alice.tasks.keys());
  send(alice, { type: "task.create", goal: goal.id, title, brief: title, tickets: [], shareable: false, plan: true, agent: "claude" });
  return (await wait(title, () => [...alice.tasks.values()].find((t) => t.goal === goal.id && !before.has(t.id)))).id;
};
const task = (id) => alice.tasks.get(id);

// ---- a member takes over a teammate's planned task ----
const first = await create("First");
await wait(`${first} waiting on alice's machines`, () => task(first)?.waiting?.includes(`${alice.login}'s machines`));
step(`${first} is ${alice.login}'s: "${task(first).waiting}"`);

await refused(bob, `${bob.login} giving ${alice.login}'s task to ${carol.login}`, { type: "task.assign", id: first, owner: carol.login }, /Only .* or an admin/);
if (task(first).owner !== alice.login) throw new Error("the refused assign changed the owner");

send(bob, { type: "task.assign", id: first, owner: bob.login });
await wait(`${first} owned by bob`, () => task(first)?.owner === bob.login);
if (!task(first).events.some((e) => e.who === bob.login && e.text === "took it over")) throw new Error(`no "took it over" event: ${JSON.stringify(task(first).events)}`);
await wait(`${first} started on ${runnerId}`, () => task(first)?.worker?.machine === runnerId && opened.includes(first));
step(`${bob.login} took ${first} over; it started on ${runnerId}`);

// ---- the next one waits for the new owner's machine ----
const second = await create("Second");
await wait(`${second} waiting on alice's machines`, () => task(second)?.waiting?.includes(`${alice.login}'s machines`));
send(bob, { type: "task.assign", id: second, owner: bob.login });
await wait(`${second} waiting on bob's machine`, () => task(second)?.owner === bob.login && task(second)?.waiting?.includes(`${bob.login}'s machines (${runnerId})`));
step(`${second}, taken over with ${runnerId} busy: "${task(second).waiting}"`);
send(bob, { type: "task.cancel", id: second });
await wait(`${second} cancelled`, () => task(second)?.state === "cancelled");
send(bob, { type: "task.cancel", id: first });
await wait(`${first} cancelled, the slot free`, () => task(first)?.state === "cancelled" && !task(first).worker);

// ---- a hand moves with the task ----
const third = await create("Expire");
send(bob, { type: "task.assign", id: third, owner: bob.login });
await wait(`${third}'s hand`, () => task(third)?.hand);
if (task(third).hand.assignee !== bob.login) throw new Error(`hand is ${task(third).hand.assignee}'s, not ${bob.login}'s`);
step(`${third}'s hand went up for its new owner ${bob.login}: "${task(third).hand.summary}"`);

// Back to alice, by the admin; the hand goes with it. bob, not the owner now, can't give it away.
send(admin, { type: "task.assign", id: third, owner: alice.login });
await wait(`${third} back to alice`, () => task(third)?.owner === alice.login && task(third)?.hand?.assignee === alice.login);
if (!task(third).events.some((e) => e.who === admin.login && e.text === `assigned it to @${alice.login}`)) throw new Error("no event for the admin's assign");
step(`${admin.login} (admin) assigned ${third} to ${alice.login}; the hand is hers too`);
await refused(bob, `${bob.login} giving ${alice.login}'s task to ${carol.login} again`, { type: "task.assign", id: third, owner: carol.login }, /Only .* or an admin/);
send(admin, { type: "task.assign", id: third, owner: carol.login });
await wait(`${third} to carol`, () => task(third)?.owner === carol.login && task(third)?.hand?.assignee === carol.login);
step(`${admin.login} (admin) gave it to ${carol.login}, a third person`);
send(carol, { type: "task.assign", id: third, owner: alice.login });
await wait(`${third} back to alice from carol`, () => task(third)?.owner === alice.login);
step(`${carol.login}, its owner, handed it back to ${alice.login}`);

// ---- refusals ----
await refused(alice, "assigning to its owner", { type: "task.assign", id: third, owner: alice.login }, /already owns it/);
await refused(alice, "assigning to a non-member", { type: "task.assign", id: third, owner: `nobody${run}` }, /isn't in the org/);
send(alice, { type: "task.cancel", id: third });
await wait(`${third} cancelled`, () => task(third)?.state === "cancelled");
await refused(bob, "taking over a cancelled task", { type: "task.assign", id: third, owner: bob.login }, /already finished/);

for (const app of [admin, alice, bob, carol]) if (app.errors.length) throw new Error(`${app.login}: ${app.errors.join("; ")}`);
send(alice, { type: "goal.archive", id: goal.id, archived: true, unfinished: "cancel" });
await new Promise((r) => setTimeout(r, 300));
console.log("e2e-assign passed");
process.exit(0);

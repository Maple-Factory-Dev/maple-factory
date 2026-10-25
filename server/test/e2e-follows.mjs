// Following goals:
//   node server/test/e2e-follows.mjs http://localhost:8788
// Checks: a new goal is led by whoever made it and keeps its team; following and unfollowing reach
// only that person's apps, and a fresh connection's snapshot remembers the choice.

const [base = "http://localhost:8788"] = process.argv.slice(2);
const connect = async (as) => {
  const { token } = await (await fetch(`${base}/dev/token${as ? `?as=${as}` : ""}`, { method: "POST" })).json();
  const ws = new WebSocket(`${base.replace(/^http/, "ws")}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
  const app = { ws, goals: [], follows: null, me: null, errors: [], seen: [] };
  ws.onmessage = (e) => {
    const m = JSON.parse(e.data);
    app.seen.push(m.type);
    if (m.type === "snapshot") { app.goals = m.goals; app.follows = m.follows; app.me = m.me; }
    if (m.type === "goal.updated") app.goals = [...app.goals.filter((g) => g.id !== m.goal.id), m.goal];
    if (m.type === "follows.updated") app.follows = m.follows;
    if (m.type === "error") app.errors.push(m.message);
  };
  await new Promise((r) => (ws.onopen = r));
  ws.send(JSON.stringify({ type: "subscribe" }));
  await wait("snapshot", () => app.follows);
  return app;
};
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
const send = (app, m) => app.ws.send(JSON.stringify(m));

const me = await connect();
const other = await connect("follower2");
const prefix = `FW${Date.now() % 1000}`;
send(me, { type: "goal.save", goal: { id: "", name: `Follows ${prefix}`, prefix, color: "#14B8A6", summary: "", lead: "", team: "@Platform", repos: [], folder: "/tmp/follows", base: null } });
const goal = await wait("goal", () => me.goals.find((g) => g.prefix === prefix));
if (goal.lead !== me.me.login) throw new Error(`lead is "${goal.lead}", not ${me.me.login}`);
if (goal.team !== "platform") throw new Error(`team is ${goal.team}`);
step(`${goal.name} is led by ${goal.lead}, for @${goal.team}`);

send(me, { type: "goal.follow", id: goal.id, following: false });
await wait("unfollow", () => me.follows.some((f) => f.goal === goal.id && !f.following));
await new Promise((r) => setTimeout(r, 300));
if (other.seen.includes("follows.updated")) throw new Error("someone else's app heard about the follow");
step("unfollowing reached only my apps");

const again = await connect();
if (!again.follows.some((f) => f.goal === goal.id && !f.following)) throw new Error("a new snapshot forgot the unfollow");
step("a new connection's snapshot remembers it");

send(again, { type: "goal.follow", id: goal.id, following: true });
await wait("follow", () => me.follows.some((f) => f.goal === goal.id && f.following));
step("following again reached my other app");

send(me, { type: "goal.follow", id: "no-such-goal", following: true });
await wait("error", () => me.errors.length);
step(`following a missing goal: "${me.errors[0]}"`);

send(me, { type: "goal.archive", id: goal.id, archived: true });
await new Promise((r) => setTimeout(r, 300));
process.exit(0);

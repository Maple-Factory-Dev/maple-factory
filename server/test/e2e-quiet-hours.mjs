// Quiet hours (MF-224):
//   node server/test/e2e-quiet-hours.mjs http://localhost:8788
// Checks: setting quiet hours from one app reaches that person's other app (quietHours.updated) and
// a fresh connection's snapshot, never another member's app; a bad schedule is refused; clearing works.

const [base = "http://localhost:8788"] = process.argv.slice(2);
const connect = async (as) => {
  const { token } = await (await fetch(`${base}/dev/token${as ? `?as=${as}` : ""}`, { method: "POST" })).json();
  const ws = new WebSocket(`${base.replace(/^http/, "ws")}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
  const app = { ws, me: null, quietHours: undefined, updates: [], errors: [], snapshot: false };
  ws.onmessage = (e) => {
    const m = JSON.parse(e.data);
    if (m.type === "snapshot") { app.me = m.me; app.quietHours = m.quietHours ?? null; app.snapshot = true; }
    if (m.type === "quietHours.updated") { app.quietHours = m.quietHours ?? null; app.updates.push(m.quietHours ?? null); }
    if (m.type === "error") app.errors.push(m.message);
  };
  await new Promise((r) => (ws.onopen = r));
  ws.send(JSON.stringify({ type: "subscribe" }));
  await wait("snapshot", () => app.snapshot);
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
const show = (q) => q ? `${q.timeZone}: ${q.windows.map((w) => `[${w.days}] ${w.start}–${w.end}`).join(", ")}` : "none";

const phone = await connect();
const laptop = await connect();
const other = await connect("quiet2");
step(`${phone.me.login} on two connections, ${other.me.login} on a third`);

const schedule = {
  timeZone: "America/Toronto",
  windows: [
    { days: [4, 0, 1, 2, 3, 3], start: 22 * 60, end: 7 * 60 }, // weeknights, Sun–Thu (sent untidy: comes back sorted)
    { days: [1, 2, 3, 4, 5], start: 9 * 60, end: 17 * 60 }, // work hours
  ],
};
send(phone, { type: "quietHours.set", quietHours: schedule });
const got = await wait("quietHours.updated on the laptop", () => laptop.updates[0]);
if (got.windows.length !== 2 || got.windows[0].days.join() !== "0,1,2,3,4") throw new Error(`laptop got ${JSON.stringify(got)}`);
step(`the second connection got quietHours.updated: ${show(got)}`);
await wait("quietHours.updated on the phone too", () => phone.updates[0]);
step("the sender's own connection got it too");

await new Promise((r) => setTimeout(r, 300));
if (other.updates.length) throw new Error(`${other.me.login}'s app heard about it: ${JSON.stringify(other.updates)}`);
if (other.quietHours !== null) throw new Error(`${other.me.login}'s snapshot has quiet hours`);
step(`${other.me.login}'s app heard nothing`);

const again = await connect();
if (show(again.quietHours) !== show(got)) throw new Error(`a new snapshot has ${show(again.quietHours)}`);
step(`a new connection's snapshot has it: ${show(again.quietHours)}`);
const otherAgain = await connect("quiet2");
if (otherAgain.quietHours !== null) throw new Error(`${other.me.login}'s new snapshot has ${show(otherAgain.quietHours)}`);
step(`${other.me.login}'s new snapshot still has none`);

send(laptop, { type: "quietHours.set", quietHours: { timeZone: "Mars/Olympus", windows: [] } });
await wait("an error", () => laptop.errors.length);
step(`a bad time zone is refused: "${laptop.errors[0]}"`);
send(laptop, { type: "quietHours.set", quietHours: { timeZone: "UTC", windows: [{ days: [1], start: 600, end: 600 }] } });
await wait("an error", () => laptop.errors.length > 1);
step(`a zero-length window is refused: "${laptop.errors[1]}"`);
if (phone.updates.length !== 1) throw new Error("a refused schedule was sent out");

send(laptop, { type: "quietHours.set", quietHours: null });
await wait("cleared on the phone", () => phone.updates.length === 2 && phone.quietHours === null);
const last = await connect();
if (last.quietHours !== null) throw new Error("clearing didn't stick");
step("clearing reached the other connection and a new snapshot");
if (other.updates.length) throw new Error(`${other.me.login}'s app heard about it`);
step(`${other.me.login}'s app never heard a thing`);
process.exit(0);

// Recurring tasks through the OrgHub alarm:
//   node server/test/e2e-recurring.mjs http://localhost:8788
// Checks: a recurring task saved due now becomes a planning task (its prompt as the brief) when the alarm
// runs, and its next run moves forward one interval; a second due run is skipped while that task is open;
// pause holds it, runNow starts one at once, a refused save says why, and delete takes it out of the feed.

const [base = "http://localhost:8788"] = process.argv.slice(2);
const { token } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();
const alarm = () => fetch(`${base}/dev/alarm`, { method: "POST" }).then((r) => r.json());
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
const connect = async () => {
  const ws = new WebSocket(`${base.replace(/^http/, "ws")}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
  const c = { ws, goals: null, tasks: [], recurring: null, errors: [] };
  ws.onmessage = (e) => {
    const m = JSON.parse(e.data);
    if (m.type === "snapshot") Object.assign(c, { goals: m.goals, tasks: m.tasks, recurring: m.recurring });
    if (m.type === "goal.updated") c.goals = [...c.goals.filter((g) => g.id !== m.goal.id), m.goal];
    if (m.type === "task.updated") c.tasks = [...c.tasks.filter((t) => t.id !== m.task.id), m.task];
    if (m.type === "recurring.updated") c.recurring = [...c.recurring.filter((r) => r.id !== m.recurring.id), m.recurring];
    if (m.type === "recurring.deleted") c.recurring = c.recurring.filter((r) => r.id !== m.id);
    if (m.type === "error") c.errors.push(m.message);
  };
  await new Promise((r) => (ws.onopen = r));
  ws.send(JSON.stringify({ type: "subscribe" }));
  await wait("snapshot", () => c.goals);
  if (!Array.isArray(c.recurring)) throw new Error("the snapshot has no recurring list");
  return c;
};

const c = await connect();
const send = (m) => c.ws.send(JSON.stringify(m));
const prefix = `REC${Date.now() % 1000}`;
send({ type: "goal.save", goal: { id: "", name: `Recurring ${prefix}`, prefix, color: "#10B981", summary: "", lead: "", repos: [], folder: "/tmp/recurring-test", base: null } });
const goal = await wait("goal", () => c.goals.find((g) => g.prefix === prefix));

const HOUR = 60, DAY = 24 * HOUR;
const id = crypto.randomUUID();
const prompt = "Check for dependency updates and open a task for any worth taking.";
const firstAt = Date.now();
const recurring = { id, goal: goal.id, title: "Check for dependency updates", brief: prompt, repo: null, agent: "claude", every: 7 * DAY, unit: "weeks", firstAt, timeZone: "America/New_York", nextAt: 0, paused: false, lastRunAt: null, lastTask: null, by: "" };

// A bad save is refused.
let seen = c.errors.length;
send({ type: "recurring.save", recurring: { ...recurring, id: crypto.randomUUID(), every: 30 } });
step(`a 30-minute interval is refused: "${await wait("refusal", () => c.errors[seen])}"`);

// Saving one due now runs it right away (the save wakes the alarm path), and an explicit alarm makes no second one.
send({ type: "recurring.save", recurring });
let r = await wait("first run", () => c.recurring.find((x) => x.id === id && x.lastTask));
await alarm();
const task = await wait("its task", () => c.tasks.find((t) => t.id === r.lastTask));
if (task.goal !== goal.id) throw new Error(`${task.id} is in ${task.goal}`);
if (task.state !== "planning") throw new Error(`${task.id} is ${task.state}, not planning`);
if (!task.brief.startsWith(prompt) || !task.brief.includes("Recurring: Check for dependency updates, every week")) throw new Error(`brief: ${JSON.stringify(task.brief)}`);
const week = 7 * 24 * 3_600_000;
if (Math.abs(r.nextAt - (firstAt + week)) > 2 * 3_600_000) throw new Error(`nextAt ${new Date(r.nextAt).toISOString()} isn't a week after ${new Date(firstAt).toISOString()}`);
step(`due now → ${task.id} in planning with the prompt as its brief; next run ${new Date(r.nextAt).toISOString()} (one week on)`);
if (c.tasks.filter((t) => t.goal === goal.id).length !== 1) throw new Error("the alarm made a second task");

// Due again (an hourly one saved due now) while that task is still open: skipped.
const id2 = crypto.randomUUID();
send({ type: "recurring.save", recurring: { ...recurring, id: id2, title: "Hourly", every: HOUR, unit: "hours" } });
const hourly = await wait("hourly run", () => c.recurring.find((x) => x.id === id2 && x.lastTask));
const hourlyTask = hourly.lastTask;
// Move it due again by re-saving with a first run now (its lastTask is kept), then run the alarm.
send({ type: "recurring.save", recurring: { ...hourly, firstAt: Date.now() } });
await wait("re-saved", () => c.recurring.find((x) => x.id === id2 && x.firstAt !== hourly.firstAt));
await alarm();
await new Promise((r) => setTimeout(r, 500));
const after = c.recurring.find((x) => x.id === id2);
if (after.lastTask !== hourlyTask) throw new Error(`a second run made ${after.lastTask} while ${hourlyTask} is open`);
if (c.tasks.filter((t) => t.goal === goal.id).length !== 2) throw new Error("a skipped run made a task");
if (after.nextAt <= Date.now()) throw new Error("the skipped run's next run didn't move forward");
const noted = await wait("skip note", () => c.tasks.find((t) => t.id === hourlyTask)?.events.some((e) => /skipped a run/.test(e.text)));
step(`due again while ${hourlyTask} is open → skipped (noted on ${hourlyTask}), next run ${new Date(after.nextAt).toISOString()}`);

// Pause, then run now: run now starts one at once and keeps the schedule.
send({ type: "recurring.pause", id, paused: true });
r = await wait("paused", () => c.recurring.find((x) => x.id === id && x.paused));
step("paused");
const before = r.nextAt;
send({ type: "recurring.runNow", id });
r = await wait("run now", () => c.recurring.find((x) => x.id === id && x.lastTask !== task.id));
const second = await wait("run now's task", () => c.tasks.find((t) => t.id === r.lastTask));
if (second.state !== "planning") throw new Error(`${second.id} is ${second.state}`);
if (r.nextAt !== before) throw new Error("run now moved the schedule");
step(`run now → ${second.id} in planning, schedule kept`);
send({ type: "recurring.pause", id, paused: false });
r = await wait("resumed", () => c.recurring.find((x) => x.id === id && !x.paused));
if (r.nextAt <= Date.now()) throw new Error("resumed with a run in the past");
step(`resumed: next run ${new Date(r.nextAt).toISOString()}`);

// A fresh snapshot has them; delete takes them out.
const fresh = await connect();
if (!fresh.recurring.some((x) => x.id === id)) throw new Error("the snapshot lost it");
fresh.ws.close();
send({ type: "recurring.delete", id });
send({ type: "recurring.delete", id: id2 });
await wait("deleted", () => !c.recurring.some((x) => x.id === id || x.id === id2));
const again = await connect();
if (again.recurring.some((x) => x.id === id || x.id === id2)) throw new Error("deleted but still in the snapshot");
again.ws.close();
step("deleted: gone from the feed and a fresh snapshot");

// Tidy up: cancel the tasks it made and archive the goal.
for (const t of c.tasks.filter((t) => t.goal === goal.id)) send({ type: "task.cancel", id: t.id });
await new Promise((r) => setTimeout(r, 500));
send({ type: "goal.archive", id: goal.id, archived: true, unfinished: "cancel" });
await new Promise((r) => setTimeout(r, 300));
c.ws.close();
console.log("e2e-recurring passed");

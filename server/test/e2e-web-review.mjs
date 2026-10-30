// Reviewing a task's diff and asking for a change on a mockup from the web app (MF-128), with this script as the runner:
//   node server/test/e2e-web-review.mjs http://localhost:8788
// Enrolls a runner and makes a goal. The first task's plan has a mockup and waits for approval: task.mockupChange
// marks it changesRequested, records the change and sends the task back to planning. Once a second task is
// building, sends the web app's own task.review
// (two notes on lines and a summary) and checks: each note is a comment anchored to `path:Lstart–end` with its
// code, the summary is a comment of its own, the builder gets one change request ("Review · 2 comments") and the
// timeline says "asked for a change: a review of 2 comments"; a review with no comments is refused.
// The mockup's task is cancelled after; the review's task is left building with the review on it, to look at in the web app.

const [base = "http://localhost:8788"] = process.argv.slice(2);
const ws = base.replace(/^http/, "ws");
let failures = 0;
const check = (ok, what) => { console.log(`${ok ? "ok  " : "FAIL"} ${what}`); if (!ok) failures++; };

const { token } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();
const member = { authorization: `Bearer ${token}` };

// The runner: enrolled with the member's code, connected, answering the planner itself.
const { code } = await (await fetch(`${base}/api/machines/enroll`, { method: "POST", headers: member })).json();
const runnerId = `review-${Date.now().toString(36)}`;
const enrolled = await (await fetch(`${base}/runner/enroll`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ code, runnerId, hostname: runnerId, os: "macos", arch: "arm64", version: "0.0.0-fake" }),
})).json();
const runner = new WebSocket(`${ws}/runner/connect?runner=${runnerId}`, { headers: { authorization: `Bearer ${enrolled.token}` } });
await new Promise((r, j) => { runner.onopen = r; runner.onerror = j; });
const sessions = [];
const replies = new Map();
const typed = []; // what the factory types into the builder's terminal, in binary frames
runner.onmessage = async (e) => {
  if (typeof e.data !== "string") return typed.push(await e.data.text());
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

// The web app's feed.
const feed = new WebSocket(`${ws}/client/connect`, { headers: member });
const tasks = new Map();
const errors = [];
let me = null;
let goals = [];
let poke = null;
feed.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "snapshot") { me = m.me; goals = m.goals; for (const t of m.tasks) tasks.set(t.id, t); }
  if (m.type === "goal.updated") goals = [...goals.filter((g) => g.id !== m.goal.id), m.goal];
  if (m.type === "task.updated") tasks.set(m.task.id, m.task);
  if (m.type === "error") errors.push(m.message);
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
await wait("snapshot", () => me);

const prefix = `RV${Date.now() % 1000}`;
send({ type: "goal.save", goal: { id: "", name: `Review ${prefix}`, prefix, color: "#0E8FA3", summary: "Reviewing from the web", lead: "", folder: "/tmp/mf-review", base: "main" } });
const goal = await wait("goal", () => goals.find((g) => g.prefix === prefix));

/** A task planned by this script's planner, with `extra` in its plan. */
async function planned(title, extra = {}) {
  send({ type: "task.create", goal: goal.id, title, brief: "From the web review test.", shareable: false, plan: true, tickets: [], agent: "scripted" });
  const task = await wait(title, () => [...tasks.values()].find((t) => t.title === title));
  const planner = await wait(`${task.id}'s planner`, () => sessions.find((s) => s.taskId === task.id));
  const r = await call(planner.id, "submit_plan", {
    summary: "Wire up Save.", steps: [{ text: "Wire up Save", file: "web/settings.js" }],
    doneWhen: [{ text: "Saving shows a toast", proof: "screenshot" }],
    risk: { level: "low", reasons: ["One handler."], areas: [] }, footprint: { files: 1, lines: 10 }, ...extra,
  });
  check(!r.error, `${task.id}'s planner submits a plan (${r.error ?? "ok"})`);
  await wait(`${task.id}'s plan`, () => ["awaitingApproval", "building"].includes(tasks.get(task.id)?.state));
  return task.id;
}

// ---- a change to a mockup ----

const screen = { title: "Settings saved", kind: "screen", url: "/settings", html: "<p>Saved ✓</p>", notes: ["A toast once it's saved"] };
const mid = await planned(`Settings mockup ${prefix}`, { risk: { level: "high", reasons: ["Touches settings."], areas: ["settings"] }, mockups: [screen] });
const m = await wait("awaiting approval", () => tasks.get(mid)?.state === "awaitingApproval" && tasks.get(mid));
check(m.mockups.length === 1, `${mid} waits for approval with a mockup (${m.state}, ${m.mockups.length})`);
const before = errors.length;
send({ type: "task.mockupChange", id: mid, mockup: m.mockups[0].id, text: "Show what was saved in the toast." });
const back = await wait("back to planning", () => tasks.get(mid)?.state === "planning" && tasks.get(mid));
check(errors.length === before, `the server took it (${errors.slice(before).join("; ") || "no errors"})`);
check(back.mockups[0].status === "changesRequested", `the mockup is changesRequested (${back.mockups[0].status})`);
const asked = back.changes.at(-1);
check(asked?.anchor === "Mockup: Settings saved" && asked.text === "Show what was saved in the toast.", `the change is recorded (${asked?.anchor})`);
check(back.state === "planning", `an awaitingApproval task goes back to planning (${back.state})`);

// The runner has one slot: the planner it went back to gives it up for the review's task.
send({ type: "task.cancel", id: mid });
await wait("cancelled", () => tasks.get(mid)?.state === "cancelled");

// ---- a review of the diff ----

const id = await planned(`Settings page saves ${prefix}`);
if (tasks.get(id).state === "awaitingApproval") send({ type: "task.approvePlan", id });
await wait("building", () => tasks.get(id)?.state === "building");
check(true, `${id} is building`);

// What reviewBar sends: the notes as review.js's toNote made them, and the trimmed summary.
const notes = [
  { path: "web/settings.js", start: 12, end: 15, side: "new", snippet: " function save() {\n+  fetch('/api/settings');\n+  toast('Saved');\n }", text: "Await the fetch before the toast." },
  { path: "web/old.js", start: 4, end: 4, side: "old", snippet: "-  retry();", text: "Keep the retry." },
];
const sent = errors.length;
const changes = tasks.get(id).changes.length;
send({ type: "task.review", id, notes, summary: "Close, two things." });
const t = await wait("the review", () => tasks.get(id)?.changes.length > changes && tasks.get(id));
check(errors.length === sent, `the server took it (${errors.slice(sent).join("; ") || "no errors"})`);
const first = t.comments.find((c) => c.anchor === "web/settings.js:L12–15");
check(first && first.author === me.login && first.text.includes("+  toast('Saved');") && first.text.endsWith("Await the fetch before the toast."),
  `the first comment is anchored to web/settings.js:L12–15 with its code (${first?.anchor})`);
const second = t.comments.find((c) => c.anchor === "web/old.js:L4");
check(second?.text.endsWith("Keep the retry.") && second.text.includes("-  retry();"), `the second is anchored to web/old.js:L4 (${second?.anchor})`);
const summary = t.comments.find((c) => c.anchor === "Review");
check(summary?.text === "Close, two things.", `the summary is a comment of its own ("${summary?.text}")`);
const added = t.changes.slice(changes);
const change = added[0];
check(added.length === 1 && change.anchor === "Review · 2 comments", `the builder gets one change request (${added.length}: ${change?.anchor})`);
check(change?.text.includes("1. web/settings.js:L12–15: Await the fetch") && change.text.includes("2. web/old.js:L4 (removed lines): Keep the retry."),
  "the change request lists both notes by their lines");
await wait("the builder's terminal", () => typed.some((x) => x.includes(`Change request ${change?.id}`)), 5000).catch(() => null);
check(typed.some((x) => x.includes(`Change request ${change?.id} from ${me.login}`) && x.includes("Keep the retry.")), "it's typed into the builder's session as one change request");
check(t.events.some((e) => e.who === me.login && e.text === "asked for a change: a review of 2 comments"), "the timeline says \"asked for a change: a review of 2 comments\"");

// A review with nothing on a line: the web app never sends one, and the server refuses it anyway.
const early = errors.length;
send({ type: "task.review", id, notes: [{ ...notes[0], text: "   " }], summary: "Just a summary" });
const refused = await wait("the refusal", () => errors.length > early && errors.at(-1));
check(/Add a comment to a line first/.test(refused), `an empty review is refused ("${refused}")`);
check(tasks.get(id).changes.length === changes + 1, "and asks for no change");

console.log(`${id}, ${mid}: ${failures ? `${failures} failed` : "all ok"}`);
process.exit(failures ? 1 : 0);

// Attesting to a Done when item from the web app (MF-66), with this script as the runner:
//   node server/test/e2e-web-attest.mjs http://localhost:8788
// Enrolls a runner, makes a goal and a task, answers the planner's session with a two-item plan, and once
// it's building sends the web app's own task.checkedIt with a reason. Checks: the item is proven with
// attested=true, the person as `by` and the reason kept; the other item is still unproven; an "attested"
// event is on the timeline; and the server refuses the same message on a drafting task (no Done when yet)
// and on a cancelled one that has a Done when (not building or in review).
// The task is left building, with one item attested, to look at in the web app.

const [base = "http://localhost:8788"] = process.argv.slice(2);
const ws = base.replace(/^http/, "ws");
let failures = 0;
const check = (ok, what) => { console.log(`${ok ? "ok  " : "FAIL"} ${what}`); if (!ok) failures++; };

const { token } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();
const member = { authorization: `Bearer ${token}` };

// The runner: enrolled with the member's code, connected, answering the planner itself.
const { code } = await (await fetch(`${base}/api/machines/enroll`, { method: "POST", headers: member })).json();
const runnerId = `attest-${Date.now().toString(36)}`;
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

const prefix = `AT${Date.now() % 1000}`;
send({ type: "goal.save", goal: { id: "", name: `Attest ${prefix}`, prefix, color: "#14A866", summary: "Attesting from the web", lead: "", folder: "/tmp/mf-attest", base: "main" } });
const goal = await wait("goal", () => goals.find((g) => g.prefix === prefix));

// A draft first: attesting to it is refused.
send({ type: "task.create", goal: goal.id, title: `Still a draft ${prefix}`, brief: "", shareable: false, plan: false, tickets: [], repo: null });
const draft = await wait("the draft", () => [...tasks.values()].find((t) => t.title === `Still a draft ${prefix}`));
check(draft.state === "drafting", `${draft.id} is drafting (${draft.state})`);

// A planned task that was cancelled has a Done when, and is refused for its state.
send({ type: "task.create", goal: goal.id, title: `Cancelled ${prefix}`, brief: "Stop it.", shareable: false, plan: true, tickets: [], agent: "scripted" });
const other = await wait("the cancelled task", () => [...tasks.values()].find((x) => x.title === `Cancelled ${prefix}`));
const planner2 = await wait("its planner", () => sessions.find((s) => s.taskId === other.id));
await call(planner2.id, "submit_plan", {
  summary: "Nothing.", steps: [{ text: "Nothing", file: "x" }], doneWhen: [{ text: "Nothing changed", proof: "terminal" }],
  risk: { level: "low", reasons: ["None."], areas: [] }, footprint: { files: 1, lines: 1 },
});
await wait("its plan", () => tasks.get(other.id)?.doneWhen.length === 1);
send({ type: "task.cancel", id: other.id });
await wait("cancelled", () => tasks.get(other.id)?.state === "cancelled");
const before = errors.length;
send({ type: "task.checkedIt", id: other.id, item: 0, note: "Too late" });
const late = await wait("the refusal", () => errors.length > before && errors.at(-1));
check(/building or in review/.test(late), `a cancelled task with a Done when is refused ("${late}")`);
check(tasks.get(other.id).doneWhen[0].status !== "proven", "its item is still unproven");

send({ type: "task.create", goal: goal.id, title: `Settings page saves ${prefix}`, brief: "Make Save work.", shareable: false, plan: true, tickets: [], agent: "scripted" });
const task = await wait("the task", () => [...tasks.values()].find((t) => t.title === `Settings page saves ${prefix}`));
const id = task.id;
const planner = await wait("planner", () => sessions.find((s) => s.taskId === id));
const planned = await call(planner.id, "submit_plan", {
  summary: "Wire up Save.",
  steps: [{ text: "Wire up Save", file: "web/settings.js" }],
  doneWhen: [{ text: "Saving shows a toast", proof: "screenshot" }, { text: "The setting is kept after a reload", proof: "terminal" }],
  risk: { level: "low", reasons: ["One handler."], areas: [] },
  footprint: { files: 1, lines: 10 },
});
check(!planned.error, `the planner submits a plan (${planned.error ?? "ok"})`);
await wait("plan", () => tasks.get(id)?.state === "awaitingApproval" || tasks.get(id)?.state === "building");
if (tasks.get(id).state === "awaitingApproval") send({ type: "task.approvePlan", id });
await wait("building", () => tasks.get(id)?.state === "building");
check(true, `${id} is building`);

// What attestForm sends: the trimmed reason.
const sent = errors.length;
send({ type: "task.checkedIt", id, item: 0, note: "Clicked Save on staging, saw the toast" });
const t = await wait("attested", () => tasks.get(id)?.doneWhen[0].status === "proven" && tasks.get(id));
const d = t.doneWhen[0];
check(errors.length === sent, `the server took it (${errors.slice(sent).join("; ") || "no errors"})`);
check(d.evidence?.attested === true, `item 1 is attested (attested=${d.evidence?.attested})`);
check(d.evidence?.by === me.login, `by the person who sent it (${d.evidence?.by})`);
check(d.evidence?.reason === "Clicked Save on staging, saw the toast", `the reason is kept ("${d.evidence?.reason}")`);
check(t.doneWhen[1].status !== "proven", `item 2 is still unproven (${t.doneWhen[1].status})`);
const event = t.events.find((e) => e.text.startsWith("attested"));
check(event?.text === `attested "${d.text}": Clicked Save on staging, saw the toast` && event.who === me.login, `the timeline has it (${event?.who}: ${event?.text})`);

// The same message on the draft, which has no Done when yet.
const early = errors.length;
send({ type: "task.checkedIt", id: draft.id, item: 0, note: "Too early" });
const refused = await wait("the refusal", () => errors.length > early && errors.at(-1));
check(/no such Done when/.test(refused), `a drafting task is refused ("${refused}")`);
check(tasks.get(draft.id).state === "drafting" && tasks.get(draft.id).doneWhen.every((x) => !x.evidence?.attested), "the draft is unchanged");

console.log(`${id}: ${failures ? `${failures} failed` : "all passed"}`);
process.exit(failures ? 1 : 0);

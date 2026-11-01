// The builder attesting to Done when items for a person, over MCP (MF-295), with this script as the runner:
//   node server/test/e2e-mcp-attest.mjs http://localhost:8788
// Enrolls a runner, makes a goal and a task, answers the planner's session with a two-item plan, and once
// it's building plays the builder through the `maple` tools. Checks: `attest` before anyone answered is
// refused and the item stays unproven; after `ask` → the person's answer, `attest` proves item 1 with
// attested=true, by = the person, and their answer quoted in the reason, with a timeline event naming the
// builder and the person; a later `prove` keeps their sign-off; a new `raise_hand` takes the permission away
// until a person picks an option, after which item 2 is attested for them too.

const [base = "http://localhost:8788"] = process.argv.slice(2);
const ws = base.replace(/^http/, "ws");
let failures = 0;
const check = (ok, what) => { console.log(`${ok ? "ok  " : "FAIL"} ${what}`); if (!ok) failures++; };

const { token } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();
const member = { authorization: `Bearer ${token}` };

const { code } = await (await fetch(`${base}/api/machines/enroll`, { method: "POST", headers: member })).json();
const runnerId = `mcpattest-${Date.now().toString(36)}`;
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
  if (typeof e.data !== "string") return; // keystrokes typed into a session
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
const text = (r) => r.error ?? r.result?.summary ?? JSON.stringify(r.result);

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

const prefix = `MA${Date.now() % 1000}`;
send({ type: "goal.save", goal: { id: "", name: `MCP attest ${prefix}`, prefix, color: "#14A866", summary: "The builder attesting for a person", lead: "", folder: "/tmp/mf-mcp-attest", base: "main" } });
const goal = await wait("goal", () => goals.find((g) => g.prefix === prefix));

send({ type: "task.create", goal: goal.id, title: `Push arrives ${prefix}`, brief: "Send a push on merge.", shareable: false, plan: true, tickets: [], agent: "scripted" });
const task = await wait("the task", () => [...tasks.values()].find((t) => t.title === `Push arrives ${prefix}`));
const id = task.id;
const planner = await wait("planner", () => sessions.find((s) => s.taskId === id));
await call(planner.id, "submit_plan", {
  summary: "Send the push.",
  steps: [{ text: "Send it", file: "server/push.ts" }],
  doneWhen: [{ text: "The push shows on a real iPhone", proof: "screenshot" }, { text: "It arrives within a minute", proof: "terminal" }],
  risk: { level: "low", reasons: ["One call."], areas: [] },
  footprint: { files: 1, lines: 10 },
});
await wait("plan", () => tasks.get(id)?.state === "awaitingApproval" || tasks.get(id)?.state === "building");
if (tasks.get(id).state === "awaitingApproval") send({ type: "task.approvePlan", id });
await wait("building", () => tasks.get(id)?.state === "building");
const builder = await wait("builder", () => sessions.find((s) => s.taskId === id && s.id !== planner.id));
check(true, `${id} is building (builder session ${builder.id})`);

// 1. Nobody has answered yet: refused.
const early = await call(builder.id, "attest", { items: [1], reason: "No iPhone on this machine" });
check(!!early.error, `attest before any answer is refused ("${text(early)}")`);
check(tasks.get(id).doneWhen[0].status !== "proven", `item 1 stays unproven (${tasks.get(id).doneWhen[0].status})`);

// 2. ask → answer → attest.
await call(builder.id, "ask", { question: "I can't screenshot a real iPhone here. Attest item 1 for you?", options: ["Attest it for me", "I'll check it myself"] });
await wait("the question", () => tasks.get(id)?.question);
const answer = "Attest it for me, I saw it on my phone";
send({ type: "task.answer", id, text: answer });
await wait("answered", () => !tasks.get(id)?.question);
const done = await call(builder.id, "attest", { items: [1], reason: "No iPhone on this machine" });
check(!done.error, `attest after the answer is taken ("${text(done)}")`);
const t = await wait("attested", () => tasks.get(id)?.doneWhen[0].status === "proven" && tasks.get(id));
const d = t.doneWhen[0];
check(d.evidence?.attested === true, `item 1 is attested (attested=${d.evidence?.attested})`);
check(d.evidence?.by === me.login, `by the person who answered (${d.evidence?.by})`);
check(d.evidence?.reason === `No iPhone on this machine (confirmed in their answer: "${answer}")`, `their answer is quoted ("${d.evidence?.reason}")`);
check(t.doneWhen[1].status !== "proven", `item 2 is still unproven (${t.doneWhen[1].status})`);
const event = t.events.find((e) => e.who === "builder" && e.text.startsWith("attested"));
check(!!event && event.text.includes(`for ${me.login}`), `the timeline names both (${event?.who}: ${event?.text})`);

// 3. A later prove keeps the sign-off.
const proved = await call(builder.id, "prove", { item: 1, kind: "screenshot", summary: "Simulator only" });
check(/kept their sign-off/.test(text(proved)), `prove afterwards keeps it ("${text(proved)}")`);
check(tasks.get(id).doneWhen[0].evidence?.attested === true, "item 1 is still attested");

// 4. A new raise_hand takes it away until a person picks.
await call(builder.id, "raise_hand", { reason: "proofBurden", summary: "Can't time a real push here.", options: [{ title: "Attest it for me", detail: "Sign item 2 off for you" }, { title: "Skip it", detail: "Leave it" }] });
await wait("the hand", () => tasks.get(id)?.hand);
const again = await call(builder.id, "attest", { items: [2], reason: "Can't time a real push" });
check(!!again.error, `attest after a new raise_hand is refused ("${text(again)}")`);
check(tasks.get(id).doneWhen[1].status !== "proven", "item 2 stays unproven");
send({ type: "task.resolveHand", id, option: "Attest it for me", note: "" });
await wait("hand lowered", () => !tasks.get(id)?.hand);
const second = await call(builder.id, "attest", { items: [2], reason: "Can't time a real push" });
check(!second.error, `attest after the pick is taken ("${text(second)}")`);
const d2 = (await wait("item 2", () => tasks.get(id)?.doneWhen[1].status === "proven" && tasks.get(id))).doneWhen[1];
check(d2.evidence?.attested === true && d2.evidence.by === me.login && /Go with: Attest it for me/.test(d2.evidence.reason ?? ""), `item 2 is attested for them with their pick quoted ("${d2.evidence?.reason}")`);
check(/Every item is proven/.test(text(second)), "every item is proven");

console.log(`${id}: ${failures ? `${failures} failed` : "all passed"}`);
process.exit(failures ? 1 : 0);

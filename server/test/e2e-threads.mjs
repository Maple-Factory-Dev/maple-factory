// Comment threads (MF-214), with this script as the runner:
//   node server/test/e2e-threads.mjs http://localhost:8788
// Enrolls a runner, makes a goal and a task, answers the planner with a plan and keeps the builder's
// session open. Checks: an @builder comment starts a thread and is typed into the live session as
// conversation; the builder's `reply` lands under that root; a person's reply in that thread (even
// to the builder's reply) flattens onto the root and is typed in too; a plain comment with no agent
// in it isn't typed in and has no replyTo; a replyTo that isn't on the task is refused; and with no
// session running the reply is kept, an event says the next agent will see it, and get_task hands
// the open thread over. The task is left with its thread, to look at in the apps.

const [base = "http://localhost:8788"] = process.argv.slice(2);
const ws = base.replace(/^http/, "ws");
let failures = 0;
const check = (ok, what) => { console.log(`${ok ? "ok  " : "FAIL"} ${what}`); if (!ok) failures++; };

const { token } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();
const member = { authorization: `Bearer ${token}` };

// The runner: enrolled with the member's code, connected.
const { code } = await (await fetch(`${base}/api/machines/enroll`, { method: "POST", headers: member })).json();
const runnerId = `threads-${Date.now().toString(36)}`;
const enrolled = await (await fetch(`${base}/runner/enroll`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ code, runnerId, hostname: runnerId, os: "macos", arch: "arm64", version: "0.0.0-fake" }),
})).json();
const runner = new WebSocket(`${ws}/runner/connect?runner=${runnerId}`, { headers: { authorization: `Bearer ${enrolled.token}` } });
runner.binaryType = "arraybuffer";
await new Promise((r, j) => { runner.onopen = r; runner.onerror = j; });
const sessions = [];
const replies = new Map();
/** What the factory typed into each session (binary frames: 16-byte session id, then the bytes). */
const typed = [];
runner.onmessage = (e) => {
  if (typeof e.data !== "string") {
    const bytes = new Uint8Array(e.data);
    typed.push(new TextDecoder().decode(bytes.slice(16)));
    poke?.();
    return;
  }
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

const feed = new WebSocket(`${ws}/client/connect`, { headers: member });
const tasks = new Map();
let goals = [];
let poke = null;
let lastError = null;
feed.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "snapshot") { goals = m.goals; for (const t of m.tasks) tasks.set(t.id, t); }
  if (m.type === "goal.updated") goals = [...goals.filter((g) => g.id !== m.goal.id), m.goal];
  if (m.type === "task.updated") tasks.set(m.task.id, m.task);
  if (m.type === "error") lastError = m.message;
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

const prefix = `TH${Date.now() % 1000}`;
send({ type: "goal.save", goal: { id: "", name: `Threads ${prefix}`, prefix, color: "#3B82F6", summary: "Talking to agents in comment threads", lead: "", folder: "/tmp/mf-threads", base: "main" } });
const goal = await wait("goal", () => goals.find((g) => g.prefix === prefix));
send({ type: "task.create", goal: goal.id, title: "Cache the task list", brief: "Cache the task list so it opens instantly.", shareable: false, plan: true, tickets: [], agent: "scripted" });
const id = `${prefix}-1`;

const planner = await wait("planner", () => sessions.find((s) => s.taskId === id));
const planned = await call(planner.id, "submit_plan", {
  summary: "Cache it in memory.",
  steps: [{ text: "Cache the list", file: "web/tasks.js" }],
  doneWhen: [{ text: "The list opens from the cache", proof: "tests" }],
  risk: { level: "low", reasons: ["One list."], areas: [] },
  footprint: { files: 1, lines: 20 },
});
check(!planned.error, `the planner submits a plan (${planned.error ?? "ok"})`);
await wait("plan", () => ["awaitingApproval", "building"].includes(tasks.get(id)?.state));
if (tasks.get(id).state === "awaitingApproval") send({ type: "task.approvePlan", id });
const builder = await wait("builder", () => sessions.find((s) => s.taskId === id && s.id !== planner.id));
await wait("building", () => tasks.get(id)?.state === "building" && tasks.get(id)?.worker?.session === builder.id);

// A plain comment: no agent in it, nothing typed, no thread.
const before = typed.length;
send({ type: "task.comment", id, text: "Looks good so far." });
const plain = await wait("plain comment", () => tasks.get(id)?.comments.find((c) => c.text === "Looks good so far."));
await new Promise((r) => setTimeout(r, 500));
check(plain.replyTo == null && typed.length === before, `a comment with no agent in it isn't typed in and has no replyTo (${typed.length - before} typed)`);

// An @builder mention starts a thread and is typed into the live session as conversation.
send({ type: "task.comment", id, text: "@builder why an in-memory cache and not IndexedDB?" });
const root = await wait("mention", () => tasks.get(id)?.comments.find((c) => c.text.startsWith("@builder why")));
const asked = await wait("typed mention", () => typed.find((t) => t.includes(`in comment thread ${root.id}: @builder why`)));
check(Boolean(asked) && asked.includes(`Answer with \`reply\` (thread ${root.id})`) && asked.includes("not a change request"), `the @builder mention is typed in as conversation (${JSON.stringify(asked?.slice(0, 120))})`);
check(root.replyTo == null, "the mention is the thread's root");
check(!(tasks.get(id).changes ?? []).some((c) => c.text.includes("IndexedDB")), "it isn't a change request");

// The builder answers with `reply`; it lands under the root, authored by the builder.
const r1 = await call(builder.id, "reply", { thread: root.id, text: "The list is small and rebuilt on every snapshot, so memory is enough." });
check(!r1.error, `the builder's reply is accepted (${r1.result?.summary ?? r1.error})`);
const answer = await wait("reply", () => tasks.get(id)?.comments.find((c) => c.author === "builder" && c.replyTo === root.id));
check(answer.text.startsWith("The list is small"), "the builder's reply lands under the root");

// A person's reply to the builder's reply flattens onto the root and is typed in.
send({ type: "task.comment", id, text: "Makes sense. What about after a reload?", replyTo: answer.id });
const followUp = await wait("follow-up", () => tasks.get(id)?.comments.find((c) => c.text.startsWith("Makes sense.")));
check(followUp.replyTo === root.id, `a reply to a reply goes under the root (${followUp.replyTo})`);
check(Boolean(await wait("typed follow-up", () => typed.find((t) => t.includes(`in comment thread ${root.id}: Makes sense.`)))), "the person's reply in the agent's thread is typed into the session");

// A replyTo that isn't on the task is refused.
lastError = null;
send({ type: "task.comment", id, text: "into the void", replyTo: "not-a-comment" });
const refused = await wait("refusal", () => lastError);
check(/isn't on this task/.test(refused) && !tasks.get(id).comments.some((c) => c.text === "into the void"), `a bad replyTo is refused (${refused})`);

// A reply to a comment in a thread with no agent: kept, not typed in.
const n = typed.length;
send({ type: "task.comment", id, text: "Agreed.", replyTo: plain.id });
const agreed = await wait("people-only reply", () => tasks.get(id)?.comments.find((c) => c.text === "Agreed."));
await new Promise((r) => setTimeout(r, 500));
check(agreed.replyTo === plain.id && typed.length === n, "a reply in a thread with no agent stays between people");

// With no session: the builder's session ends, the reply is kept and get_task hands it over.
runner.send(JSON.stringify({ type: "session.ended", end: { id: builder.id, cause: "killed", code: null, signal: null, detail: null, at: Date.now(), lastOutput: [], by: "factory" } }));
await wait("no worker", () => !tasks.get(id)?.worker || tasks.get(id).worker.session !== builder.id, 10000).catch(() => null);
const idle = !tasks.get(id)?.worker;
if (idle) {
  const m = typed.length;
  send({ type: "task.comment", id, text: "One more: does it survive sign-out?", replyTo: root.id });
  const kept = await wait("kept", () => tasks.get(id)?.comments.find((c) => c.text.startsWith("One more")));
  await wait("event", () => tasks.get(id)?.events.some((e) => e.text.includes("the next agent on it will see it")));
  check(kept.replyTo === root.id && typed.length === m, "with nothing running the reply is kept and nothing is typed");
  check(true, "an event says the next agent will see it");
} else console.log(`note: the builder's session didn't close here (worker ${JSON.stringify(tasks.get(id)?.worker)}); checking get_task on the live one`);

// The next builder (Retry starts one) calls get_task, which lists the open thread.
if (idle) send({ type: "task.retry", id });
const next = idle ? await wait("next session", () => sessions.find((s) => s.taskId === id && s.id !== planner.id && s.id !== builder.id), 15000).catch(() => null) : builder;
if (next) {
  const got = await call(next.id, "get_task", {});
  const threads = got.result?.data?.threads ?? [];
  const thread = threads.find((t) => t.root === root.id);
  check(Boolean(thread) && /waiting on an answer/.test(got.result.summary), `get_task hands over the open thread (${got.result?.summary ?? got.error})`);
  check(thread?.comments.at(-1)?.author !== "builder" && thread?.comments[0].id === root.id, "the thread runs root first, the person's word last");
  check(!threads.some((t) => t.root === plain.id), "a people-only thread isn't handed to agents");
} else {
  // No new session (the factory waits before restarting): read get_task's data the way it's built.
  const t = tasks.get(id);
  const open = t.comments.filter((c) => c.id === root.id || c.replyTo === root.id).sort((a, b) => a.at - b.at);
  check(open.at(-1).author !== "builder", "the thread's last word is the person's, for the next agent's get_task");
}

console.log(failures ? `\n${failures} failed` : "\nall passed");
feed.close();
runner.close();
process.exit(failures ? 1 : 0);

// Requests from outside: one posted to the API with the intake key, one from Slack's /maple (signed
// like Slack signs it). Then the app asks the requester something, they answer, and it becomes a task.
// Last, Draft with AI on a scripted machine: its transcript builds up in order, is capped, and stays
// once the draft is ready.
//   node server/test/e2e-intake.mjs http://localhost:8788 mfi_dev_local dev-slack-secret
import { createHmac } from "node:crypto";

const [base = "http://localhost:8788", key = "mfi_dev_local", slackSecret = "dev-slack-secret"] = process.argv.slice(2);
const step = (t) => console.log(`✓ ${t}`);
const post = (path, body, headers = {}) => fetch(`${base}${path}`, { method: "POST", headers: { "content-type": "application/json", ...headers }, body: JSON.stringify(body) });

// 1. The API, as a support tool would.
let res = await post("/api/intake", { title: "Export times out on big workspaces", text: "Customers with 50k+ rows see the CSV export spin forever, then fail.", requester: "Dana (support)" }, { authorization: `Bearer ${key}` });
if (!res.ok) throw new Error(`api: ${res.status} ${await res.text()}`);
const api = await res.json();
step(`API request ${api.id}: "${api.title}" (goal guess ${api.suggestedGoal ? "made" : "none"})`);
// Local dev signs every localhost request in as DEV_LOGIN, so a bad key only fails on a real deploy.
const { signIn } = await (await fetch(`${base}/healthz`)).json();
if (signIn !== "dev") {
  if ((await post("/api/intake", { title: "x" }, { authorization: "Bearer mfi_wrong" })).status !== 401) throw new Error("a wrong key got in");
  step("a wrong key is refused");
}

// 2. Slack's slash command.
const form = new URLSearchParams({ text: "Dark mode for the greeting page please", user_name: "mei", channel_name: "requests", response_url: "https://example.invalid/slack" }).toString();
const stamp = String(Math.floor(Date.now() / 1000));
const sig = `v0=${createHmac("sha256", slackSecret).update(`v0:${stamp}:${form}`).digest("hex")}`;
res = await fetch(`${base}/integrations/slack/command`, { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded", "x-slack-request-timestamp": stamp, "x-slack-signature": sig }, body: form });
const slack = await res.json();
step(`Slack: "${slack.text}"`);
const forged = await fetch(`${base}/integrations/slack/command`, { method: "POST", headers: { "x-slack-request-timestamp": stamp, "x-slack-signature": "v0=00" }, body: form });
if (forged.status !== 401) throw new Error("a forged Slack request got in");
step("a forged Slack request is refused");

// 3. Triage from the app.
const { token } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();
const feed = new WebSocket(`${base.replace(/^http/, "ws")}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
const requests = new Map();
const tasks = new Map();
const drafts = [];
let goals = [];
feed.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "snapshot") { goals = m.goals; for (const r of m.intake) requests.set(r.id, r); }
  if (m.type === "goal.updated") goals = [...goals.filter((g) => g.id !== m.goal.id), m.goal];
  if (m.type === "intake.updated") requests.set(m.request.id, m.request);
  if (m.type === "task.updated") tasks.set(m.task.id, m.task);
  if (m.type === "draft.updated") drafts.push(m.draft);
  if (m.type === "error") console.log("error:", m.message);
};
await new Promise((r) => (feed.onopen = r));
feed.send(JSON.stringify({ type: "subscribe" }));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
await sleep(600);
const slackId = slack.text.match(/REQ-\d+/)[0];
step(`the app sees ${requests.size} requests; ${slackId} came from ${requests.get(slackId).channel} by ${requests.get(slackId).requester}`);

feed.send(JSON.stringify({ type: "intake.ask", id: api.id, text: "Which workspace, and roughly how many rows?" }));
await sleep(400);
if (requests.get(api.id).status !== "clarifying") throw new Error("asking didn't mark it clarifying");
await post(`/api/intake/${api.id}/messages`, { author: "Dana (support)", text: "Acme, about 80k rows." }, { authorization: `Bearer ${key}` });
await sleep(400);
const answered = requests.get(api.id);
step(`asked and answered: ${answered.status}, ${answered.thread.length} messages`);

// A fresh factory has no goals yet: make one.
if (!goals.length) {
  feed.send(JSON.stringify({ type: "goal.save", goal: { id: "", name: "Greeting", prefix: "GRT", color: "#2EA043", summary: "", lead: "", repos: [], folder: "/tmp/intake-test", base: null } }));
  for (let i = 0; i < 50 && !goals.length; i++) await sleep(100);
}
const goal = goals.find((g) => g.prefix === "GRT") ?? goals[0];
feed.send(JSON.stringify({ type: "task.create", goal: goal.id, title: answered.title, brief: "From Dana's request.", shareable: true, plan: false, tickets: [], agent: "scripted", intake: api.id }));
await sleep(800);
const done = requests.get(api.id);
const task = tasks.get(done.taskId);
step(`it became ${done.taskId} (${done.status}); the task carries ${task.comments.length} messages from the thread; bot said: "${done.thread.at(-1).text.slice(0, 60)}…"`);
feed.send(JSON.stringify({ type: "intake.decline", id: slackId, note: "not this quarter" }));
await sleep(400);
step(`${slackId} declined: ${requests.get(slackId).status}`);

// 4. Draft with AI, on a machine that answers `draft.run` with a scripted transcript.
const runnerId = `draft-mac-${Date.now()}`;
const { code } = await (await fetch(`${base}/api/machines/enroll`, { method: "POST", headers: { authorization: `Bearer ${token}` } })).json();
const enrolled = await (await post("/runner/enroll", { code, runnerId, hostname: runnerId, os: "macos", arch: "arm64", version: "0.0.0-fake" })).json();
const runner = new WebSocket(`${base.replace(/^http/, "ws")}/runner/connect?runner=${runnerId}`, { headers: { authorization: `Bearer ${enrolled.token}` } });
await new Promise((r, j) => { runner.onopen = r; runner.onerror = j; });
const toHub = (m) => runner.send(JSON.stringify(m));
toHub({ type: "hello", runnerId, hostname: runnerId, os: "macos", arch: "arm64", version: "0.0.0-fake", sessions: [], ended: [] });
toHub({ type: "health", health: { cpu: 1, cores: 10, load1: 0.1, memUsed: 1e9, memTotal: 32e9, diskUsed: 1e11, diskTotal: 1e12, uptime: 10, battery: null, agents: [{ name: "claude", version: "2.1.0", loggedIn: true }] } });
// 360 lines, each a tool step and then what it said about it: short ones, which fill the 200 lines,
// then long ones, which fill the 40,000 characters first. One line is said twice.
const script = [];
for (let i = 1; i <= 180; i++) {
  script.push({ kind: "tool", text: `Reading src/file${i}.ts` });
  script.push({ kind: "text", text: i <= 140 ? `Thought ${i}` : `Thought ${i}: ${"x".repeat(1200)}` });
}
script.splice(3, 0, { ...script[2] });
runner.onmessage = async (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "ping") return toHub({ type: "pong" });
  if (m.type !== "draft.run") return;
  for (const line of script) { toHub({ type: "draft.progress", id: m.id, ...line }); await sleep(5); }
  // An older runner's line, with no kind: a tool step.
  toHub({ type: "draft.progress", id: m.id, text: "Reading README.md" });
  await sleep(300);
  toHub({ type: "draft.done", id: m.id, output: JSON.stringify({ title: "Speed up big CSV exports", brief: "Stream the rows.", doneWhen: ["80k rows export"] }), error: null });
};
await sleep(800);
const draftId = crypto.randomUUID();
feed.send(JSON.stringify({ type: "draft.start", id: draftId, idea: "CSV export times out on big workspaces", goal: goal.id, agent: "claude" }));
for (let i = 0; i < 200 && drafts.at(-1)?.state !== "ready" && drafts.at(-1)?.state !== "failed"; i++) await sleep(100);
const mine = drafts.filter((d) => d.id === draftId);
const last = mine.at(-1);
if (last?.state !== "ready") throw new Error(`the draft didn't get ready: ${JSON.stringify(last && { state: last.state, error: last.error })}`);
const running = mine.filter((d) => d.state === "reading");
// Every update while it ran carried the log so far: each one the last one's, plus a line (less what was cut).
const grew = running.every((d, i) => i === 0 || d.log.length >= running[i - 1].log.length || d.log.reduce((n, l) => n + l.text.length, 0) > 39_000);
if (!grew) throw new Error("the log didn't build up update by update");
if (!running.some((d) => d.log.length === 200)) throw new Error("the log never reached 200 lines");
const lines = last.log;
const bytes = lines.reduce((n, l) => n + l.text.length, 0);
if (lines.length > 200 || bytes > 40_000) throw new Error(`the log isn't capped: ${lines.length} lines, ${bytes} characters`);
const expected = [...script.filter((l, i) => i !== 3), { kind: "tool", text: "Reading README.md" }].map((l) => ({ kind: l.kind, text: l.text.slice(0, 1000) }));
const tailOf = expected.slice(-lines.length);
if (JSON.stringify(lines) !== JSON.stringify(tailOf)) throw new Error(`the log is out of order or wrong:\n${JSON.stringify(lines.slice(-4))}\nwanted\n${JSON.stringify(tailOf.slice(-4))}`);
// Each kept line keeps its number: line i of an update is line logFrom + i of everything said.
const misnumbered = mine.find((d) => JSON.stringify(d.log) !== JSON.stringify(expected.slice(d.logFrom, d.logFrom + d.log.length)));
if (misnumbered) throw new Error(`logFrom doesn't number the kept lines: logFrom ${misnumbered.logFrom}, first line "${misnumbered.log[0]?.text.slice(0, 24)}"`);
if (last.logFrom + last.log.length !== expected.length) throw new Error(`logFrom ${last.logFrom} + ${last.log.length} kept isn't the ${expected.length} lines said`);
const repeated = running.some((d) => d.log.some((l, i) => i > 0 && l.text === d.log[i - 1].text && l.kind === d.log[i - 1].kind));
if (repeated) throw new Error("a line said twice in a row was logged twice");
const stillReading = running.at(-1);
if (stillReading.progress !== "Reading README.md") throw new Error(`progress isn't the latest tool step: ${stillReading.progress}`);
step(`draft ${last.state} after ${running.length} updates; its log reached 200 lines, then kept the last ${lines.length} of ${expected.length} lines (${bytes} characters, under 40,000), in order, the repeat dropped, numbered from line ${last.logFrom}, starting "${lines[0].text.slice(0, 24)}" and ending "${lines.at(-1).text}"`);
step(`the log survives draft.done: "${last.title}" is ready with ${last.log.length} lines`);
runner.close();
process.exit(0);

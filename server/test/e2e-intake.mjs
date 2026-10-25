// Requests from outside: one posted to the API with the intake key, one from Slack's /maple (signed
// like Slack signs it). Then the app asks the requester something, they answer, and it becomes a task.
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
let goals = [];
feed.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "snapshot") { goals = m.goals; for (const r of m.intake) requests.set(r.id, r); }
  if (m.type === "intake.updated") requests.set(m.request.id, m.request);
  if (m.type === "task.updated") tasks.set(m.task.id, m.task);
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

const goal = goals.find((g) => g.prefix === "GRT") ?? goals[0];
feed.send(JSON.stringify({ type: "task.create", goal: goal.id, title: answered.title, brief: "From Dana's request.", shareable: true, plan: false, tickets: [], agent: "scripted", intake: api.id }));
await sleep(800);
const done = requests.get(api.id);
const task = tasks.get(done.taskId);
step(`it became ${done.taskId} (${done.status}); the task carries ${task.comments.length} messages from the thread; bot said: "${done.thread.at(-1).text.slice(0, 60)}…"`);
feed.send(JSON.stringify({ type: "intake.decline", id: slackId, note: "not this quarter" }));
await sleep(400);
step(`${slackId} declined: ${requests.get(slackId).status}`);
process.exit(0);

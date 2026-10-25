// Requests from Linear and Jira: labelled issues come in through their webhooks, the bot's questions
// go back as comments, and the requester's comments come back into the thread.
//   node server/test/e2e-trackers.mjs http://localhost:8788
// .dev.vars needs LINEAR_WEBHOOK_SECRET=dev-linear-secret, LINEAR_API_KEY, LINEAR_API_URL=http://localhost:8799/graphql,
// JIRA_WEBHOOK_SECRET=dev-jira-secret, JIRA_SITE=http://localhost:8799, JIRA_EMAIL and JIRA_API_TOKEN.
// Port 8799 stands in for Linear's API and the Jira site, and records what the bot sends.

import { createHmac } from "node:crypto";
import http from "node:http";

const [base = "http://localhost:8788"] = process.argv.slice(2);
const step = (t) => console.log(`✓ ${t}`);
const sent = [];
const catcher = http.createServer((req, res) => {
  let body = "";
  req.on("data", (d) => (body += d));
  req.on("end", () => {
    sent.push({ path: req.url, auth: req.headers.authorization, body: JSON.parse(body || "{}") });
    res.setHeader("content-type", "application/json");
    res.end(req.url === "/graphql" ? '{"data":{"commentCreate":{"success":true}}}' : '{"id":"1"}');
  });
});
await new Promise((r) => catcher.listen(8799, r));

const { token } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();
const feed = new WebSocket(`${base.replace(/^http/, "ws")}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
const requests = new Map();
let poke = null;
feed.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "snapshot") for (const r of m.intake) requests.set(r.id, r);
  if (m.type === "intake.updated") requests.set(m.request.id, m.request);
  if (m.type === "error") console.log("error:", m.message);
  poke?.();
};
await new Promise((r) => (feed.onopen = r));
feed.send(JSON.stringify({ type: "subscribe" }));
const wait = async (what, test, ms = 10000) => {
  const deadline = Date.now() + ms;
  for (;;) {
    const hit = test();
    if (hit) return hit;
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((r) => { poke = r; setTimeout(r, 200); });
  }
};
const byTicket = (key) => [...requests.values()].find((r) => r.tickets.some((t) => t.key === key));

// ---- Linear ----
const linear = (event, secret = "dev-linear-secret") => {
  const body = JSON.stringify({ webhookTimestamp: Date.now(), ...event });
  return fetch(`${base}/integrations/linear`, { method: "POST", headers: { "content-type": "application/json", "linear-signature": createHmac("sha256", secret).update(body).digest("hex") }, body });
};
const issueId = crypto.randomUUID();
const key = `ENG-${Math.floor(Math.random() * 9000) + 1000}`;
const issue = { id: issueId, identifier: key, title: "Greeting should use the person's name", description: "Right now it says hello to everyone the same way.", url: `https://linear.app/acme/issue/${key}`, state: { name: "Todo" } };

if ((await linear({ action: "create", type: "Issue", data: { ...issue, labels: [{ id: "l1", name: "maple" }] } }, "wrong")).status !== 401) throw new Error("a forged Linear webhook got in");
step("a forged Linear webhook is refused");
await linear({ action: "create", type: "Issue", data: { ...issue, labels: [] }, actor: { name: "Ines" } });
await new Promise((r) => setTimeout(r, 500));
if (byTicket(key)) throw new Error("an unlabelled issue became a request");
step("an issue without the label stays in Linear");

await linear({ action: "update", type: "Issue", data: { ...issue, labels: [{ id: "l1", name: "maple" }] }, updatedFrom: { labelIds: [] }, actor: { name: "Ines" } });
const lin = await wait("Linear request", () => byTicket(key));
step(`labelling ${key} made ${lin.id} from ${lin.requester}: "${lin.title}"`);
await linear({ action: "update", type: "Issue", data: { ...issue, labels: [{ id: "l1", name: "maple" }] }, updatedFrom: { labelIds: [] }, actor: { name: "Ines" } });
await new Promise((r) => setTimeout(r, 500));
if ([...requests.values()].filter((r) => r.tickets.some((t) => t.key === key)).length !== 1) throw new Error("labelling it again made a second request");
step("labelling it again doesn't make another");

feed.send(JSON.stringify({ type: "intake.ask", id: lin.id, text: "Their first name, or the name on their profile?" }));
const comment = await wait("a Linear comment", () => sent.find((s) => s.path === "/graphql"));
if (comment.body.variables.input.issueId !== issueId || !comment.body.variables.input.body.startsWith("Maple · ")) throw new Error(`sent ${JSON.stringify(comment.body)}`);
step(`the question went to ${key} as a comment: "${comment.body.variables.input.body}"`);

await linear({ action: "create", type: "Comment", data: { body: comment.body.variables.input.body, issueId, user: { name: "Maple bot" } } });
await linear({ action: "create", type: "Comment", data: { body: "The profile name, please.", issueId, user: { name: "Ines" } } });
const answered = await wait("the answer", () => requests.get(lin.id)?.thread.some((m) => m.text === "The profile name, please.") && requests.get(lin.id));
if (answered.thread.filter((m) => m.bot).length !== 1) throw new Error("the bot's own comment came back as a message");
step(`Ines's comment is in the thread (status ${answered.status}); the bot's own wasn't echoed`);

// ---- Jira ----
const jira = (event, secret = "dev-jira-secret") =>
  fetch(`${base}/integrations/jira?secret=${secret}`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(event) });
const jkey = `OPS-${Math.floor(Math.random() * 9000) + 1000}`;
const jissue = { key: jkey, self: `http://localhost:8799/rest/api/2/issue/1${jkey.slice(4)}`, fields: { summary: "Greeting page is slow on first load", description: "Takes 4s on a cold start.", labels: ["maple"], status: { name: "To Do" } } };
if ((await jira({ webhookEvent: "jira:issue_created", issue: jissue }, "wrong")).status !== 401) throw new Error("a Jira webhook with the wrong secret got in");
step("a Jira webhook with the wrong secret is refused");
const elsewhere = await jira({ webhookEvent: "jira:issue_created", issue: { ...jissue, self: "https://evil.example/rest/api/2/issue/1" }, user: { displayName: "Ola" } });
if (elsewhere.status !== 400) throw new Error("an issue from another site got in");
step("an issue from another Jira site is refused");
await jira({ webhookEvent: "jira:issue_created", issue: jissue, user: { displayName: "Ola" } });
const jr = await wait("Jira request", () => byTicket(jkey));
step(`${jkey} made ${jr.id} from ${jr.requester}`);
feed.send(JSON.stringify({ type: "intake.ask", id: jr.id, text: "Which browser?" }));
const jc = await wait("a Jira comment", () => sent.find((s) => s.path === `/rest/api/2/issue/${jkey}/comment`));
if (!jc.auth?.startsWith("Basic ") || !jc.body.body.startsWith("Maple · ")) throw new Error(`sent ${JSON.stringify(jc)}`);
step(`the question went to ${jkey} as a comment`);
await jira({ webhookEvent: "comment_created", issue: jissue, comment: { body: "Safari 19.", author: { displayName: "Ola" } } });
await wait("the Jira answer", () => requests.get(jr.id)?.thread.some((m) => m.text === "Safari 19."));
step("Ola's comment is in the thread");

feed.send(JSON.stringify({ type: "intake.decline", id: lin.id, note: "test" }));
feed.send(JSON.stringify({ type: "intake.decline", id: jr.id, note: "test" }));
await wait("declined", () => requests.get(lin.id)?.status === "declined" && requests.get(jr.id)?.status === "declined");
step("declined both (the declines went back as comments too)");
catcher.close();
process.exit(0);

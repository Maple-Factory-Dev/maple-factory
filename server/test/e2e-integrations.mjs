// Integrations set up in Settings (MF-142), on a factory with no LINEAR_* env vars:
//   node server/test/e2e-integrations.mjs http://localhost:8788
// .dev.vars needs DEV_LOGIN, and LINEAR_API_URL=http://localhost:8797/graphql (this script stands in for
// Linear's API there), but no LINEAR_WEBHOOK_SECRET or LINEAR_API_KEY.
// Linear starts Not set up (its webhook 404s). A member's integrations.save is refused; the admin's goes
// through, and its broadcast carries no secret. A signed webhook then makes a request, the bot's comment
// goes out with the stored API key, and the status shows lastEventAt; a bad signature records lastError,
// and the next good one clears it. Saving again with the secrets blank keeps them. A fresh snapshot
// carries no secret either, and nothing any app was sent ever did.

import { createHmac } from "node:crypto";
import http from "node:http";

const [base = "http://localhost:8788"] = process.argv.slice(2);
const ws = base.replace(/^http/, "ws");
const run = Date.now() % 100000;
const SECRET = `whsec-e2e-${run}-do-not-leak`;
const API_KEY = `lin_api_e2e_${run}_do_not_leak`;
let failures = 0;
const check = (ok, what) => { console.log(`${ok ? "ok  " : "FAIL"} ${what}`); if (!ok) failures++; };
const wait = async (what, test, ms = 10000) => {
  const deadline = Date.now() + ms;
  for (;;) {
    const hit = test();
    if (hit) return hit;
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 100));
  }
};

const comments = [];
const linearApi = http.createServer((req, res) => {
  let body = "";
  req.on("data", (d) => (body += d));
  req.on("end", () => {
    comments.push({ auth: req.headers.authorization, body: JSON.parse(body || "{}") });
    res.setHeader("content-type", "application/json");
    res.end('{"data":{"commentCreate":{"success":true}}}');
  });
});
await new Promise((r) => linearApi.listen(8797, r));

const connect = async (as) => {
  const { token } = await (await fetch(`${base}/dev/token${as ? `?as=${as}` : ""}`, { method: "POST" })).json();
  const feed = new WebSocket(`${ws}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
  const app = { raw: [], seen: [], errors: [], requests: new Map() };
  feed.onmessage = (e) => {
    app.raw.push(e.data);
    const m = JSON.parse(e.data);
    app.seen.push(m);
    if (m.type === "snapshot") { app.integrations = m.integrations; for (const r of m.intake) app.requests.set(r.id, r); }
    if (m.type === "integrations.updated") app.integrations = m.integrations;
    if (m.type === "intake.updated") app.requests.set(m.request.id, m.request);
    if (m.type === "error") app.errors.push(m.message);
  };
  app.send = (m) => feed.send(JSON.stringify(m));
  app.linear = () => app.integrations?.find((i) => i.kind === "linear");
  app.close = () => feed.close();
  await new Promise((r) => (feed.onopen = r));
  app.send({ type: "subscribe" });
  await wait("snapshot", () => app.integrations);
  return app;
};

const sign = (body) => createHmac("sha256", SECRET).update(body).digest("hex");
const webhook = (event, signature) => {
  const body = JSON.stringify({ ...event, webhookTimestamp: Date.now() });
  return fetch(`${base}/integrations/linear`, { method: "POST", headers: { "content-type": "application/json", "linear-signature": signature ?? sign(body) }, body });
};
const issue = (n) => ({
  action: "create",
  type: "Issue",
  actor: { name: "Priya" },
  data: { id: `e2e-int-${run}-${n}`, identifier: `INT-${run}${n}`, title: `Integrations e2e ${run} #${n}`, description: "From Settings, not env vars.", url: "https://linear.app/x", labels: [{ id: "l1", name: "Triage" }], state: { name: "Todo" } },
});

const admin = await connect();
const member = await connect(`teammate${run}`);
check(admin.integrations.map((i) => i.kind).join() === "slack,linear,jira", "the snapshot lists Slack, Linear and Jira");
check(!admin.linear().enabled && !admin.linear().updatedBy, "Linear starts not set up (no env vars)");
check((await webhook(issue(0))).status === 404, "and its webhook answers 404 until it is");

// A member can't set it up.
member.send({ type: "integrations.save", kind: "linear", enabled: true, values: { webhookSecret: "member-secret" } });
await wait("the member's refusal", () => member.errors.length);
check(/Only admins/.test(member.errors[0]), `a member's save is refused: ${member.errors[0]}`);
check(!admin.linear().enabled, "and changed nothing");

// A save that won't do.
admin.send({ type: "integrations.save", kind: "linear", enabled: true, values: { label: "maple" } });
await wait("the admin's refusal", () => admin.errors.length);
check(/needs its webhook signing secret/.test(admin.errors[0]), `an enabled Linear needs its secret: ${admin.errors[0]}`);

// The admin sets it up.
const before = admin.seen.length;
admin.send({ type: "integrations.save", kind: "linear", enabled: true, values: { webhookSecret: SECRET, apiKey: API_KEY, label: "Triage" } });
await wait("integrations.updated", () => admin.seen.slice(before).some((m) => m.type === "integrations.updated"));
await wait("the member's integrations.updated", () => member.linear()?.enabled);
let linear = admin.linear();
check(linear.enabled && linear.updatedBy === "afomera", `Linear is on, saved by ${linear.updatedBy}`);
check(linear.values.webhookSecret === "" && linear.values.apiKey === "" && linear.values.label === "triage", `its secrets are blank, its label lowercased: ${JSON.stringify(linear.values)}`);
check(linear.webhookUrl.endsWith("/integrations/linear"), `its webhook URL: ${linear.webhookUrl}`);
check(linear.fromEnv.length === 0 && !linear.lastEventAt, "nothing from env vars, no event yet");

// A signed webhook makes a request, and the bot comments back with the stored key.
let res = await webhook(issue(1));
const created = await res.json().catch(() => null);
check(res.ok && created?.id?.startsWith("REQ-"), `a signed webhook made ${created?.id} (${res.status})`);
await wait("lastEventAt", () => admin.linear().lastEventAt);
check(Date.now() - admin.linear().lastEventAt < 30_000 && !admin.linear().lastError, "the status shows its last event, no error");
const req = await wait("the request on the app", () => admin.requests.get(created.id));
check(req.source === "linear" && req.title === issue(1).data.title, `the app has it: ${req.title} from ${req.source}`);

// The bot's reply goes to Linear with the API key from Settings.
admin.send({ type: "intake.ask", id: created.id, text: "Which workspace?" });
const comment = await wait("the bot's comment", () => comments.find((c) => c.body.variables?.input?.issueId === issue(1).data.id));
check(comment.auth === API_KEY, "the bot's comment went out with the stored API key");

// A bad signature: refused, and the status says so.
res = await webhook(issue(2), "0".repeat(64));
check(res.status === 401, "a bad signature is refused");
await wait("lastError", () => admin.linear().lastError);
check(/bad signature/.test(admin.linear().lastError), `lastError: ${admin.linear().lastError}`);
res = await webhook({ action: "update", type: "Issue", data: { id: "x" } });
await wait("the error cleared", () => !admin.linear().lastError);
check(res.status === 204, "the next good webhook clears it");

// Saving with the secrets blank keeps them.
admin.send({ type: "integrations.save", kind: "linear", enabled: true, values: { webhookSecret: "", apiKey: "", label: "triage" } });
await new Promise((r) => setTimeout(r, 500));
res = await webhook(issue(3));
check(res.ok, `after a save with the secrets blank, a webhook signed with the stored one still gets in (${res.status})`);

// Turned off: 404, as with nothing set up.
admin.send({ type: "integrations.save", kind: "linear", enabled: false, values: {} });
await wait("Linear off", () => !admin.linear().enabled);
check((await webhook(issue(4))).status === 404, "turned off, its webhook answers 404");
admin.send({ type: "integrations.save", kind: "linear", enabled: true, values: {} });
await wait("Linear on", () => admin.linear().enabled);

// A fresh snapshot, and everything any app was sent: no secret anywhere.
const late = await connect();
check(late.linear().enabled && late.linear().values.webhookSecret === "", "a fresh snapshot shows Linear set up, its secret blank");
const leaked = [admin, member, late].flatMap((a) => a.raw).filter((m) => m.includes(SECRET) || m.includes(API_KEY));
check(leaked.length === 0, `no message to any app carried the secret or API key (${[admin, member, late].reduce((n, a) => n + a.raw.length, 0)} messages)`);

for (const a of [admin, member, late]) a.close();
linearApi.close();
console.log(failures ? `${failures} failed` : "all passed");
process.exit(failures ? 1 : 0);

// The org hub watching githubstatus.com, against `wrangler dev` started with GITHUB_STATUS_URL pointing at
// the fake summary.json this test serves on <status port>:
//   npx wrangler dev --port 8788 --var GITHUB_STATUS_URL:http://127.0.0.1:8799/summary.json
//   node server/test/e2e-github-status.mjs http://localhost:8788 8799
// Checks: with no app connected the alarm reads nothing; once an app connects, a due check reads the fake and
// broadcasts github.status with its incident (the next snapshot has it too); another read with nothing changed
// broadcasts nothing, and a check that isn't due yet reads nothing; a read that fails (503, or not JSON) keeps
// the incident; the incident resolving broadcasts github.status with no status. After the apps leave, nothing is read.

import { createServer } from "node:http";

const [base = "http://localhost:8788", statusPort = "8799"] = process.argv.slice(2);
const ws = base.replace(/^http/, "ws");
const { token } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();
const auth = { authorization: `Bearer ${token}` };

const wait = async (what, test, ms = 10000) => {
  const deadline = Date.now() + ms;
  for (;;) {
    const hit = test();
    if (hit) return hit;
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 100));
  }
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const step = (text) => console.log(`✓ ${text}`);
const alarm = (stale = true) => fetch(`${base}/dev/alarm${stale ? "?stale" : ""}`, { method: "POST" }).then((r) => r.json());

// The fake githubstatus.com: `reply` is what summary.json says next, and every read is counted.
const operational = { status: { indicator: "none", description: "All Systems Operational" }, components: [{ name: "Git Operations", status: "operational" }], incidents: [] };
const incident = {
  status: { indicator: "minor", description: "Partial System Outage" },
  components: [{ name: "Git Operations", status: "operational" }, { name: "Pull Requests", status: "degraded_performance" }],
  incidents: [{ id: "e2e1", name: "Disruption with pull requests", status: "investigating", created_at: new Date().toISOString() }],
};
let reply = incident;
let reads = 0;
const fake = createServer((req, res) => {
  reads++;
  if (reply === 503) { res.statusCode = 503; return res.end(); }
  if (reply === "html") return res.end("<html>down for maintenance</html>");
  res.setHeader("content-type", "application/json");
  res.end(JSON.stringify(reply));
});
await new Promise((r) => fake.listen(Number(statusPort), "127.0.0.1", r));

const connectApp = async () => {
  const sock = new WebSocket(`${ws}/client/connect`, { headers: auth });
  const app = { sock, snapshot: null, statuses: [] };
  sock.onmessage = (e) => {
    const m = JSON.parse(e.data);
    if (m.type === "snapshot") app.snapshot = m;
    if (m.type === "github.status") app.statuses.push(m.status ?? null);
  };
  await new Promise((r) => (sock.onopen = r));
  sock.send(JSON.stringify({ type: "subscribe" }));
  await wait("snapshot", () => app.snapshot);
  return app;
};

try {
  await alarm();
  await sleep(300);
  if (reads) throw new Error(`the alarm read githubstatus ${reads} time(s) with no app connected`);
  step("no app connected: the alarm doesn't read githubstatus.com");

  const app = await connectApp();
  await alarm();
  const status = await wait("github.status with the incident", () => app.statuses.find((s) => s?.incidents?.length));
  if (status.indicator !== "minor" || status.incidents[0].name !== "Disruption with pull requests" || status.incidents[0].url !== "https://www.githubstatus.com/incidents/e2e1")
    throw new Error(`github.status said ${JSON.stringify(status)}`);
  if (JSON.stringify(status.components) !== JSON.stringify(["Pull Requests"])) throw new Error(`components ${JSON.stringify(status.components)}`);
  const fresh = await connectApp();
  if (fresh.snapshot.githubStatus?.incidents?.[0]?.name !== "Disruption with pull requests") throw new Error(`a fresh snapshot has ${JSON.stringify(fresh.snapshot.githubStatus)}`);
  fresh.sock.close();
  step(`an incident → github.status "${status.incidents[0].name}" (${status.components.join(", ")}), and in a fresh snapshot`);

  const broadcasts = app.statuses.length;
  let before = reads;
  await alarm();
  await sleep(500);
  if (reads === before) throw new Error("a due check didn't read githubstatus.com");
  if (app.statuses.length !== broadcasts) throw new Error(`nothing changed but github.status came again: ${JSON.stringify(app.statuses.at(-1))}`);
  before = reads;
  await alarm(false);
  await sleep(300);
  if (reads !== before) throw new Error("a check that wasn't due (5 minutes) read githubstatus.com");
  step("nothing changed → no second broadcast; a check before 5 minutes reads nothing");

  for (const broken of [503, "html"]) {
    reply = broken;
    before = reads;
    await alarm();
    await wait(`the ${broken} read`, () => reads > before);
    await sleep(300);
    if (app.statuses.length !== broadcasts) throw new Error(`a failed read (${broken}) broadcast ${JSON.stringify(app.statuses.at(-1))}`);
  }
  const kept = await connectApp();
  if (!kept.snapshot.githubStatus?.incidents?.length) throw new Error(`after failed reads the snapshot has ${JSON.stringify(kept.snapshot.githubStatus)}`);
  kept.sock.close();
  step("a failed read (503, not JSON) keeps the last known status");

  reply = operational;
  await alarm();
  await wait("github.status clearing", () => app.statuses.length > broadcasts && app.statuses.at(-1) === null);
  const cleared = await connectApp();
  if (cleared.snapshot.githubStatus != null) throw new Error(`a cleared snapshot has ${JSON.stringify(cleared.snapshot.githubStatus)}`);
  cleared.sock.close();
  step("the incident resolves → github.status with no status, and the snapshot has none");

  app.sock.close();
  await sleep(1000);
  before = reads;
  await alarm();
  await sleep(300);
  if (reads !== before) throw new Error("the alarm read githubstatus.com after the apps left");
  step("after the apps leave: no read");
  console.log("ok");
} finally {
  fake.close();
}
process.exit(0);

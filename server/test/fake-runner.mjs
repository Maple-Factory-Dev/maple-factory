// A runner that only talks: enrolls as <id>, says hello, reports plan usage, and stays connected
// for <seconds>, answering pings. For trying server paths without a real machine:
//   node server/test/fake-runner.mjs http://localhost:8788 <id> <seconds> [usedPercent]
const [base = "http://localhost:8788", id = "fake-mac", seconds = "20", used = "86"] = process.argv.slice(2);
const { token: app } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();
const auth = { authorization: `Bearer ${app}` };
const { code } = await (await fetch(`${base}/api/machines/enroll`, { method: "POST", headers: auth })).json();
const enrolled = await (await fetch(`${base}/runner/enroll`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ code, runnerId: id, hostname: id, os: "macos", arch: "arm64", version: "0.0.0-fake" }),
})).json();
const ws = new WebSocket(`${base.replace(/^http/, "ws")}/runner/connect?runner=${id}`, { headers: { authorization: `Bearer ${enrolled.token}` } });
await new Promise((r, j) => { ws.onopen = r; ws.onerror = j; });
const send = (m) => ws.send(JSON.stringify(m));
send({ type: "hello", runnerId: id, hostname: id, os: "macos", arch: "arm64", version: "0.0.0-fake", sessions: [], ended: [] });
const health = { cpu: 12, cores: 10, load1: 1.2, memUsed: 8e9, memTotal: 32e9, diskUsed: 2e11, diskTotal: 1e12, uptime: 1000, battery: null, agents: [{ name: "claude", version: "2.1.0", loggedIn: true }] };
send({ type: "health", health });
const now = Date.now();
send({
  type: "usage",
  agents: [{
    agent: "claude", plan: "max", observedAt: now, source: "statusline",
    account: { id: "org-fake", email: "someone@example.com", name: "Fake Org" },
    windows: [
      { label: "5h", usedPercent: Number(used), windowMinutes: 300, resetsAt: now + 2 * 3600e3 },
      { label: "7d", usedPercent: 41, windowMinutes: 10080, resetsAt: now + 3 * 86400e3 },
    ],
  }],
});
console.log(`${id} connected`);
setTimeout(() => process.exit(0), Number(seconds) * 1000);

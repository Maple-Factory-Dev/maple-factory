// A runner update's state on its machine, against `wrangler dev` and a talking-only runner enrolled here
// (like test/fake-runner.mjs) that plays the update itself:
//   node server/test/e2e-runner-update.mjs http://localhost:8788
// Checks: the snapshot carries runnerReleases; runner.check reads the feed past its cache and answers with
// runner.released and a toast, leaving the machine's update alone and sending the runner nothing; machine.update puts the machine at checking; the runner's
// update.status notices move it to installing (with the version) and restarting, and it stays restarting
// while the runner is offline; reconnecting on that version marks it updated, in a fresh snapshot too.
// A second update that fails shows failed with the runner's reason (and a toast), and up_to_date shows as upToDate.
// Then a newer runner is published to the bucket and the hub's alarm fires (its hourly check due): the app gets
// runner.released with that version and its notes, and the alarm is set again no more than an hour ahead.

const [base = "http://localhost:8788"] = process.argv.slice(2);
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
const step = (text) => console.log(`✓ ${text}`);
const publish = (path, body) => fetch(`${base}/dev/releases/${path}`, { method: "PUT", body: JSON.stringify(body) });

// The runner: says hello on `version`, and records what the hub asks of it.
const runnerId = `update-${Date.now() % 100000}`;
const { code } = await (await fetch(`${base}/api/machines/enroll`, { method: "POST", headers: auth })).json();
const enrolled = await (await fetch(`${base}/runner/enroll`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ code, runnerId, hostname: runnerId, os: "macos", arch: "arm64", version: "0.1.0" }),
})).json();
const asked = [];
const connectRunner = async (version) => {
  const runner = new WebSocket(`${ws}/runner/connect?runner=${runnerId}`, { headers: { authorization: `Bearer ${enrolled.token}` } });
  await new Promise((r, j) => { runner.onopen = r; runner.onerror = j; });
  runner.onmessage = (e) => {
    if (typeof e.data !== "string") return;
    const m = JSON.parse(e.data);
    if (m.type === "runner.update") asked.push(m);
    if (m.type === "ping") runner.send(JSON.stringify({ type: "pong" }));
  };
  runner.send(JSON.stringify({ type: "hello", runnerId, hostname: runnerId, os: "macos", arch: "arm64", version, sessions: [], ended: [] }));
  return { status: (state, v = null, message = null) => runner.send(JSON.stringify({ type: "update.status", state, version: v, message })), close: () => runner.close() };
};

// The app: the machine as it's last been told, and the toasts.
const connectApp = async () => {
  const sock = new WebSocket(`${ws}/client/connect`, { headers: auth });
  const app = { sock, snapshot: null, machine: null, history: [], toasts: [], released: [] };
  sock.onmessage = (e) => {
    const m = JSON.parse(e.data);
    if (m.type === "snapshot") { app.snapshot = m; app.machine = m.machines.find((x) => x.id === runnerId) ?? null; }
    if (m.type === "machine.updated" && m.machine.id === runnerId) {
      app.machine = m.machine;
      if (m.machine.update && app.history.at(-1) !== m.machine.update.state) app.history.push(m.machine.update.state);
    }
    if (m.type === "toast") app.toasts.push(m.text);
    if (m.type === "runner.released") app.released.push(m);
  };
  await new Promise((r) => (sock.onopen = r));
  sock.send(JSON.stringify({ type: "subscribe" }));
  await wait("snapshot", () => app.snapshot);
  return app;
};

let runner = await connectRunner("0.1.0");
const app = await connectApp();
await wait("the machine online", () => app.machine?.online && app.machine.version === "0.1.0");
if (!Array.isArray(app.snapshot.runnerReleases)) throw new Error(`snapshot.runnerReleases is ${JSON.stringify(app.snapshot.runnerReleases)}`);
step(`snapshot has runnerReleases (${app.snapshot.runnerReleases.length}${app.snapshot.runnerReleases[0] ? `, newest ${app.snapshot.runnerReleases[0].version}` : ""})`);

// A check only looks: a newer release comes back as runner.released and a toast, and nothing installs.
const available = `8.${Date.now() % 100000}.0`;
await publish("maple-runner/latest.json", { version: available });
await publish("maple-runner/changes.json", { releases: [{ version: available, publishedAt: new Date().toISOString(), notes: "- A checked release." }] });
app.sock.send(JSON.stringify({ type: "runner.check", machine: runnerId }));
await wait("runner.released from the check", () => app.released.find((m) => m.runnerLatest === available));
const offered = await wait("the check's toast", () => app.toasts.find((t) => t.includes(available)));
if (offered !== `Runner ${available} is available for ${app.machine.name}.`) throw new Error(`the check toasted "${offered}"`);
step(`runner.check → runner.released ${available} past the cache, and "${offered}"`);
await publish("maple-runner/latest.json", { version: "0.1.0" });
app.sock.send(JSON.stringify({ type: "runner.check", machine: runnerId }));
const current = await wait("the up-to-date toast", () => app.toasts.find((t) => t.includes("latest runner")));
if (current !== `${app.machine.name} is on the latest runner (0.1.0).`) throw new Error(`the check toasted "${current}"`);
step(`runner.check on the latest → "${current}"`);
await new Promise((r) => setTimeout(r, 500));
if (app.machine.update != null) throw new Error(`a check set the machine's update to ${JSON.stringify(app.machine.update)}`);
if (asked.length) throw new Error(`a check sent the runner ${asked.length} runner.update`);
step("a check leaves the machine's update null and sends the runner no runner.update");
app.toasts.length = 0;

app.sock.send(JSON.stringify({ type: "machine.update", machine: runnerId }));
await wait("runner.update reaching the runner", () => asked.length === 1);
await wait("checking", () => app.machine.update?.state === "checking");
step("machine.update → checking");

runner.status("checking");
runner.status("installing", "0.2.0");
await wait("installing", () => app.machine.update?.state === "installing" && app.machine.update.target === "0.2.0");
step("update.status installing → installing 0.2.0");

runner.status("updating", "0.2.0", "installed 0.2.0; restarting");
await wait("restarting", () => app.machine.update?.state === "restarting");
runner.close();
await wait("offline", () => !app.machine.online);
if (app.machine.update?.state !== "restarting") throw new Error(`offline mid-update shows ${app.machine.update?.state}`);
step("update.status updating → restarting, and still restarting while it's offline");

runner = await connectRunner("0.2.0");
await wait("updated", () => app.machine.online && app.machine.update?.state === "updated");
if (app.machine.version !== "0.2.0" || app.machine.update.target !== "0.2.0") throw new Error(`updated on ${app.machine.version}, target ${app.machine.update.target}`);
const fresh = await connectApp();
if (fresh.machine?.update?.state !== "updated") throw new Error(`a fresh snapshot shows ${fresh.machine?.update?.state}`);
step(`reconnecting on 0.2.0 → updated (${app.history.join(" → ")}), in a fresh snapshot too`);
if (app.toasts.length) throw new Error(`toasts for a good update: ${app.toasts.join(" | ")}`);
step("no toast for an update that worked");

app.sock.send(JSON.stringify({ type: "machine.update", machine: runnerId }));
await wait("the second runner.update", () => asked.length === 2);
runner.status("failed", "0.3.0", "installing 0.3.0: checksum mismatch");
await wait("failed", () => app.machine.update?.state === "failed");
if (app.machine.update.message !== "installing 0.3.0: checksum mismatch") throw new Error(`failed with ${app.machine.update.message}`);
await wait("a failure toast", () => app.toasts.some((t) => t.includes("checksum mismatch")));
step(`a failed update → failed: "${app.machine.update.message}", and a toast`);

app.sock.send(JSON.stringify({ type: "machine.update", machine: runnerId }));
await wait("the third runner.update", () => asked.length === 3);
runner.status("up_to_date", "0.2.0", "maple-runner 0.2.0 is up to date");
await wait("upToDate", () => app.machine.update?.state === "upToDate");
step("up_to_date → upToDate");

const newer = `9.${Date.now() % 100000}.0`;
await publish("maple-runner/latest.json", { version: newer });
await publish("maple-runner/changes.json", { releases: [{ version: newer, publishedAt: new Date().toISOString(), notes: "- A test release." }] });
const fired = await (await fetch(`${base}/dev/alarm?stale`, { method: "POST" })).json();
const released = await wait("runner.released", () => app.released.find((m) => m.runnerLatest === newer));
if (released.runnerReleases[0]?.version !== newer || released.runnerReleases[0].notes !== "- A test release.") throw new Error(`runner.released carried ${JSON.stringify(released.runnerReleases)}`);
step(`a newer runner published and the alarm fired → runner.released ${released.runnerLatest} with its notes`);
const ahead = fired.alarm - fired.now;
if (fired.alarm == null || ahead > 3_600_000) throw new Error(`the alarm is set ${fired.alarm == null ? "never" : `${ahead}ms ahead`}`);
step(`the alarm is set again ${Math.round(ahead / 60000)} min ahead (no more than an hour)`);

const before = app.released.length;
await fetch(`${base}/dev/alarm`, { method: "POST" });
await new Promise((r) => setTimeout(r, 500));
if (app.released.length !== before) throw new Error("runner.released again within the hour");
step("no runner.released again until the hour's up");

runner.close();
process.exit(0);

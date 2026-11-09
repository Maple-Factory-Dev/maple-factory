// Smoke check for maple-server under celld (server/celld.jsonc, `npm run celld`), from the MF-372 spike.
//   node server/celld/probe.mjs [http://localhost:8788]
// Needs DEV_LOGIN in server/.dev.vars (it signs in through /dev/token). Set CELLD_PROBE_HIBERNATION=1, and
// start celld with CELLD_IDLE_EVICT_S=5, to also check a MachineHub hibernating and waking.
import crypto from "node:crypto";

const [base = "http://localhost:8788"] = process.argv.slice(2);
const wsBase = base.replace(/^http/, "ws");
const results = [];
const report = (item, verdict, why) => { results.push([item, verdict, why]); console.log(`${verdict.padEnd(7)} ${item}: ${why}`); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const check = async (item, fn) => { try { await fn(); } catch (e) { report(item, "FAIL", String(e?.message ?? e)); } };

const { token } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();
const auth = { authorization: `Bearer ${token}` };

await check("healthz", async () => {
  const r = await fetch(`${base}/healthz`);
  const j = await r.json();
  report("healthz", r.status === 200 && j.ok ? "PASS" : "FAIL", `${r.status} version=${j.version} signIn=${j.signIn}`);
});

await check("assets auto-trailing-slash", async () => {
  const a = await fetch(`${base}/app`, { redirect: "manual" });
  const b = await fetch(`${base}/app/`);
  const c = await fetch(`${base}/app/app.css`);
  const body = await b.text();
  const ok = a.status === 307 && a.headers.get("location")?.endsWith("/app/") && c.status === 200;
  const served = b.status === 200 && /<html/i.test(body);
  report("assets auto-trailing-slash", ok && served ? "PASS" : ok ? "PARTIAL" : "FAIL",
    `/app -> ${a.status} ${a.headers.get("location")}; /app/ -> ${b.status} ${served ? "index.html" : JSON.stringify(body.slice(0, 40))}; /app/app.css -> ${c.status}`);
});

await check("D1 read/write", async () => {
  const me = await (await fetch(`${base}/api/me`, { headers: auth })).json();
  const r = await fetch(`${base}/api/name`, { method: "PUT", headers: { ...auth, "content-type": "application/json", origin: base }, body: JSON.stringify({ name: "celld probe" }) });
  const enroll = await fetch(`${base}/api/machines/enroll`, { method: "POST", headers: { ...auth, origin: base } });
  report("D1 read/write", me.member?.login && enroll.status === 200 ? "PASS" : "FAIL", `/api/me login=${me.member?.login} role=${me.member?.role}; PUT /api/name ${r.status}; enroll code insert ${enroll.status}`);
});

await check("R2 put/get", async () => {
  const body = `celld r2 probe ${Date.now()}`;
  const up = await fetch(`${base}/api/attachments?name=probe.txt`, { method: "POST", headers: { ...auth, origin: base, "content-type": "text/plain" }, body });
  const j = await up.json();
  const got = await fetch(`${base}${j.path}`, { headers: auth });
  const text = await got.text();
  const rel = await fetch(`${base}/releases/stable/does-not-exist.txt`);
  report("R2 put/get", up.status === 201 && text === body ? "PASS" : "FAIL", `RELEASES.put via /api/attachments ${up.status}; get ${got.status} match=${text === body}; /releases/ miss -> ${rel.status}`);
});

// A fake runner and a viewer on one MachineHub: auto-response, attachments, hibernation.
if (process.env.CELLD_PROBE_HIBERNATION) await check("hibernation WS + auto-response + attachments", async () => {
  const { code } = await (await fetch(`${base}/api/machines/enroll`, { method: "POST", headers: { ...auth, origin: base } })).json();
  const id = `celld-probe-${Date.now().toString(36)}`;
  const en = await fetch(`${base}/runner/enroll`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ code, runnerId: id, hostname: id, os: "macos", arch: "aarch64", version: "0.0.0" }) });
  const enj = await en.json();
  const runnerToken = enj.token;
  if (!runnerToken) throw new Error(`enroll ${en.status} ${JSON.stringify(enj)}`);
  const runner = new WebSocket(`${wsBase}/runner/connect?runner=${id}`, { headers: { authorization: `Bearer ${runnerToken}` } });
  runner.binaryType = "arraybuffer";
  const fromHub = [];
  runner.onmessage = (e) => fromHub.push(e.data);
  await new Promise((ok, no) => { runner.onopen = ok; runner.onerror = () => no(new Error("runner socket failed")); });
  runner.send(JSON.stringify({ type: "hello", runnerId: id, hostname: id, os: "macos", arch: "aarch64", version: "0.0.0", sessions: [], ended: [] }));
  await sleep(500);
  const pong = () => new Promise((ok) => { const n = fromHub.length; runner.send("ping"); const t = setInterval(() => { if (fromHub.slice(n).includes("pong")) { clearInterval(t); ok(true); } }, 50); setTimeout(() => { clearInterval(t); ok(false); }, 3000); });
  const pong1 = await pong();

  const session = crypto.randomUUID();
  const viewer = new WebSocket(`${wsBase}/client/terminal?machine=${id}&session=${session}`, { headers: auth });
  viewer.binaryType = "arraybuffer";
  const toViewer = [];
  viewer.onmessage = (e) => toViewer.push(Buffer.from(e.data).toString());
  await new Promise((ok, no) => { viewer.onopen = ok; viewer.onerror = () => no(new Error("viewer socket failed")); });
  await sleep(500);
  const replay = fromHub.map((m) => { try { return JSON.parse(m); } catch { return null; } }).find((m) => m?.type === "session.replay" && m.id === session);
  if (!replay) throw new Error(`no session.replay reached the runner (pong=${pong1}; hub sent ${JSON.stringify(fromHub.map((m) => String(m).slice(0, 80)))}; viewer state=${viewer.readyState} got ${JSON.stringify(toViewer)})`);
  runner.send(JSON.stringify({ type: "session.replay", id: session, nonce: replay.nonce, data: Buffer.from("replayed\r\n").toString("base64") }));
  await sleep(500);
  const ready = toViewer.includes("replayed\r\n");

  const evict = Number(process.env.CELLD_IDLE_EVICT_S ?? 5);
  console.log(`        … idle ${evict + 5}s so celld can hibernate the MachineHub (CELLD_IDLE_EVICT_S=${evict})`);
  await sleep((evict + 5) * 1000);
  const pong2 = await pong();
  await sleep((evict + 5) * 1000);
  const frame = Buffer.concat([Buffer.from(session.replace(/-/g, ""), "hex"), Buffer.from("after hibernation")]);
  runner.send(frame);
  await sleep(1000);
  const routed = toViewer.includes("after hibernation");
  const open = runner.readyState === 1 && viewer.readyState === 1;
  runner.close(); viewer.close();
  const verdict = pong1 && pong2 && ready && routed && open ? "PASS" : (pong1 || ready) ? "PARTIAL" : "FAIL";
  report("hibernation WS + auto-response + attachments", verdict,
    `ping->pong before=${pong1} after-idle=${pong2}; viewer ready via serializeAttachment=${ready}; output routed after idle (deserializeAttachment().ready)=${routed}; sockets open=${open}; runner=${id}`);
  globalThis.probeRunner = id;
});

console.log("\n| item | verdict | detail |\n| --- | --- | --- |");
for (const [i, v, w] of results) console.log(`| ${i} | ${v} | ${w.replace(/\|/g, "\\|")} |`);
process.exit(results.some(([, v]) => v === "FAIL") ? 1 : 0);

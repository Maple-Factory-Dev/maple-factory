// Task artifacts (MF-205), with this script as the runner:
//   node server/test/e2e-artifacts.mjs http://localhost:8788 [chart.html] [screenshot.png]
// Enrolls a runner, makes a goal and a task, answers the planner's session with a plan, and in the
// builder's session does what runner/src/proof.rs `prepare_artifact` does: PUTs each file to
// /runner/artifact/<task> with the runner's token and calls `share_artifact` with the key.
// Checks: the uploads answer {key, type, bytes}; the task feed carries both artifacts with their kind,
// file and version; sharing again under the same title bumps the version instead of adding one; a
// member GETs the bytes back, the HTML only ever as a sandboxed download; a wrong or missing runner
// token gets 401, a 12 MB file 413 and a binary blob 415; and a key that isn't an attachment's is
// refused. The task is left building with its artifacts, to look at in the apps.

import { randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { basename } from "node:path";

const [base = "http://localhost:8788", htmlPath, pngPath] = process.argv.slice(2);
const ws = base.replace(/^http/, "ws");
let failures = 0;
const check = (ok, what) => { console.log(`${ok ? "ok  " : "FAIL"} ${what}`); if (!ok) failures++; };

const html = htmlPath ? readFileSync(htmlPath) : Buffer.from(`<!doctype html><html><body><canvas id="c" width="300" height="120"></canvas>
<script>const x = document.getElementById("c").getContext("2d"); [40, 70, 55, 90].forEach((h, i) => { x.fillStyle = "#14A866"; x.fillRect(20 + i * 60, 120 - h, 40, h); });</script></body></html>`);
const png = pngPath ? readFileSync(pngPath) : Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), randomBytes(40_000)]);
const htmlName = htmlPath ? basename(htmlPath) : "latency-chart.html";
const pngName = pngPath ? basename(pngPath) : "before-after.png";

const { token } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();
const member = { authorization: `Bearer ${token}` };

// The runner: enrolled with the member's code, connected, with an agent of its own.
const { code } = await (await fetch(`${base}/api/machines/enroll`, { method: "POST", headers: member })).json();
const runnerId = `artifacts-${Date.now().toString(36)}`;
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
  const m = JSON.parse(e.data);
  if (m.type === "ping") runner.send(JSON.stringify({ type: "pong" }));
  if (m.type === "session.open") sessions.push(m);
  if (m.type === "mcp.response") replies.get(m.reqId)?.(m);
};
runner.send(JSON.stringify({ type: "hello", runnerId, hostname: runnerId, os: "macos", arch: "arm64", version: "0.0.0-fake", sessions: [], ended: [] }));
/** A tool call from one of this runner's sessions, as runner/src/mcp.rs forwards it. */
const call = (session, tool, args) => new Promise((resolve) => {
  const reqId = crypto.randomUUID();
  replies.set(reqId, resolve);
  runner.send(JSON.stringify({ type: "mcp.request", reqId, session, tool, args }));
});
const putArtifact = (task, name, body, type, auth = `Bearer ${enrolled.token}`) =>
  fetch(`${base}/runner/artifact/${task}?runner=${runnerId}&name=${encodeURIComponent(name)}`, { method: "PUT", headers: { "content-type": type, ...(auth ? { authorization: auth } : {}) }, body });

// The feed, for the task.
const feed = new WebSocket(`${ws}/client/connect`, { headers: member });
const tasks = new Map();
let goals = [];
let poke = null;
feed.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "snapshot") { goals = m.goals; for (const t of m.tasks) tasks.set(t.id, t); }
  if (m.type === "goal.updated") goals = [...goals.filter((g) => g.id !== m.goal.id), m.goal];
  if (m.type === "task.updated") tasks.set(m.task.id, m.task);
  if (m.type === "error") console.log(`server said: ${m.message}`);
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

const prefix = `AR${Date.now() % 1000}`;
send({ type: "goal.save", goal: { id: "", name: `Artifacts ${prefix}`, prefix, color: "#14A866", summary: "Charts and pages agents share", lead: "", folder: "/tmp/mf-artifacts", base: "main" } });
const goal = await wait("goal", () => goals.find((g) => g.prefix === prefix));
send({ type: "task.create", goal: goal.id, title: "Speed up the task list", brief: "Make the task list load faster and show the numbers.", shareable: false, plan: true, tickets: [], agent: "scripted" });
const id = `${prefix}-1`;

const planner = await wait("planner", () => sessions.find((s) => s.taskId === id));
const planned = await call(planner.id, "submit_plan", {
  summary: "Page the list.",
  steps: [{ text: "Page the list", file: "web/tasks.js" }],
  doneWhen: [{ text: "The list loads in under 100ms", proof: "tests" }],
  risk: { level: "low", reasons: ["One list."], areas: [] },
  footprint: { files: 1, lines: 20 },
});
check(!planned.error, `the planner submits a plan (${planned.error ?? "ok"})`);
await wait("plan", () => tasks.get(id)?.state === "awaitingApproval" || tasks.get(id)?.state === "building");
if (tasks.get(id).state === "awaitingApproval") send({ type: "task.approvePlan", id });
const builder = await wait("builder", () => sessions.find((s) => s.taskId === id && s.id !== planner.id));
check((tasks.get(id).artifacts ?? []).length === 0, "a new task has no artifacts");

// The runner uploads each file, as proof.rs `prepare_artifact` does.
const pageRes = await putArtifact(id, htmlName, html, "text/html");
const page = await pageRes.json();
check(pageRes.status === 201 && /^\/attachments\/[0-9a-f-]{36}\/[\w.\-]+$/.test(page.key) && page.type === "text/html" && page.bytes === html.length,
  `the HTML page is stored (${pageRes.status} ${JSON.stringify(page)})`);
const shotRes = await putArtifact(id, pngName, png, "image/png");
const shot = await shotRes.json();
check(shotRes.status === 201 && shot.type === "image/png" && shot.bytes === png.length, `the PNG is stored (${shotRes.status} ${JSON.stringify(shot)})`);

// Refused: wrong, missing or a member's token; too big; not a kind it knows; a name with '..'.
check((await putArtifact(id, "x.png", png, "image/png", "Bearer mfr_wrong")).status === 401, "a wrong runner token gets 401");
check((await putArtifact(id, "x.png", png, "image/png", null)).status === 401, "no runner token gets 401");
check((await fetch(`${base}/runner/artifact/${id}?runner=${runnerId}&name=x.png`, { method: "PUT", headers: member, body: png })).status === 401, "a member's token isn't a runner's (401)");
const big = Buffer.concat([Buffer.from("<!doctype html>"), Buffer.alloc(12 * 1024 * 1024, 0x61)]);
check((await putArtifact(id, "big.html", big, "text/html")).status === 413, "a 12 MB file is refused (413)");
check((await putArtifact(id, "blob.bin", Buffer.from([0x50, 0x4b, 0x03, 0x04, 0xff, 0xfe, 0, 1]), "application/octet-stream")).status === 415, "a binary blob is refused (415)");
check((await putArtifact(id, "../x.png", png, "image/png")).status === 400, "a name with '..' is refused (400)");

// `share_artifact` with the keys, the way proof.rs `prepare_artifact_with` rewrites the call.
const s1 = await call(builder.id, "share_artifact", { title: "Latency chart", summary: "p50 load time per build", file: { key: page.key, name: htmlName, type: page.type, bytes: page.bytes } });
const s2 = await call(builder.id, "share_artifact", { title: "Before and after", file: { key: shot.key, name: pngName, type: shot.type, bytes: shot.bytes } });
check(!s1.error && !s2.error, `share_artifact takes both (${s1.result?.summary ?? s1.error}; ${s2.result?.summary ?? s2.error})`);
const t = await wait("artifacts", () => tasks.get(id)?.artifacts?.length === 2 && tasks.get(id));
const [a1, a2] = t.artifacts;
check(a1.title === "Latency chart" && a1.kind === "html" && a1.file === page.key && a1.mime === "text/html" && a1.version === 1 && a1.by === "builder" && a1.summary === "p50 load time per build",
  `the feed carries the HTML artifact (${JSON.stringify(a1)})`);
check(a2.title === "Before and after" && a2.kind === "image" && a2.file === shot.key && a2.bytes === png.length && a2.version === 1 && a2.summary == null,
  `the feed carries the PNG artifact (${JSON.stringify(a2)})`);
check(t.events.some((e) => e.who === "builder" && e.text === "shared an artifact: Latency chart"), "the timeline says the builder shared it");

// Sharing again under the same title is a new version, not a second artifact.
const againRes = await putArtifact(id, htmlName, html, "text/html");
const again = await againRes.json();
const s3 = await call(builder.id, "share_artifact", { title: "latency chart", summary: "with build 2", file: { key: again.key, name: htmlName, type: again.type, bytes: again.bytes } });
const t2 = await wait("v2", () => tasks.get(id)?.artifacts?.some((a) => a.version === 2) && tasks.get(id));
const v2 = t2.artifacts.find((a) => a.version === 2);
check(!s3.error && t2.artifacts.length === 2 && v2.file === again.key && v2.summary === "with build 2", `a re-share bumps the version (${s3.result?.summary ?? s3.error}; ${t2.artifacts.map((a) => `${a.title} v${a.version}`).join(", ")})`);

// A member fetches the bytes; the HTML never as a page on the factory's origin.
const got = await fetch(`${base}${a2.file}`, { headers: member });
check(got.status === 200 && Buffer.from(await got.arrayBuffer()).equals(png), `a member gets the PNG back byte for byte (${got.status})`);
const pageGot = await fetch(`${base}${v2.file}`, { headers: member });
check(pageGot.status === 200 && Buffer.from(await pageGot.arrayBuffer()).equals(html), `a member gets the HTML back byte for byte (${pageGot.status})`);
check(/^attachment/.test(pageGot.headers.get("content-disposition") ?? "") && (pageGot.headers.get("content-security-policy") ?? "").includes("sandbox"), "the HTML is a sandboxed download, never a page");

// A key that isn't an attachment's link is refused.
const bad = await call(builder.id, "share_artifact", { title: "Elsewhere", file: { key: "https://evil.example/x.html" } });
check(!!bad.error && !tasks.get(id).artifacts.some((a) => a.title === "Elsewhere"), `a file that isn't /attachments/<id>/<name> is refused (${bad.error})`);

console.log(`${id}: ${failures ? `${failures} failed` : "all passed"}`);
process.exit(failures ? 1 : 0);

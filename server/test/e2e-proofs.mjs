// A builder's screenshot and video proofs (MF-44), with this script as the runner:
//   node server/test/e2e-proofs.mjs http://localhost:8788 [screenshot.png] [recording.mp4]
// Enrolls a runner, makes a goal and a task, answers the planner's session with a plan whose Done when
// wants a screenshot and a video, and in the builder's session does what runner/src/proof.rs does:
// PUTs each file to /runner/proof/<task> with the runner's token and calls `prove` with the key.
// Checks: the upload answers {key, type, bytes}; the item's evidence.file is that key; a member GETs the
// same bytes there; a wrong or missing runner token gets 401; a file that isn't an image, video or text
// is refused, as is a video over 95 MB and an image over 20 MB; full-size ones (a 15 MB PNG, a 30 MB
// video) go through byte for byte; a body over 95 MB is refused (413); and a key that isn't an attachment's is dropped. Without files it uses made-up bytes with the right headers. The task is left proven, to look at.

import { randomBytes } from "node:crypto";
import { request as httpRequest } from "node:http";
import { readFileSync } from "node:fs";
import { basename } from "node:path";

const [base = "http://localhost:8788", shotPath, clipPath] = process.argv.slice(2);
const ws = base.replace(/^http/, "ws");
let failures = 0;
const check = (ok, what) => { console.log(`${ok ? "ok  " : "FAIL"} ${what}`); if (!ok) failures++; };

const png = shotPath ? readFileSync(shotPath) : Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), randomBytes(40_000)]);
const mp4 = clipPath ? readFileSync(clipPath) : Buffer.concat([Buffer.from("\0\0\0\x20ftypisom\0\0\x02\0", "latin1"), randomBytes(200_000)]);
const shotName = shotPath ? basename(shotPath) : "login.png";
const clipName = clipPath ? basename(clipPath) : "sign-in.mp4";

const { token } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();
const member = { authorization: `Bearer ${token}` };

// The runner: enrolled with the member's code, connected, with an agent of its own.
const { code } = await (await fetch(`${base}/api/machines/enroll`, { method: "POST", headers: member })).json();
const runnerId = `proofs-${Date.now().toString(36)}`;
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
const putProof = (task, name, body, type, auth = `Bearer ${enrolled.token}`) =>
  fetch(`${base}/runner/proof/${task}?runner=${runnerId}&name=${encodeURIComponent(name)}`, { method: "PUT", headers: { "content-type": type, ...(auth ? { authorization: auth } : {}) }, body });

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

const prefix = `PF${Date.now() % 1000}`;
send({ type: "goal.save", goal: { id: "", name: `Proofs ${prefix}`, prefix, color: "#14A866", summary: "Screenshot and video proofs", lead: "", folder: "/tmp/mf-proofs", base: "main" } });
const goal = await wait("goal", () => goals.find((g) => g.prefix === prefix));
send({ type: "task.create", goal: goal.id, title: "Sign-in page shows the new logo", brief: "Swap the logo on /login.", shareable: false, plan: true, tickets: [], agent: "scripted" });
const id = `${prefix}-1`;

// The planner's session: a plan whose Done when wants a screenshot and a video.
const planner = await wait("planner", () => sessions.find((s) => s.taskId === id));
const planned = await call(planner.id, "submit_plan", {
  summary: "Swap the logo.",
  steps: [{ text: "Swap the logo", file: "web/login.html" }],
  doneWhen: [{ text: "/login shows the new logo", proof: "screenshot" }, { text: "Signing in still works", proof: "video" }],
  risk: { level: "low", reasons: ["One image."], areas: [] },
  footprint: { files: 1, lines: 2 },
});
check(!planned.error, `the planner submits a plan (${planned.error ?? "ok"})`);
await wait("plan", () => tasks.get(id)?.state === "awaitingApproval" || tasks.get(id)?.state === "building");
if (tasks.get(id).state === "awaitingApproval") send({ type: "task.approvePlan", id });
const builder = await wait("builder", () => sessions.find((s) => s.taskId === id && s.id !== planner.id));

// The runner uploads each file, as proof.rs `upload` does.
const shotRes = await putProof(id, shotName, png, "image/png");
const shot = await shotRes.json();
check(shotRes.status === 201 && /^\/attachments\/[0-9a-f-]{36}\/[\w.\-]+$/.test(shot.key) && shot.type === "image/png" && shot.bytes === png.length,
  `the screenshot is stored (${shotRes.status} ${JSON.stringify(shot)})`);
const clipRes = await putProof(id, clipName, mp4, "video/mp4");
const clip = await clipRes.json();
check(clipRes.status === 201 && clip.type === "video/mp4" && clip.bytes === mp4.length, `the video is stored (${clipRes.status} ${JSON.stringify(clip)})`);

// Refused: wrong or no token, a file that's neither, too big.
check((await putProof(id, "x.png", png, "image/png", "Bearer mfr_wrong")).status === 401, "a wrong runner token gets 401");
check((await putProof(id, "x.png", png, "image/png", null)).status === 401, "no runner token gets 401");
check((await fetch(`${base}/runner/proof/${id}?runner=${runnerId}&name=x.png`, { method: "PUT", headers: member, body: png })).status === 401, "a member's token isn't a runner's (401)");
check((await putProof(id, "x.bin", Buffer.from([0x50, 0x4b, 0x03, 0x04, 0xff, 0xfe, 0, 1]), "application/zip")).status === 415, "a file that isn't an image, video or text is refused (415)");
// Full-size ones go as they are, and come back the same.
const fullPng = Buffer.concat([png.subarray(0, 8), randomBytes(15 * 1024 * 1024)]);
const fullMp4 = Buffer.concat([mp4.subarray(0, 16), randomBytes(30 * 1024 * 1024)]);
for (const [what, name, bytes, type] of [["a 15 MB PNG", "retina.png", fullPng, "image/png"], ["a 30 MB video", "long.mp4", fullMp4, "video/mp4"]]) {
  const res = await putProof(id, name, bytes, type);
  const up = await res.json().catch(() => ({}));
  const got = up.key ? await fetch(`${base}${up.key}`, { headers: member }) : null;
  const back = got ? Buffer.from(await got.arrayBuffer()) : Buffer.alloc(0);
  check(res.status === 201 && up.bytes === bytes.length && back.equals(bytes), `${what} uploads (${res.status}) and comes back byte for byte (${back.length} of ${bytes.length})`);
}

/** A raw PUT: `length` as the content-length (or chunked when null). The whole body is sent: wrangler
 *  dev's proxy holds a request until its body is in, so "refused without reading it" is checked against
 *  the Worker's own code in security.test.ts (it counts the bytes pulled); here it's the status. */
const rawPut = (name, length, send, type = "video/mp4", head = mp4.subarray(0, 16)) => new Promise((resolve, reject) => {
  const headers = { authorization: `Bearer ${enrolled.token}`, "content-type": type };
  if (length !== null) headers["content-length"] = String(length);
  const req = httpRequest(`${base}/runner/proof/${id}?runner=${runnerId}&name=${name}`, { method: "PUT", headers }, (res) => {
    res.resume();
    resolve(res.statusCode);
    req.destroy();
  });
  req.on("error", (e) => (e.code === "ECONNRESET" || e.code === "EPIPE" ? null : reject(e)));
  req.end(Buffer.concat([head, Buffer.alloc(send)]));
  setTimeout(() => { resolve(-1); req.destroy(); }, 60000);
});
const bigPng = await rawPut("big.png", 21 * 1024 * 1024 + 8, 21 * 1024 * 1024, "image/png", png.subarray(0, 8));
check(bigPng === 413, `a 21 MB image is refused (413) (${bigPng})`);
const huge = await rawPut("huge.mp4", 96 * 1024 * 1024, 96 * 1024 * 1024 - 16);
check(huge === 413, `a 96 MB body is refused (413) (${huge})`);
// A chunked upload with no content-length (411) isn't checked here: wrangler dev's proxy adds one. See
// security.test.ts, "a proof without content-length is refused (411), without reading it".
check((await putProof(id, "../x.png", png, "image/png")).status === 400, "a name with '..' is refused (400)");

// `prove` with the keys, the way proof.rs `prepare_with` rewrites the call.
const p1 = await call(builder.id, "prove", { item: 1, kind: "screenshot", summary: "/login with the new logo", file: { key: shot.key, name: shotName, type: shot.type, bytes: shot.bytes } });
const p2 = await call(builder.id, "prove", { item: 2, kind: "video", summary: "Signing in, start to finish", file: { key: clip.key, name: clipName, type: clip.type, bytes: clip.bytes } });
check(!p1.error && !p2.error, `prove takes both (${p1.result?.summary ?? p1.error}; ${p2.result?.summary ?? p2.error})`);
const t = await wait("proven", () => tasks.get(id)?.doneWhen.every((d) => d.status === "proven") && tasks.get(id));
check(t.doneWhen[0].evidence.file === shot.key, `the screenshot's evidence.file is its key (${t.doneWhen[0].evidence.file})`);
check(t.doneWhen[1].evidence.file === clip.key, `the video's evidence.file is its key (${t.doneWhen[1].evidence.file})`);

// A member fetches the same bytes.
for (const [what, key, bytes, type] of [["screenshot", shot.key, png, "image/png"], ["video", clip.key, mp4, "video/mp4"]]) {
  const got = await fetch(`${base}${key}`, { headers: member });
  const back = Buffer.from(await got.arrayBuffer());
  check(got.status === 200 && back.equals(bytes) && got.headers.get("content-type") === type && /^inline/.test(got.headers.get("content-disposition") ?? ""),
    `a member gets the ${what} back byte for byte, inline as ${type} (${got.status}, ${back.length} bytes)`);
}

// A key that isn't an attachment's link is dropped, not kept.
const p3 = await call(builder.id, "prove", { item: 1, kind: "screenshot", summary: "elsewhere", file: { key: "https://evil.example/x.png" } });
const after = await wait("re-proven", () => tasks.get(id)?.doneWhen[0].evidence.summary === "elsewhere" && tasks.get(id));
check(!p3.error && after.doneWhen[0].evidence.file === null, `a file that isn't /attachments/<id>/<name> isn't kept (${after.doneWhen[0].evidence.file})`);
await call(builder.id, "prove", { item: 1, kind: "screenshot", summary: "/login with the new logo", file: { key: shot.key } });

console.log(`${id}: ${failures ? `${failures} failed` : "all passed"}`);
process.exit(failures ? 1 : 0);

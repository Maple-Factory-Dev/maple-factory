// A runner unenrolls itself with its own token (`maple-runner unenroll`):
//   node server/test/e2e-unenroll.mjs http://localhost:8788
// Against `wrangler dev` with DEV_LOGIN. Enrolls a machine, checks a wrong token gets 401 and leaves it listed,
// then unenrolls it with the right token (204): it's gone from /api/machines, and connecting with the old
// token, or unenrolling again, gets 401.

import { request as httpRequest } from "node:http";

const [base = "http://localhost:8788"] = process.argv.slice(2);
const ws = base.replace(/^http/, "ws");
let failures = 0;
const check = (ok, what) => { console.log(`${ok ? "ok  " : "FAIL"} ${what}`); if (!ok) failures++; };

const { token: appToken } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();
const app = { authorization: `Bearer ${appToken}` };
const machines = async () => (await (await fetch(`${base}/api/machines`, { headers: app })).json()).map((m) => m.id);

// Enroll a machine with a fresh code.
const id = `unenroll-${Date.now().toString(36)}`;
const { code } = await (await fetch(`${base}/api/machines/enroll`, { method: "POST", headers: app })).json();
const enrolled = await fetch(`${base}/runner/enroll`, { method: "POST", body: JSON.stringify({ code, runnerId: id, hostname: "e2e", os: "macos", arch: "aarch64", version: "0.0.0" }) });
check(enrolled.status === 200, `enrolled ${id} (${enrolled.status})`);
const { token } = await enrolled.json();
check((await machines()).includes(id), `${id} is listed`);

/** Whether /runner/connect accepts this token: a WebSocket that opens, or one the server turns away. */
const connects = (t) => new Promise((resolve) => {
  const sock = new WebSocket(`${ws}/runner/connect?runner=${id}`, { headers: { authorization: `Bearer ${t}` } });
  sock.onopen = () => { sock.close(); resolve(true); };
  sock.onerror = () => resolve(false);
});
const unenroll = (t, body = { runnerId: id }) =>
  fetch(`${base}/runner/unenroll`, { method: "POST", headers: { authorization: `Bearer ${t}` }, body: JSON.stringify(body) });

check(await connects(token), "connect with its token works");

// A wrong token (or none) is turned away and the machine stays.
const wrong = await unenroll("mfr_wrong");
check(wrong.status === 401, `wrong token → ${wrong.status}`);
const none = await fetch(`${base}/runner/unenroll`, { method: "POST", body: JSON.stringify({ runnerId: id }) });
check(none.status === 401, `no token → ${none.status}`);
check((await machines()).includes(id), `${id} is still listed`);

// The right token: 204, the machine is forgotten, and the token is dead.
const done = await unenroll(token);
check(done.status === 204, `unenroll with its token → ${done.status}`);
check(!(await machines()).includes(id), `${id} is gone from /api/machines`);
// fetch won't send an Upgrade header, so ask over node:http to see the status the server answers.
const connectStatus = await new Promise((resolve, reject) => {
  const req = httpRequest(`${base}/runner/connect?runner=${id}`, {
    headers: { authorization: `Bearer ${token}`, upgrade: "websocket", connection: "Upgrade", "sec-websocket-version": "13", "sec-websocket-key": "dGhlIHNhbXBsZSBub25jZQ==" },
  });
  req.on("response", (res) => { res.resume(); resolve(res.statusCode); });
  req.on("upgrade", (res, socket) => { socket.destroy(); resolve(101); });
  req.on("error", reject);
  req.end();
});
check(connectStatus === 401, `connect with the old token → ${connectStatus}`);
check(!(await connects(token)), "the old token's WebSocket is refused");
const again = await unenroll(token);
check(again.status === 401, `unenrolling again → ${again.status}`);
// The runner id can come in the query, too.
const viaQuery = await fetch(`${base}/runner/unenroll?runner=${id}`, { method: "POST", headers: { authorization: `Bearer ${token}` } });
check(viaQuery.status === 401, `?runner= with the old token → ${viaQuery.status}`);

console.log(failures ? `${failures} failed` : "all passed");
process.exit(failures ? 1 : 0);

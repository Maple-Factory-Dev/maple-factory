// Who may open a terminal, and cutting people off, against the fake GitHub: only a machine's owner and admins
// get its terminals; someone who leaves the org loses their session cookie, app token and open apps at their
// next request; an admin's "Revoke access" (members.revoke) does the same at once, and they can sign in again.
//   node server/test/e2e-access.mjs http://localhost:8788 [fake GitHub URL] [wrangler --persist-to folder]
// The fake runs with --owner acme:alice --member acme:bob --member acme:carol --member acme:dave --installed acme/greeter;
// the server with GITHUB_ORG=acme, GITHUB_API_URL pointing at the fake, the GitHub App's id, key, client id/secret,
// SESSION_SECRET and MEMBERSHIP_RECHECK_MS=0, no DEV_LOGIN, on a fresh local D1 (kept in the persist folder, if any).
// This script plays bob's machine, bobs-mac, itself.

import { execFileSync } from "node:child_process";
import { randomBytes, randomUUID } from "node:crypto";
import { request as httpRequest } from "node:http";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const [base = "http://localhost:8788", gh = "http://localhost:18803", persist] = process.argv.slice(2);
const wsBase = base.replace(/^http/, "ws");
let failures = 0;
const check = (ok, what) => { console.log(`${ok ? "ok  " : "FAIL"} ${what}`); if (!ok) failures++; };
const get = (path, auth) => fetch(`${base}${path}`, { redirect: "manual", headers: auth ?? {} });
const cookieOf = (res, name) => res.headers.getSetCookie().map((c) => c.split(";")[0]).find((c) => c.startsWith(`maple_${name}=`) && c.length > name.length + 7);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const until = async (what, test, ms = 10000) => {
  const deadline = Date.now() + ms;
  for (;;) {
    const hit = await test();
    if (hit) return hit;
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await sleep(100);
  }
};

/** Signs in through /auth/login and /auth/callback as <login>: { cookie } for their session. */
async function signIn(login) {
  const start = await get("/auth/login");
  const state = new URL(start.headers.get("location")).searchParams.get("state");
  const res = await get(`/auth/callback?code=as-${login}&state=${encodeURIComponent(state)}`, { cookie: cookieOf(start, "oauth") });
  if (res.status !== 302) throw new Error(`${login} couldn't sign in: ${res.status} ${await res.text()}`);
  return { cookie: cookieOf(res, "session") };
}
/** Signs in the way the apps do (device flow): { authorization } with their app token. */
async function appSignIn(login) {
  const res = await fetch(`${base}/auth/device/poll`, { method: "POST", body: JSON.stringify({ deviceCode: `as-${login}`, label: "e2e" }) });
  if (res.status !== 200) throw new Error(`${login}'s app couldn't sign in: ${res.status} ${await res.text()}`);
  return { authorization: `Bearer ${(await res.json()).token}` };
}
const meStatus = async (auth) => (await get("/api/me", auth)).status;

/** A WebSocket's handshake alone: the status and, when refused, the body. */
function handshake(path, auth) {
  return new Promise((resolve, reject) => {
    const req = httpRequest(`${base}${path}`, {
      headers: { connection: "Upgrade", upgrade: "websocket", "sec-websocket-version": "13", "sec-websocket-key": randomBytes(16).toString("base64"), ...auth },
    });
    req.on("upgrade", (res, socket) => { socket.destroy(); resolve({ status: res.statusCode, body: "" }); });
    req.on("response", async (res) => {
      let body = "";
      for await (const chunk of res) body += chunk;
      resolve({ status: res.statusCode, body });
    });
    req.on("error", reject);
    req.end();
  });
}

/** A socket that keeps what arrives and how it closed. */
async function open(path, auth) {
  const ws = new WebSocket(`${wsBase}${path}`, { headers: auth });
  ws.binaryType = "arraybuffer";
  const s = { ws, seen: [], closed: null };
  ws.onmessage = (e) => s.seen.push(typeof e.data === "string" ? JSON.parse(e.data) : new TextDecoder().decode(e.data));
  ws.onclose = (e) => (s.closed = { code: e.code, reason: e.reason });
  await new Promise((r, j) => { ws.onopen = r; ws.onerror = () => j(new Error(`${path} didn't open`)); });
  return s;
}
async function feed(auth) {
  const f = await open("/client/connect", auth);
  f.send = (m) => f.ws.send(JSON.stringify(m));
  /** Sends `m` and waits for an error, or the first message after it that `test` takes. */
  f.ask = async (m, what, test) => {
    const from = f.seen.length;
    f.send(m);
    return until(what, () => f.seen.slice(from).find((x) => x.type === "error" || test(x)));
  };
  f.send({ type: "subscribe" });
  f.snapshot = await until("snapshot", () => f.seen.find((m) => m.type === "snapshot"));
  return f;
}
const membersUpdated = (m) => m.type === "members.updated";

/** The server's local D1, as the e2e tests' wrangler dev keeps it. */
function d1(sql) {
  const server = join(dirname(fileURLToPath(import.meta.url)), "..");
  const out = execFileSync("npx", ["wrangler", "d1", "execute", "maple", "--local", "--json", "--command", sql, ...(persist ? ["--persist-to", persist] : [])], { cwd: server, encoding: "utf8" });
  return JSON.parse(out)[0].results;
}

const alice = await signIn("alice");
const bob = await signIn("bob");
const carol = await signIn("carol");
const dave = await signIn("dave");

// ---- 1. Terminals: the machine's owner and admins only ---------------------------------------------------

const enroll = await (await fetch(`${base}/api/machines/enroll`, { method: "POST", headers: bob })).json();
const enrolled = await (await fetch(`${base}/runner/enroll`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ code: enroll.code, runnerId: "bobs-mac", hostname: "bobs-mac", os: "macos", arch: "arm64", version: "0.0.0-e2e" }),
})).json();
check(!!enrolled.token, "bob enrolls bobs-mac");
const runner = new WebSocket(`${wsBase}/runner/connect?runner=bobs-mac`, { headers: { authorization: `Bearer ${enrolled.token}` } });
const replays = [];
runner.onmessage = (e) => {
  if (typeof e.data !== "string") return;
  const m = JSON.parse(e.data);
  if (m.type !== "session.replay") return;
  replays.push(m);
  runner.send(JSON.stringify({ type: "session.replay", id: m.id, nonce: m.nonce, data: Buffer.from(`replay for ${m.nonce}`).toString("base64") }));
};
await new Promise((r, j) => { runner.onopen = r; runner.onerror = j; });
runner.send(JSON.stringify({ type: "hello", runnerId: "bobs-mac", hostname: "bobs-mac", os: "macos", arch: "arm64", version: "0.0.0-e2e", sessions: [], ended: [] }));
await sleep(300);

const session = randomUUID();
const terminal = `/client/terminal?machine=bobs-mac&session=${session}`;
const asked = replays.length;
const carolTerm = await handshake(terminal, carol);
check(carolTerm.status === 403 && carolTerm.body === "Only bob or an admin can open terminals on bobs-mac.", `carol, a member, is refused bob's terminal: ${carolTerm.status} "${carolTerm.body}"`);
await sleep(500);
check(replays.length === asked, `and no session.replay reached the runner (${replays.length - asked})`);
const plain = await get(terminal, carol);
check(plain.status === 403 && (await plain.text()) === carolTerm.body, `a plain GET of the same URL gives the apps the same reason (${plain.status})`);
const unknown = await handshake(`/client/terminal?machine=nobodys-mac&session=${session}`, alice);
check(unknown.status === 404, `an unknown machine is a 404 (${unknown.status})`);

for (const [who, auth] of [["bob (owner)", bob], ["alice (admin)", alice]]) {
  const status = (await handshake(terminal, auth)).status;
  const before = replays.length;
  const term = await open(terminal, auth);
  const replay = await until(`${who}'s replay`, () => term.seen.find((x) => typeof x === "string" && x.startsWith("replay for ")));
  check(status === 101 && replays.length > before && replay === `replay for ${replays.at(-1).nonce}`, `${who} gets ${status} and the runner's replay ("${replay}")`);
  term.ws.close();
}

// ---- 2. Leaving the org: cut off at the next request ------------------------------------------------------

const carolApp = await appSignIn("carol");
check(await meStatus(carol) === 200 && await meStatus(carolApp) === 200, "carol's cookie and app token work while she's in acme");
check(d1("SELECT count(*) AS n FROM app_tokens WHERE login = 'carol'")[0].n === 1, "she has an app token");
const carolFeed = await feed(carolApp);
await fetch(`${gh}/_leave`, { method: "POST", body: JSON.stringify({ org: "acme", login: "carol" }) });
const cookieAfter = await meStatus(carol);
const tokenAfter = await meStatus(carolApp);
check(cookieAfter === 401 && tokenAfter === 401, `after she leaves acme, her cookie and app token get ${cookieAfter} and ${tokenAfter} on /api/me`);
const carolClosed = await until("carol's feed closing", () => carolFeed.closed);
check(carolClosed.code === 4003, `her open feed closes (${carolClosed.code} ${carolClosed.reason})`);
check(d1("SELECT count(*) AS n FROM app_tokens WHERE login = 'carol'")[0].n === 0, "her app_tokens rows are gone");
const revokedRow = d1("SELECT revoked_at FROM members WHERE login = 'carol'")[0];
check(revokedRow.revoked_at > 0, `members.revoked_at is set (${revokedRow.revoked_at})`);

// ---- 3. An admin's "Revoke access" ------------------------------------------------------------------------

const aliceFeed = await feed(alice);
const bobFeed = await feed(bob);
const daveApp = await appSignIn("dave");
const daveFeed = await feed(daveApp);

const refused = await bobFeed.ask({ type: "members.revoke", login: "dave" }, "bob's refusal", membersUpdated);
check(refused.type === "error", `bob, a member, can't revoke dave: "${refused.message}"`);
check(await meStatus(dave) === 200, "and dave's still in");

// Make dave an admin for a moment, so he has a terminal open to lose.
await aliceFeed.ask({ type: "admins.grant", login: "dave" }, "dave's grant", (m) => m.members?.find((x) => x.login === "dave")?.role === "admin");
const daveTerm = await open(terminal, daveApp);
await until("dave's replay", () => daveTerm.seen.find((x) => typeof x === "string" && x.startsWith("replay for ")));

const revoked = await aliceFeed.ask({ type: "members.revoke", login: "dave" }, "the revocation", (m) => membersUpdated(m) && m.members.find((x) => x.login === "dave")?.role === "member");
check(revoked.type === "members.updated", `alice revokes dave (${revoked.type}${revoked.message ? `: ${revoked.message}` : ""})`);
check(await meStatus(dave) === 401 && await meStatus(daveApp) === 401, "dave's cookie and app token get 401");
const daveClosed = await until("dave's feed closing", () => daveFeed.closed);
check(daveClosed.code === 4003, `his feed closes (${daveClosed.code} ${daveClosed.reason})`);
const termClosed = await until("dave's terminal closing", () => daveTerm.closed);
check(termClosed.code === 4003, `and so does his terminal on bobs-mac (${termClosed.code} ${termClosed.reason})`);

const daveAgain = await signIn("dave");
const daveMe = await get("/api/me", daveAgain);
check(daveMe.status === 200 && (await daveMe.json()).member.role === "member", "dave signs in again: the new session works, without his old admin grant");

const self = await aliceFeed.ask({ type: "members.revoke", login: "alice" }, "alice revoking herself", membersUpdated);
check(self.type === "error", `alice can't revoke herself: "${self.message}"`);
await aliceFeed.ask({ type: "admins.grant", login: "bob" }, "bob's grant", (m) => m.members?.find((x) => x.login === "bob")?.role === "admin");
const owner = await bobFeed.ask({ type: "members.revoke", login: "alice" }, "revoking alice", membersUpdated);
check(owner.type === "error", `bob, now an admin, can't revoke alice, a GitHub owner: "${owner.message}"`);
check(await meStatus(alice) === 200, "and alice is still in");

for (const f of [aliceFeed, bobFeed]) f.ws.close();
runner.close();
process.exit(failures ? 1 : 0);

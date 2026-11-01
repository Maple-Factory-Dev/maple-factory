// Who may open a terminal, and cutting people off, against the fake GitHub: only a machine's owner and admins
// get its terminals, and taking back an admin's grant closes those they opened as one; someone who leaves the org
// loses their session cookie, app token and open apps (by the org hub's sweep, or at their next request); an admin's "Revoke access" (members.revoke) does the same at once, and they can sign in again.
// Only the owner and admins resize a machine's sessions; a revoked owner's machines go offline until they sign in
// again; and an owner GitHub demotes stops being an admin at the next re-check.
// Sharing a session lets a teammate in: watch-only input is dropped, "can type" input reaches the runner, unsharing
// closes their terminal with 4003, only the owner (or an admin) shares, and leaving the org closes a shared terminal too.
// The native session view (MF-201) follows the same rule over the feed: a stranger can't subscribe, a watch-only share
// gets its own backfill and live events but its input is refused, "can type" input reaches the runner with `by`, and
// unsharing stops the events; the last unsubscribe tells the runner to stop.
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
const replays = [];
const resizes = [];
const inputs = [];
const eventSubs = [];
const sessionInputs = [];
let seq = 0;
const event = (text) => ({ type: "user", id: `ev-${++seq}`, session, seq, at: Date.now(), agent: "claude", text });
/** A live native-view event from bobs-mac: no nonce, so it goes to every subscriber still allowed. */
const live = (text) => runner.ws.send(JSON.stringify({ type: "session.events", id: session, events: [event(text)], backfill: false, nextSeq: seq + 1, epoch: "e1" }));
const session = randomUUID();
/** bobs-mac's runner, with one session open: answers replays and keeps the resizes and keystrokes it's sent. */
async function connectRunner() {
  const ws = new WebSocket(`${wsBase}/runner/connect?runner=bobs-mac`, { headers: { authorization: `Bearer ${enrolled.token}` } });
  const r = { ws, closed: null };
  ws.binaryType = "arraybuffer";
  ws.onmessage = (e) => {
    if (typeof e.data !== "string") return void inputs.push(new TextDecoder().decode(new Uint8Array(e.data).subarray(16)));
    const m = JSON.parse(e.data);
    if (m.type === "session.resize") resizes.push(m);
    if (m.type === "session.input") sessionInputs.push(m);
    if (m.type === "session.events.subscribe") {
      eventSubs.push(m);
      // The backfill echoes the nonce (and a cursor the apps never see), so only the viewer that asked gets it.
      if (!m.stop) ws.send(JSON.stringify({ type: "session.events", id: m.id, events: [event(`backfill for ${m.nonce}`)], backfill: true, nextSeq: seq + 1, epoch: "e1", nonce: m.nonce, cursor: { seq, token: "t" } }));
    }
    if (m.type !== "session.replay") return;
    replays.push(m);
    ws.send(JSON.stringify({ type: "session.replay", id: m.id, nonce: m.nonce, data: Buffer.from(`replay for ${m.nonce}`).toString("base64") }));
  };
  ws.onclose = (e) => (r.closed = { code: e.code, reason: e.reason });
  await new Promise((ok, j) => { ws.onopen = ok; ws.onerror = j; });
  ws.send(JSON.stringify({ type: "hello", runnerId: "bobs-mac", hostname: "bobs-mac", os: "macos", arch: "arm64", version: "0.0.0-e2e", ended: [],
    sessions: [{ session: { id: session, agent: "claude", cwd: "/tmp", startedAt: Date.now() }, activity: null }] }));
  await sleep(300);
  return r;
}
let runner = await connectRunner();

const terminal = `/client/terminal?machine=bobs-mac&session=${session}`;
const asked = replays.length;
const carolTerm = await handshake(terminal, carol);
const refusal = "Only bob or an admin can open terminals on bobs-mac; ask bob to share this session with you.";
check(carolTerm.status === 403 && carolTerm.body === refusal, `carol, a member, is refused bob's terminal: ${carolTerm.status} "${carolTerm.body}"`);
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

// ---- 1b. Sharing a session: watch, then type, then taken back ---------------------------------------------

const shared = async (auth) => (await (await get("/api/machines", auth)).json()).find((m) => m.id === "bobs-mac").sessions.find((s) => s.session.id === session)?.shares ?? [];
const typed = async (term, keys) => {
  const from = inputs.length;
  term.ws.send(new TextEncoder().encode(keys));
  await sleep(600);
  return inputs.slice(from).join("");
};
const bobShares = await feed(bob);
const carolShares = await feed(carol);
const daveRefused = async (when) => {
  const t = await handshake(terminal, dave);
  check(t.status === 403 && t.body === refusal, `dave, not shared with, is refused ${when} (${t.status})`);
};
await daveRefused("before any share");

const notOwner = await carolShares.ask({ type: "session.share", machine: "bobs-mac", id: session, shares: [{ login: "carol", canType: true }] }, "carol's share refused", () => false);
check(notOwner.message === "Only bob or an admin can share sessions on bobs-mac.", `carol can't share bob's session (with herself): "${notOwner.message}"`);
check((await shared(bob)).length === 0, "and nothing is shared");
const toOwner = await bobShares.ask({ type: "session.share", machine: "bobs-mac", id: session, shares: [{ login: "bob", canType: true }] }, "sharing with the owner refused", () => false);
check(toOwner.type === "error", `bob can't share with himself, the owner: "${toOwner.message}"`);
const toStranger = await bobShares.ask({ type: "session.share", machine: "bobs-mac", id: session, shares: [{ login: "mallory", canType: false }] }, "sharing with a stranger refused", () => false);
check(toStranger.type === "error", `or with someone who isn't a member: "${toStranger.message}"`);

const sharedWith = (canType) => (m) => m.type === "machine.updated" && m.machine.id === "bobs-mac" &&
  m.machine.sessions.find((s) => s.session.id === session)?.shares?.some((x) => x.login === "carol" && x.canType === canType);
bobShares.send({ type: "session.share", machine: "bobs-mac", id: session, shares: [{ login: "carol", canType: false }] });
const watch = await until("carol's feed seeing the share", () => carolShares.seen.find(sharedWith(false)));
check(!!watch, "bob shares the session with carol to watch, and her app sees it on the machine");
const share = (await shared(carol)).find((x) => x.login === "carol");
check(share?.canType === false && share.by === "bob" && share.at > 0, `the session's shares say carol, watch-only, by bob (${JSON.stringify(share)})`);
const carolStatus = (await handshake(terminal, carol)).status;
const carolTerm2 = await open(terminal, carol);
const carolReplay = await until("carol's replay", () => carolTerm2.seen.find((x) => typeof x === "string" && x.startsWith("replay for ")));
check(carolStatus === 101 && !!carolReplay, `carol opens it now (${carolStatus}) and gets the replay`);
runner.ws.send(Buffer.concat([Buffer.from(session.replace(/-/g, ""), "hex"), Buffer.from("live output")]));
await until("carol seeing live output", () => carolTerm2.seen.includes("live output"));
check(true, "and live output reaches her");
check(await typed(carolTerm2, "echo watching\r") === "", "her keystrokes never reach the runner while she can only watch");
const resizesNow = resizes.length;
carolTerm2.ws.send(JSON.stringify({ type: "session.resize", cols: 40, rows: 10 }));
await sleep(500);
check(resizes.length === resizesNow, "nor do her resizes");
await daveRefused("while it's shared with carol");

// The native view, over the feed: the same rule as the terminal.
const sub = { type: "session.subscribeEvents", machine: "bobs-mac", id: session };
const isBackfill = (m) => m.type === "session.events" && m.backfill;
const daveNative = await feed(dave);
const subsBefore = eventSubs.length;
const daveSub = await daveNative.ask(sub, "dave's subscribe refused", () => false);
check(daveSub.type === "error" && daveSub.message === refusal, `dave, not shared with, is refused subscribe: "${daveSub.message}"`);
await sleep(300);
check(eventSubs.length === subsBefore, "and no session.events.subscribe reached the runner for him");
const bobBackfill = await bobShares.ask(sub, "bob's backfill", isBackfill);
check(bobBackfill.type === "session.events" && bobBackfill.events[0].text === `backfill for ${eventSubs.at(-1).nonce}`, "bob, the owner, subscribes and gets his backfill");
const carolBackfill = await carolShares.ask(sub, "carol's backfill", isBackfill);
const carolNonce = eventSubs.at(-1).nonce;
check(carolBackfill.type === "session.events" && carolBackfill.machine === "bobs-mac" && carolBackfill.events[0].text === `backfill for ${carolNonce}` && !("nonce" in carolBackfill) && !("cursor" in carolBackfill),
  `carol (watch-only) gets her backfill, with the machine and without nonce or cursor (${carolBackfill.type}${carolBackfill.message ? `: ${carolBackfill.message}` : ""})`);
await sleep(300);
check(bobShares.seen.filter(isBackfill).length === 1 && !bobShares.seen.some((m) => isBackfill(m) && m.events[0].text.includes(carolNonce)), "and bob's feed doesn't get hers");
const sendInput = (text) => ({ type: "session.sendInput", machine: "bobs-mac", id: session, input: { type: "text", text } });
const inputsBefore = sessionInputs.length;
const carolInput = await carolShares.ask(sendInput("watching"), "carol's input refused", () => false);
check(carolInput.message === "You can watch this session but not type into it; ask bob to let you type.", `carol's sendInput is refused while she can only watch: "${carolInput.message}"`);
await sleep(300);
check(sessionInputs.length === inputsBefore, "and no session.input reached the runner");
live("after the refusal");
await until("carol's live event", () => carolShares.seen.find((m) => m.type === "session.events" && !m.backfill && m.events[0].text === "after the refusal"));
check(true, "carol still gets live events after the refusal");
bobShares.send(sendInput("from bob"));
const bobInput = await until("bob's session.input", () => sessionInputs.slice(inputsBefore).find((m) => m.input.text === "from bob"));
check(bobInput.id === session && bobInput.by === "bob", `bob's input reaches the runner as session.input by ${bobInput.by}`);

bobShares.send({ type: "session.share", machine: "bobs-mac", id: session, shares: [{ login: "carol", canType: true }] });
await until("carol's upgrade", () => carolShares.seen.find(sharedWith(true)));
const carolTyped = await typed(carolTerm2, "ls\r");
check(carolTyped === "ls\r", `upgraded to "can type", her open terminal's keystrokes arrive (${JSON.stringify(carolTyped)})`);
check(!carolTerm2.closed, "without reconnecting");
await daveRefused("while carol can type");
carolShares.send(sendInput("from carol"));
const carolInput2 = await until("carol's session.input", () => sessionInputs.find((m) => m.input.text === "from carol"));
check(carolInput2.by === "carol", `upgraded to "can type", carol's native input reaches the runner as session.input by ${carolInput2.by}`);

bobShares.send({ type: "session.share", machine: "bobs-mac", id: session, shares: [] });
const unshared = await until("carol's terminal closing", () => carolTerm2.closed);
check(unshared.code === 4003 && unshared.reason === "no longer shared", `bob unshares it: her terminal closes (${unshared.code} ${unshared.reason})`);
const again = await handshake(terminal, carol);
check(again.status === 403 && again.body === refusal, `and reconnecting gets ${again.status}`);
check((await shared(bob)).length === 0, "the session's shares are empty again");
await daveRefused("after the unshare");
live("after the unshare");
await until("bob's live event", () => bobShares.seen.find((m) => m.type === "session.events" && m.events[0].text === "after the unshare"));
await sleep(300);
check(!carolShares.seen.some((m) => m.type === "session.events" && m.events[0].text === "after the unshare"), "unshared, carol stops getting live events (bob still does)");
const stopsBefore = eventSubs.filter((m) => m.stop).length;
carolShares.send({ type: "session.unsubscribeEvents", machine: "bobs-mac", id: session });
await sleep(300);
check(eventSubs.filter((m) => m.stop).length === stopsBefore, "carol unsubscribing sends no stop while bob still watches");
bobShares.send({ type: "session.unsubscribeEvents", machine: "bobs-mac", id: session });
const stop = await until("the runner's stop", () => eventSubs.slice(subsBefore).find((m) => m.stop));
check(stop.id === session, "the last unsubscribe sends the runner session.events.subscribe with stop");
daveNative.ws.close();
const audits = d1("SELECT action, target, detail FROM audit WHERE action LIKE 'session.%shared' ORDER BY rowid").map((r) => `${r.action}:${JSON.parse(r.detail).canType ?? "-"}`);
check(JSON.stringify(audits) === JSON.stringify(["session.shared:false", "session.shared:true", "session.unshared:-"]), `each change is audited (${audits.join(", ")})`);

// Shared once more, to watch: leaving the org (below) must close this one too.
bobShares.send({ type: "session.share", machine: "bobs-mac", id: session, shares: [{ login: "carol", canType: false }] });
await until("the share again", () => carolShares.seen.filter(sharedWith(false)).length >= 2);
const carolWatching = await open(terminal, carol);
await until("carol's replay", () => carolWatching.seen.find((x) => typeof x === "string" && x.startsWith("replay for ")));
bobShares.ws.close();
carolShares.ws.close();

// ---- 2. Leaving the org: cut off by the org hub's sweep, before she makes another request -------------------

const carolApp = await appSignIn("carol");
check(await meStatus(carol) === 200 && await meStatus(carolApp) === 200, "carol's cookie and app token work while she's in acme");
check(d1("SELECT count(*) AS n FROM app_tokens WHERE login = 'carol'")[0].n === 1, "she has an app token");
const carolFeed = await feed(carolApp);
await fetch(`${gh}/_leave`, { method: "POST", body: JSON.stringify({ org: "acme", login: "carol" }) });
// No request from carol here: the org hub's alarm re-checks the people with apps open and closes hers.
const carolClosed = await until("carol's feed closing", () => carolFeed.closed);
check(carolClosed.code === 4003, `after she leaves acme, her open feed closes without her making a request (${carolClosed.code} ${carolClosed.reason})`);
const cookieAfter = await meStatus(carol);
const tokenAfter = await meStatus(carolApp);
check(cookieAfter === 401 && tokenAfter === 401, `her cookie and app token get ${cookieAfter} and ${tokenAfter} on /api/me`);
check(d1("SELECT count(*) AS n FROM app_tokens WHERE login = 'carol'")[0].n === 0, "her app_tokens rows are gone");
const revokedRow = d1("SELECT revoked_at FROM members WHERE login = 'carol'")[0];
check(revokedRow.revoked_at > 0, `members.revoked_at is set (${revokedRow.revoked_at})`);
const watchingClosed = await until("carol's shared terminal closing", () => carolWatching.closed);
check(watchingClosed.code === 4003, `the terminal bob shared with her closes too (${watchingClosed.code} ${watchingClosed.reason})`);
runner.ws.send(JSON.stringify({ type: "session.activity", id: session, activity: { state: "working", at: Date.now() } }));
await until("carol's share pruned", async () => (await shared(bob)).length === 0);
check(true, "and at bobs-mac's next report the session isn't shared with her any more");

// A stale check is claimed before GitHub is asked, so a burst of requests from one member asks it far fewer times.
const asks = async () => (await (await fetch(`${gh}/_log`)).json()).log.filter((e) => e.path === "/orgs/acme/memberships/bob").length;
const asksBefore = await asks();
const burst = await Promise.all(Array.from({ length: 8 }, () => meStatus(bob)));
const githubAsks = (await asks()) - asksBefore;
check(burst.every((s) => s === 200) && githubAsks >= 1 && githubAsks < burst.length, `8 requests at once from bob with a stale check ask GitHub ${githubAsks} time(s)`);

// ---- 3. An admin's "Revoke access" ------------------------------------------------------------------------

const aliceFeed = await feed(alice);
const bobFeed = await feed(bob);
const daveApp = await appSignIn("dave");
const daveFeed = await feed(daveApp);

const refused = await bobFeed.ask({ type: "members.revoke", login: "dave" }, "bob's refusal", membersUpdated);
check(refused.type === "error", `bob, a member, can't revoke dave: "${refused.message}"`);
check(await meStatus(dave) === 200, "and dave's still in");

// Resizing a session is for the machine's owner and admins too.
const resize = { type: "session.resize", machine: "bobs-mac", id: session, cols: 100, rows: 30 };
const resizesBefore = resizes.length;
const daveResize = await daveFeed.ask(resize, "dave's resize refused", () => false);
check(daveResize.message === "Only bob or an admin can resize sessions on bobs-mac.", `dave, a member, can't resize a session on bobs-mac: "${daveResize.message}"`);
bobFeed.send(resize);
await until("bob's resize reaching the runner", () => resizes.length > resizesBefore);
check(resizes.length === resizesBefore + 1, "bob, its owner, can, and only his resize reached the runner");

// Make dave an admin for a moment: a terminal he opens on bobs-mac closes when the grant is taken back.
await aliceFeed.ask({ type: "admins.grant", login: "dave" }, "dave's grant", (m) => m.members?.find((x) => x.login === "dave")?.role === "admin");
const adminTerm = await open(terminal, daveApp);
await until("dave's replay", () => adminTerm.seen.find((x) => typeof x === "string" && x.startsWith("replay for ")));
await aliceFeed.ask({ type: "admins.revoke", login: "dave" }, "dave's grant taken back", (m) => m.members?.find((x) => x.login === "dave")?.role === "member");
const adminClosed = await until("dave's admin terminal closing", () => adminTerm.closed);
check(adminClosed.code === 4003, `taking back dave's admin closes his terminal on bobs-mac (${adminClosed.code} ${adminClosed.reason})`);
check(await meStatus(daveApp) === 200, "but he's still signed in");

// Admin again, so he has a terminal open to lose when he's revoked.
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

// ---- 4. A revoked owner's machines go offline until they sign in again ----------------------------------------

const bobRevoked = await aliceFeed.ask({ type: "members.revoke", login: "bob" }, "bob's revocation", (m) => membersUpdated(m) && m.members.find((x) => x.login === "bob")?.role === "member");
check(bobRevoked.type === "members.updated", `alice revokes bob (${bobRevoked.type}${bobRevoked.message ? `: ${bobRevoked.message}` : ""})`);
const runnerClosed = await until("bobs-mac's runner closing", () => runner.closed);
check(runnerClosed.code === 4001, `bobs-mac's runner is disconnected (${runnerClosed.code} ${runnerClosed.reason})`);
const offline = await until("bobs-mac offline", async () => {
  const m = (await (await get("/api/machines", alice)).json()).find((x) => x.id === "bobs-mac");
  return m && !m.online && m;
}).catch(() => null);
check(!!offline, "alice sees bobs-mac offline, so no task is given to it");
const back = await handshake("/runner/connect?runner=bobs-mac", { authorization: `Bearer ${enrolled.token}` });
check(back.status === 401, `its token no longer connects while bob's revoked (${back.status} "${back.body}")`);
await signIn("bob");
runner = await connectRunner();
check(!runner.closed, "once bob signs in again, bobs-mac connects again");

// ---- 5. GitHub demotes an owner: they stop being an admin at the next re-check ---------------------------------

const aliceTerm = await open(terminal, alice);
await until("alice's replay", () => aliceTerm.seen.find((x) => typeof x === "string" && x.startsWith("replay for ")));
await fetch(`${gh}/_role`, { method: "POST", body: JSON.stringify({ org: "acme", login: "alice", role: "member" }) });
const aliceMe = await (await get("/api/me", alice)).json();
check(aliceMe.member?.role === "member", `after GitHub makes alice a member, /api/me says ${aliceMe.member?.role}`);
const aliceTermClosed = await until("alice's terminal closing", () => aliceTerm.closed);
check(aliceTermClosed.code === 4003, `her terminal on bobs-mac closes (${aliceTermClosed.code} ${aliceTermClosed.reason})`);
const demoted = await aliceFeed.ask({ type: "members.revoke", login: "dave" }, "alice's refusal", membersUpdated);
check(demoted.type === "error", `and her open app can't revoke anyone any more: "${demoted.message}"`);

aliceFeed.ws.close();
runner.ws.close();
process.exit(failures ? 1 : 0);

// Outside MCP clients at /mcp (src/mcp.ts, src/mcp-auth.ts), against `wrangler dev` with DEV_LOGIN:
//   node server/test/e2e-mcp-clients.mjs http://localhost:8788
// Checks: a read-only personal token sees 2 tools and can't comment; a write token comments and suggests, shown as
// the member with a "via MCP" badge; a revoked token gets 401; the OAuth flow (register, authorize, code + PKCE,
// token, refresh) issues a working token; app tokens don't work at /mcp nor MCP tokens at /api; and revoking a
// member (members.revoke) cuts off their OAuth tokens. Tasks (MF-416): a tasks:read token searches goals and tasks
// and reads one but can't propose; a tasks:write token proposes drafts (owned by the member, never planning) and
// comments with the "via MCP" badge; a bad proposal makes none; a docs-only token gets none of it.

import { createHash, randomBytes } from "node:crypto";
import * as Y from "yjs";
import * as syncProtocol from "y-protocols/sync";
import * as encoding from "lib0/encoding";
import * as decoding from "lib0/decoding";
import { seedDoc } from "../docs-editor/src/headless.js";

/** Writes `markdown` into a doc the way the web editor does: over its Yjs sync socket. */
async function seed(id, token, markdown) {
  const doc = new Y.Doc();
  const sock = new WebSocket(`${base.replace(/^http/, "ws")}/docs/${id}/sync`, { headers: { authorization: `Bearer ${token}` } });
  sock.binaryType = "arraybuffer";
  const synced = new Promise((resolve) => {
    sock.onmessage = (e) => {
      const d = decoding.createDecoder(new Uint8Array(e.data));
      if (decoding.readVarUint(d) !== 0) return;
      const out = encoding.createEncoder();
      encoding.writeVarUint(out, 0);
      const kind = syncProtocol.readSyncMessage(d, out, doc, null);
      if (encoding.length(out) > 1) sock.send(encoding.toUint8Array(out));
      resolve(kind);
    };
  });
  await new Promise((r) => sock.addEventListener("open", r));
  await synced;
  doc.on("update", (u) => { const e = encoding.createEncoder(); encoding.writeVarUint(e, 0); syncProtocol.writeUpdate(e, u); sock.send(encoding.toUint8Array(e)); });
  seedDoc(doc, markdown);
  await new Promise((r) => setTimeout(r, 500));
  sock.close();
}

const [base = "http://localhost:8788"] = process.argv.slice(2);
let failures = 0;
const check = (ok, what) => { console.log(`${ok ? "ok  " : "FAIL"} ${what}`); if (!ok) failures++; };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const b64url = (b) => b.toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const web = { origin: base, "content-type": "application/json" };

let rpcId = 0;
async function mcp(token, method, params = {}) {
  const res = await fetch(`${base}/mcp`, {
    method: "POST",
    headers: { "content-type": "application/json", accept: "application/json, text/event-stream", ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify({ jsonrpc: "2.0", id: ++rpcId, method, params }),
  });
  return { status: res.status, headers: res.headers, body: await res.json().catch(() => null) };
}
const call = (token, name, args) => mcp(token, "tools/call", { name, arguments: args });
const textOf = (r) => r.body?.result?.content?.[0]?.text ?? "";

async function personal(label, scopes) {
  const res = await fetch(`${base}/api/mcp-tokens`, { method: "POST", headers: web, body: JSON.stringify({ label, scopes }) });
  if (res.status !== 201) throw new Error(`couldn't make a token: ${res.status} ${await res.text()}`);
  return res.json();
}

// A doc to work on, made over the feed as the dev member.
const { token: appToken } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();
const ws = new WebSocket(`${base.replace(/^http/, "ws")}/client/connect`, { headers: { authorization: `Bearer ${appToken}` } });
await new Promise((r) => ws.addEventListener("open", r));
// The feed, kept: goals and tasks as the web app sees them.
const goalsSeen = new Map();
const tasksSeen = new Map();
ws.addEventListener("message", (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "snapshot") { for (const g of m.goals ?? []) goalsSeen.set(g.id, g); for (const t of m.tasks ?? []) tasksSeen.set(t.id, t); }
  if (m.type === "goal.updated") goalsSeen.set(m.goal.id, m.goal);
  if (m.type === "task.updated") tasksSeen.set(m.task.id, m.task);
  if (m.type === "error") console.log("feed error:", m.message);
});
const title = `MCP e2e ${Date.now()}`;
ws.send(JSON.stringify({ type: "doc.create", title }));
await sleep(500);

// 1. Read-only personal token.
const ro = await personal("Cursor (read-only)", ["docs:read"]);
check(ro.token.startsWith("mfp_"), "a personal token is an mfp_ token, shown once");
const init = await mcp(ro.token, "initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "e2e", version: "0" } });
check(init.body?.result?.serverInfo?.name === "maple-factory", "initialize answers with the server's info");
const roTools = (await mcp(ro.token, "tools/list")).body?.result?.tools?.map((t) => t.name) ?? [];
check(roTools.length === 2 && roTools.includes("list_docs") && roTools.includes("read_doc"), `read-only scope lists 2 tools (${roTools.join(", ")})`);
const listed = await call(ro.token, "list_docs", { q: title });
const doc = JSON.parse(textOf(listed).split("\n\n").slice(1).join("\n\n") || "null");
const docId = (Array.isArray(doc) ? doc : doc?.docs)?.[0]?.id;
check(Boolean(docId), "list_docs finds the doc");
await seed(docId, appToken, "We ship the MCP server on Friday.\n");
const refused = await call(ro.token, "comment_on_doc", { doc: docId, text: "should not land" });
check(refused.body?.result?.isError === true && /docs:write/.test(textOf(refused)), "read-only scope can't write: comment_on_doc is refused");

// 2. Write token: comment and suggest, as the member.
const rw = await personal("Claude Code", ["docs:read", "docs:write"]);
check((await mcp(rw.token, "tools/list")).body?.result?.tools?.length === 7, "write scope lists all 7 doc tools");
const commented = await call(rw.token, "comment_on_doc", { doc: docId, text: "From an outside MCP client." });
check(commented.status === 200 && commented.body?.result && !commented.body.result.isError, `write scope comments (${textOf(commented).split("\n")[0]})`);
// A fresh doc is empty: proposing a decision gives it a block (and checks propose_decision too).
const proposed = await call(rw.token, "propose_decision", { doc: docId, question: "Ship MCP?", options: [{ label: "Yes" }, { label: "Later" }], chosen: "Yes", rationale: "Outside clients want it." });
check(!proposed.body?.result?.isError, `write scope proposes a decision (${textOf(proposed).split("\n")[0]})`);
const block = /<!-- block (b-[\w-]+)/.exec(textOf(await call(rw.token, "read_doc", { doc: docId })))?.[1];
const suggested = await call(rw.token, "suggest_doc_edit", { doc: docId, quote: "on Friday", replacement: "on Monday", note: "From an outside client." });
check(!suggested.body?.result?.isError, `write scope suggests an edit (${textOf(suggested).split("\n")[0]})`);
const threads = await (await fetch(`${base}/docs/${docId}/threads`, { headers: { authorization: `Bearer ${appToken}` } })).json().catch(() => null);
const read = textOf(await call(rw.token, "read_doc", { doc: docId }));
const shown = JSON.stringify(threads ?? "") + read;
check(/Claude Code via MCP/.test(shown) && /"dev"|dev/.test(shown), "the thread shows the member as author with the 'Claude Code via MCP' badge");

// 3. Token separation.
check((await mcp(appToken, "tools/list")).status === 401, "an app (mft_) token gets 401 at /mcp");
check((await fetch(`${base}/api/me`, { headers: { authorization: `Bearer ${rw.token}` } })).status === 401, "an MCP (mfp_) token gets 401 at /api/me");
const noToken = await mcp(null, "tools/list");
check(noToken.status === 401 && /resource_metadata=/.test(noToken.headers.get("www-authenticate") ?? ""), "no token: 401 with WWW-Authenticate resource_metadata");
check((await fetch(`${base}/mcp`, { method: "POST", headers: { origin: "https://evil.example", authorization: `Bearer ${rw.token}` }, body: "{}" })).status === 403, "a foreign Origin is refused (DNS rebinding)");

// 4. Revoking a personal token.
const list = await (await fetch(`${base}/api/mcp-tokens`)).json();
check(list.tokens.some((t) => t.id === rw.id && t.lastUsed), "Connected apps lists the token with last used");
const del = await fetch(`${base}/api/mcp-tokens/${rw.id}`, { method: "DELETE", headers: { origin: base } });
check(del.status === 204, "DELETE /api/mcp-tokens/:id revokes it");
check((await mcp(rw.token, "tools/list")).status === 401, "a revoked personal token gets 401");

// 5. OAuth: discovery, registration, authorize (as bob, via his app token), code + PKCE, token, refresh.
const prm = await (await fetch(`${base}/.well-known/oauth-protected-resource`)).json();
const meta = await (await fetch(`${base}/.well-known/oauth-authorization-server`)).json();
// wrangler dev hands the Worker a port-less URL, so the metadata says http://localhost: point it back at base.
const at = (u) => `${base}${new URL(u).pathname}`;
const as = { ...meta, registration_endpoint: at(meta.registration_endpoint), authorization_endpoint: at(meta.authorization_endpoint), token_endpoint: at(meta.token_endpoint) };
check(prm.resource.endsWith("/mcp") && as.code_challenge_methods_supported.includes("S256"), "protected-resource and authorization-server metadata");
const badReg = await fetch(as.registration_endpoint, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ client_name: "x", redirect_uris: ["http://evil.example/cb"] }) });
check(badReg.status === 400, "registration refuses a non-https, non-loopback redirect URI");
const redirect = "http://127.0.0.1:33418/callback";
const reg = await (await fetch(as.registration_endpoint, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ client_name: "Claude Desktop", redirect_uris: [redirect] }) })).json();
check(reg.client_id?.startsWith("mcpc_"), "dynamic client registration");

const bob = `bob-${Date.now() % 1e6}`; // a fresh teammate each run: the last run revoked its own
const { token: bobApp } = await (await fetch(`${base}/dev/token?as=${bob}`, { method: "POST" })).json();
const verifier = b64url(randomBytes(32));
const challenge = b64url(createHash("sha256").update(verifier).digest());
const q = new URLSearchParams({ response_type: "code", client_id: reg.client_id, redirect_uri: redirect, code_challenge: challenge, code_challenge_method: "S256", scope: "docs:read docs:write", state: "xyz", resource: prm.resource });
const wrongRedirect = await fetch(`${as.authorization_endpoint}?${new URLSearchParams({ ...Object.fromEntries(q), redirect_uri: "http://127.0.0.1:1/other" })}`, { redirect: "manual", headers: { authorization: `Bearer ${bobApp}` } });
check(wrongRedirect.status === 400 && !wrongRedirect.headers.get("location"), "an unregistered redirect_uri is shown an error, never redirected to");
const page = await fetch(`${as.authorization_endpoint}?${q}`, { headers: { authorization: `Bearer ${bobApp}` } });
const html = await page.text();
check(page.status === 200 && html.includes("Claude Desktop") && html.includes(bob), "the consent page names the client and the member");
const consent = /name="consent" value="([^"]+)"/.exec(html)?.[1];
const form = new URLSearchParams({ ...Object.fromEntries(q), consent, decision: "approve" });
const csrf = await fetch(as.authorization_endpoint, { method: "POST", redirect: "manual", headers: { authorization: `Bearer ${bobApp}`, origin: "https://evil.example", "content-type": "application/x-www-form-urlencoded" }, body: form });
check(csrf.status === 403, "approving from another origin is refused (consent CSRF)");
const approved = await fetch(as.authorization_endpoint, { method: "POST", redirect: "manual", headers: { authorization: `Bearer ${bobApp}`, origin: base, "content-type": "application/x-www-form-urlencoded" }, body: form });
const back = new URL(approved.headers.get("location") ?? "http://x/");
check(approved.status === 302 && back.origin + back.pathname === redirect && back.searchParams.get("state") === "xyz", "approving redirects back with a code and the state");
const code = back.searchParams.get("code");
const tokenAt = (params) => fetch(as.token_endpoint, { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: new URLSearchParams(params) });
const badPkce = await tokenAt({ grant_type: "authorization_code", code, client_id: reg.client_id, redirect_uri: redirect, code_verifier: b64url(randomBytes(32)) });
check(badPkce.status === 400, "a wrong PKCE verifier is refused");
// The failed attempt used the code up (single use): go round again.
const again = await fetch(as.authorization_endpoint, { method: "POST", redirect: "manual", headers: { authorization: `Bearer ${bobApp}`, origin: base, "content-type": "application/x-www-form-urlencoded" }, body: form });
const code2 = new URL(again.headers.get("location")).searchParams.get("code");
const issued = await (await tokenAt({ grant_type: "authorization_code", code: code2, client_id: reg.client_id, redirect_uri: redirect, code_verifier: verifier })).json();
check(issued.access_token?.startsWith("mfp_") && issued.refresh_token && issued.expires_in === 3600, "the code + PKCE exchange issues an access and refresh token");
const replay = await tokenAt({ grant_type: "authorization_code", code: code2, client_id: reg.client_id, redirect_uri: redirect, code_verifier: verifier });
check(replay.status === 400, "a code can't be redeemed twice");
const oauthComment = await call(issued.access_token, "comment_on_doc", { doc: docId, text: "From Claude Desktop, as bob." });
check(oauthComment.status === 200 && oauthComment.body?.result && !oauthComment.body.result.isError, "the OAuth token works: bob comments through it");
const refreshed = await (await tokenAt({ grant_type: "refresh_token", refresh_token: issued.refresh_token, client_id: reg.client_id })).json();
check(refreshed.access_token && (await mcp(issued.access_token, "ping")).status === 401 && (await mcp(refreshed.access_token, "ping")).status === 200, "refresh rotates: the old access token stops, the new one works");
const bobList = await (await fetch(`${base}/api/mcp-tokens`, { headers: { authorization: `Bearer ${bobApp}` } })).status;
check(bobList === 403, "the token list is web-session only (an app token can't read or mint)");

// 6. Revoking the member cuts off their OAuth tokens.
ws.send(JSON.stringify({ type: "members.revoke", login: bob }));
await sleep(800);
check((await mcp(refreshed.access_token, "ping")).status === 401, "revokeMember cuts off bob's OAuth tokens");
const refreshAfter = await tokenAt({ grant_type: "refresh_token", refresh_token: refreshed.refresh_token, client_id: reg.client_id });
check(refreshAfter.status === 400, "and their refresh token");

// 7. Goals and tasks (MF-416).
ws.send(JSON.stringify({ type: "subscribe" }));
await sleep(600);
const dataOf = (r) => JSON.parse(textOf(r).split("\n\n").slice(1).join("\n\n") || "null");
const letters = (n) => [...String(n)].map((d) => "ABCDEFGHIJ"[Number(d)]).join("");
const stamp = Date.now() % 1e6;
const prefix = `MC${letters(stamp)}`;
const other = `MX${letters(stamp)}`;
const word = `zephyr${stamp}`; // only this run's tasks say it
const repo = "acme/mcp-e2e";
const goalName = `MCP tasks e2e ${stamp}`;
ws.send(JSON.stringify({ type: "goal.save", goal: { id: "", name: goalName, prefix, color: "#2EA043", summary: "Outside clients on tasks.", lead: "", repos: [repo], folder: null, base: null } }));
ws.send(JSON.stringify({ type: "goal.save", goal: { id: "", name: `Other e2e ${stamp}`, prefix: other, color: "#2EA043", summary: "Not the one searched for.", lead: "", repos: [], folder: "/tmp/mcp-e2e-other", base: null } }));
await sleep(800);
const goal = [...goalsSeen.values()].find((g) => g.prefix === prefix);
const otherGoal = [...goalsSeen.values()].find((g) => g.prefix === other);
check(Boolean(goal && otherGoal), `two goals to search (${prefix}, ${other})`);
ws.send(JSON.stringify({ type: "task.create", goal: goal.id, title: `Rate-limit /mcp per token ${word}`, brief: "A token can call as fast as the Worker answers.", shareable: true, plan: false, tickets: [], agent: "claude" }));
ws.send(JSON.stringify({ type: "task.create", goal: goal.id, title: "Tidy the consent page", brief: `Unrelated, but it says ${word} too.`, shareable: true, plan: false, tickets: [], agent: "claude" }));
ws.send(JSON.stringify({ type: "task.create", goal: otherGoal.id, title: `Rate-limit elsewhere ${word}`, brief: "In the other goal.", shareable: true, plan: false, tickets: [], agent: "claude" }));
await sleep(800);
const mine = [...tasksSeen.values()].filter((t) => t.goal === goal.id);
const rateTask = mine.find((t) => t.title.startsWith("Rate-limit"));
check(mine.length === 2 && Boolean(rateTask), `tasks to search (${mine.map((t) => t.id).join(", ")})`);

const docsOnly = await personal("Old docs token", ["docs:read", "docs:write"]);
const docsTools = (await mcp(docsOnly.token, "tools/list")).body?.result?.tools?.map((t) => t.name) ?? [];
check(docsTools.length === 7 && !docsTools.some((n) => /task|goal/.test(n)), "a docs-only token still lists 7 doc tools and no task tool");
const docsRefused = await call(docsOnly.token, "list_tasks", { q: word });
check(docsRefused.body?.result?.isError === true && /tasks:read/.test(textOf(docsRefused)), "a docs-only token is refused list_tasks");
check((await call(docsOnly.token, "propose_tasks", { goal: prefix, tasks: [{ title: "x", brief: "y" }] })).body?.result?.isError === true, "and propose_tasks");

const tr = await personal("Cursor (tasks, read-only)", ["tasks:read"]);
const trTools = (await mcp(tr.token, "tools/list")).body?.result?.tools?.map((t) => t.name) ?? [];
check(trTools.join(",") === "list_goals,list_tasks,get_task", `tasks:read lists 3 tools (${trTools.join(", ")})`);
const gFound = dataOf(await call(tr.token, "list_goals", { q: `mcp tasks ${stamp}` }));
check(gFound?.length === 1 && gFound[0].id === goal.id && gFound[0].openTasks === 2 && gFound[0].repos[0] === repo, `list_goals {q} returns only the matching goal (${gFound?.map((g) => g.name).join(", ")}, ${gFound?.[0]?.openTasks} open)`);
const byPrefix = dataOf(await call(tr.token, "list_goals", { q: prefix.toLowerCase() }));
check(byPrefix?.length === 1 && byPrefix[0].prefix === prefix, "list_goals {q} finds a goal by its prefix, whatever the case");
const everywhere = dataOf(await call(tr.token, "list_tasks", { q: word }));
check(everywhere?.length === 3, `list_tasks {q} finds the word in titles and briefs across goals (${everywhere?.map((t) => t.id).join(", ")})`);
const tFound = dataOf(await call(tr.token, "list_tasks", { q: `RATE ${word} mcp`, goal: prefix, state: "open" }));
check(tFound?.length === 1 && tFound[0].id === rateTask.id && tFound[0].goal.prefix === prefix && tFound[0].state === "drafting", `list_tasks {q, goal, state} returns only the matching task (${tFound?.map((t) => `${t.id} ${t.title}`).join("; ")})`);
check(dataOf(await call(tr.token, "list_tasks", { q: word, goal: prefix, state: "merged" }))?.length === 0, "list_tasks {state: merged} leaves the drafts out");
const byId = dataOf(await call(tr.token, "list_tasks", { q: rateTask.id.toLowerCase() }));
check(byId?.[0]?.id === rateTask.id, "list_tasks {q} finds a task by its id");
const capped = await call(tr.token, "list_tasks", { q: word, limit: 2 });
check(dataOf(capped)?.length === 2 && /^2 of 3 tasks match/.test(textOf(capped)), `a capped list says so (${textOf(capped).split("\n")[0]})`);
const got = dataOf(await call(tr.token, "get_task", { task: rateTask.id }));
check(got?.id === rateTask.id && got.brief.includes("Worker answers") && Array.isArray(got.threads) && Array.isArray(got.events), "get_task reads the task: brief, threads and events");
check(got && !("liveLog" in got) && !("worker" in got) && !("artifacts" in got) && !("stages" in got) && !("diff" in got), "get_task is a trimmed view: no logs, worker, artifacts, stages or diff");
const roPropose = await call(tr.token, "propose_tasks", { goal: prefix, tasks: [{ title: "Should not exist", brief: "A read-only token asked." }] });
check(roPropose.body?.result?.isError === true && /tasks:write/.test(textOf(roPropose)), "a tasks:read token is refused propose_tasks");
check((await call(tr.token, "comment_on_task", { task: rateTask.id, text: "no" })).body?.result?.isError === true, "and comment_on_task");

const tw = await personal("Claude Code", ["tasks:read", "tasks:write"]);
check((await mcp(tw.token, "tools/list")).body?.result?.tools?.length === 5, "tasks:read + tasks:write lists 5 tools");
const before = tasksSeen.size;
const bad = await call(tw.token, "propose_tasks", { goal: prefix, tasks: [{ title: `Fine ${word}`, brief: "This one is fine." }, { title: `Bad repo ${word}`, brief: "Not in the goal.", repo: "acme/elsewhere" }] });
await sleep(500);
check(bad.body?.result?.isError === true && /isn't one of this goal's repos/.test(textOf(bad)) && tasksSeen.size === before, `a proposal with a repo outside the goal makes no drafts (${textOf(bad)})`);
const forward = await call(tw.token, "propose_tasks", { goal: prefix, tasks: [{ title: "First", brief: "b", after: ["#2"] }, { title: "Second", brief: "b" }] });
check(forward.body?.result?.isError === true && tasksSeen.size === before, "nor does one waiting on a later proposal");
const proposal = await call(tw.token, "propose_tasks", { goal: goalName, tasks: [
  { title: `Token budget table ${word}`, brief: "Count writes per token.", repo, priority: "p2", effort: "MCP limits" },
  { title: `Refuse over-budget calls ${word}`, brief: "Answer 429 past the budget.", after: ["#1"], effort: "MCP limits" },
] });
await sleep(800);
const made = dataOf(proposal)?.made ?? [];
const [first, second] = made.map((id) => tasksSeen.get(id));
check(!proposal.body?.result?.isError && made.length === 2, `a tasks:write token proposes two tasks (${textOf(proposal).split("\n").slice(0, 3).join(" | ")})`);
check(first?.state === "drafting" && second?.state === "drafting" && !first.worker && !second.worker && first.plan.length === 0, "both are drafts: state drafting, no session, not planning");
check(first?.owner === "dev" && second?.owner === "dev", `owned by the member (${first?.owner})`);
check(second?.after?.length === 1 && second.after[0] === first?.id && first?.after?.length === 0, `the second waits on the first (${second?.id} after ${second?.after?.join(", ")})`);
check(first?.repo === repo && first?.priority === "p2" && first?.effort === "MCP limits" && /Proposed by Claude Code via MCP\.$/.test(first.brief), "with its repo, priority, effort and 'Proposed by Claude Code via MCP.'");
check(first?.events?.some((e) => e.who === "dev" && /proposed via Claude Code \(MCP\)/.test(e.text)), "its history says 'proposed via Claude Code (MCP)'");
const refound = dataOf(await call(tw.token, "list_tasks", { q: `budget ${word}`, goal: prefix, state: "drafting", mine: true }));
check(refound?.length === 2 && refound.every((t) => made.includes(t.id)), `list_tasks {q} then finds the drafts (${refound?.map((t) => t.id).join(", ")})`);
await sleep(1500);
check([first, second].every((t) => tasksSeen.get(t.id).state === "drafting"), "and they stay drafts: nothing sent them to planning");

const said = await call(tw.token, "comment_on_task", { task: rateTask.id, text: "From an outside MCP client: is 60 writes a minute enough?" });
await sleep(500);
const landed = tasksSeen.get(rateTask.id)?.comments?.find((c) => c.id === dataOf(said)?.comment);
check(!said.body?.result?.isError && landed?.author === "dev" && landed?.via === "Claude Code via MCP", `comment_on_task shows as the member with the badge (${landed?.author}, ${landed?.via})`);
const answered = await call(tw.token, "comment_on_task", { task: rateTask.id, text: "And a reply in the same thread.", thread: landed?.id });
await sleep(500);
check(tasksSeen.get(rateTask.id)?.comments?.some((c) => c.replyTo === landed?.id && c.via === "Claude Code via MCP"), `a reply lands in the thread (${textOf(answered).split("\n")[0]})`);
check((await call(tw.token, "comment_on_task", { task: "NOPE-1", text: "x" })).body?.result?.isError === true, "commenting on a task that isn't there is an error");
const readBack = dataOf(await call(tw.token, "get_task", { task: rateTask.id }));
check(readBack?.threads?.[0]?.comments?.length === 2 && readBack.threads[0].comments[0].via === "Claude Code via MCP", "get_task shows the thread with its badge");
if (process.env.MCP_E2E_KEEP) console.log(`kept: ${JSON.stringify({ task: rateTask.id, goal: goal.id, prefix })}`);

ws.close();
console.log(failures ? `${failures} failed` : "all ok");
process.exit(failures ? 1 : 0);

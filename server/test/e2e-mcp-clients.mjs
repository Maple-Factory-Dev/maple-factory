// Outside MCP clients at /mcp (src/mcp.ts, src/mcp-auth.ts), against `wrangler dev` with DEV_LOGIN:
//   node server/test/e2e-mcp-clients.mjs http://localhost:8788
// Checks: a read-only personal token sees 2 tools and can't comment; a write token comments and suggests, shown as
// the member with a "via MCP" badge; a revoked token gets 401; the OAuth flow (register, authorize, code + PKCE,
// token, refresh) issues a working token; app tokens don't work at /mcp nor MCP tokens at /api; and revoking a
// member (members.revoke) cuts off their OAuth tokens.

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

ws.close();
console.log(failures ? `${failures} failed` : "all ok");
process.exit(failures ? 1 : 0);

// The factory's MCP server (src/mcp.ts) and its auth (src/mcp-auth.ts): PKCE, redirect URI rules, scope → tool
// filtering, and that app tokens (mft_) and MCP tokens (mfp_) each only work where they belong.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { d1 } from "./d1.ts";
import { bearerKind, mcpCaller, parseScopes, redirectUriOk, verifyPkce } from "../src/mcp-auth.ts";
import { toolAllowed, toolsForScopes } from "../src/mcp-tools.ts";
import { currentMember } from "../src/auth.ts";
import { sha256 } from "../src/util.ts";

const b64url = (b: Buffer) => b.toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

test("PKCE S256: the verifier's hash is the challenge; anything else fails", async () => {
  const verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
  const challenge = b64url(createHash("sha256").update(verifier).digest());
  assert.equal(challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"); // RFC 7636 appendix B
  assert.equal(await verifyPkce(verifier, challenge), true);
  assert.equal(await verifyPkce(verifier.replace(/.$/, "Y"), challenge), false);
  assert.equal(await verifyPkce("short", b64url(createHash("sha256").update("short").digest())), false);
  assert.equal(await verifyPkce(verifier, ""), false);
  assert.equal(await verifyPkce(challenge, challenge), false, "the challenge itself (plain) isn't a verifier");
});

test("redirect URIs: https anywhere, http only on loopback, no fragments or credentials", () => {
  for (const ok of ["https://claude.ai/api/mcp/auth_callback", "http://localhost:3334/callback", "http://127.0.0.1:9999/cb", "http://[::1]:8080/cb"]) assert.ok(redirectUriOk(ok), ok);
  for (const bad of ["http://evil.example/cb", "javascript:alert(1)", "data:text/html,x", "https://a.example/cb#frag", "https://u:p@a.example/cb",
    "http://localhost.evil.example/cb", "file:///etc/passwd", "not a url", 42, `https://a.example/${"x".repeat(2001)}`]) assert.equal(redirectUriOk(bad), false, String(bad));
});

test("scopes: known ones only; tools/list and tools/call follow them", () => {
  assert.deepEqual(parseScopes(""), ["docs:read"]);
  assert.deepEqual(parseScopes("docs:write admin docs:read docs:write"), ["docs:read", "docs:write"]);
  assert.deepEqual(parseScopes("admin"), []);
  assert.deepEqual(toolsForScopes(["docs:read"]).map((t) => t.name), ["list_docs", "read_doc"]);
  assert.deepEqual(toolsForScopes(["docs:write"]).map((t) => t.name),
    ["comment_on_doc", "reply_to_doc_thread", "resolve_doc_thread", "suggest_doc_edit", "propose_decision"]);
  assert.equal(toolsForScopes(["docs:read", "docs:write"]).length, 7);
  assert.equal(toolAllowed(["docs:read"], "comment_on_doc"), false);
  assert.equal(toolAllowed(["docs:read", "docs:write"], "save_repo_setup"), false, "only doc tools, ever");
  assert.equal(toolAllowed(["docs:read"], "__proto__"), false);
});

test("token kinds: mfp_ only at /mcp, mft_ never there", async () => {
  assert.equal(bearerKind("Bearer mfp_abc"), "mcp");
  assert.equal(bearerKind("Bearer mft_abc"), "app");
  const DB = d1();
  const now = Date.now();
  DB.sql.prepare("INSERT INTO members (login, github_id, role, teams, created_at, last_seen, checked_at) VALUES ('alice', 1, 'member', '[]', ?, ?, ?)").run(now, now, now);
  const app = "mft_appappappappappappappappappappappappapp";
  const mcp = "mfp_mcpmcpmcpmcpmcpmcpmcpmcpmcpmcpmcpmcpmcp";
  DB.sql.prepare("INSERT INTO app_tokens (token_hash, login, created_at, expires_at) VALUES (?, 'alice', ?, ?)").run(await sha256(app), now, now + 1e6);
  DB.sql.prepare("INSERT INTO mcp_tokens (id, token_hash, login, kind, label, scopes, created_at) VALUES ('t1', ?, 'alice', 'personal', 'Cursor', 'docs:read', ?)").run(await sha256(mcp), now);
  const env = { DB, GITHUB_ORG: "acme", DEV_LOGIN: "alice" } as never;
  const at = (path: string, token: string) => new Request(`http://localhost:8788${path}`, { headers: { authorization: `Bearer ${token}` } });

  const caller = await mcpCaller(at("/mcp", mcp), env);
  assert.equal(caller?.member.login, "alice");
  assert.deepEqual(caller?.scopes, ["docs:read"]);
  assert.equal(caller?.client, "Cursor");
  assert.equal(await mcpCaller(at("/mcp", app), env), null, "an app token isn't an MCP token");
  assert.equal(await mcpCaller(at("/mcp", "mfp_unknown"), env), null);
  assert.equal((await currentMember(at("/api/me", app), env))?.login, "alice");
  // Even local dev's DEV_LOGIN fallback doesn't sign in an MCP token.
  assert.equal(await currentMember(at("/api/me", mcp), env), null, "an MCP token isn't an app token");

  // Expired, or issued before a revocation, it's refused.
  DB.sql.prepare("UPDATE members SET revoked_at = ? WHERE login = 'alice'").run(now + 1);
  assert.equal(await mcpCaller(at("/mcp", mcp), env), null, "revoked");
  DB.sql.prepare("UPDATE members SET revoked_at = NULL").run();
  DB.sql.prepare("UPDATE mcp_tokens SET expires_at = ?").run(now - 1);
  assert.equal(await mcpCaller(at("/mcp", mcp), env), null, "expired");
});

test("SECURITY-AUDIT.md covers MCP: every new route in the route table, each finding resolved or a follow-up", async () => {
  const { readFileSync } = await import("node:fs");
  const audit = readFileSync(new URL("../SECURITY-AUDIT.md", import.meta.url), "utf8");
  const table = audit.slice(audit.indexOf("### Worker"), audit.indexOf("### Durable Objects"));
  for (const route of ["`/mcp`", "`/.well-known/oauth-protected-resource`", "`/.well-known/oauth-authorization-server`", "`/oauth/register`", "`/oauth/authorize`", "`/oauth/token`", "`/api/mcp-tokens`"]) {
    assert.ok(table.includes(route), `${route} is in the route table`);
  }
  assert.ok(audit.includes("## MCP: outside clients at `/mcp`"));
  for (let n = 22; n <= 30; n++) {
    const row = new RegExp(`^\\| F-${n} \\|.*\\| (fixed|follow-up|no change)[^|]*\\|$`, "m");
    assert.ok(row.test(audit), `F-${n} has a status`);
    assert.ok(new RegExp(`^### F-${n} · .* — (fixed|follow-up|no change)`, "m").test(audit), `F-${n} has a section`);
  }
  assert.match(audit, /\*\*Update \(MF-369\):\*\* MCP tokens/, "F-04 notes MCP tokens are revocable");
});

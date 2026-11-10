// Who an outside MCP client (Claude Desktop, claude.ai, Claude Code, Cursor) is acting as at /mcp, and how it gets
// a token: OAuth 2.1 (authorization code + PKCE S256, dynamic client registration, RFC 9728 protected-resource
// metadata) per the MCP authorization spec, or a personal token a member makes in Settings › Connected apps.
// Tokens are `mfp_…` (with `mfr_…` refresh tokens), kept as sha256 only, accepted only at /mcp (currentMember never
// takes them) and carry docs:read and/or docs:write. App tokens (`mft_…`) are never accepted here. A member's
// tokens go with revokeMember (auth.ts) and are refused once their access was revoked. See SECURITY-AUDIT.md §MCP.

import type { Env } from "./env.ts";
import { currentMember, revoked, stillMember, toMember, type MemberRow } from "./auth.ts";
import type { Member } from "./wire.ts";
import { audit, b64url, html, publicOrigin, randomToken, readCapped, sha256, sign, text, verify } from "./util.ts";

export const SCOPES = ["docs:read", "docs:write"] as const;
export type Scope = (typeof SCOPES)[number];
const ACCESS_TTL = 3600 * 1000;
const REFRESH_TTL = 30 * 24 * 3600 * 1000;
const CODE_TTL = 60 * 1000;
const CONSENT_TTL = 600; // seconds
/** Dynamic registration's limits: per request and in all. */
const MAX_REGISTRATION = 8 * 1024;
const MAX_REDIRECTS = 5;
const MAX_CLIENTS = 1000;
const MAX_LABEL = 80;
const MAX_TOKENS_PER_MEMBER = 50;

export interface McpCaller {
  member: Member;
  scopes: Scope[];
  /** Who's calling, for the agent badge: the OAuth client's name or the personal token's label. */
  client: string;
  tokenId: string;
}

/** The scopes in a space-separated list that we know, deduplicated and in order; an empty ask is docs:read. */
export function parseScopes(asked: string | null | undefined): Scope[] {
  const words = (asked ?? "").split(/\s+/).filter(Boolean);
  if (!words.length) return ["docs:read"];
  return SCOPES.filter((s) => words.includes(s));
}

/** RFC 7636 S256: base64url(sha256(verifier)) is the challenge. The verifier is 43–128 unreserved characters. */
export async function verifyPkce(verifier: string, challenge: string): Promise<boolean> {
  if (!/^[A-Za-z0-9\-._~]{43,128}$/.test(verifier) || !challenge) return false;
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  return b64url(digest) === challenge;
}

/** A redirect URI a client may register: https anywhere, or http on a loopback address (native apps, RFC 8252);
 *  no fragment, no credentials, at most 2,000 characters. */
export function redirectUriOk(uri: unknown): uri is string {
  if (typeof uri !== "string" || uri.length > 2000) return false;
  let u: URL;
  try {
    u = new URL(uri);
  } catch {
    return false;
  }
  if (u.hash || u.username || u.password || uri.includes("#")) return false;
  if (u.protocol === "https:") return true;
  return u.protocol === "http:" && ["localhost", "127.0.0.1", "[::1]"].includes(u.hostname);
}

/** Which kind of token an Authorization header carries. */
export function bearerKind(header: string | null): "mcp" | "app" | "other" | null {
  const m = /^Bearer\s+(\S+)$/.exec(header ?? "");
  if (!m) return null;
  return m[1].startsWith("mfp_") ? "mcp" : m[1].startsWith("mft_") ? "app" : "other";
}

const bearerOf = (request: Request) => /^Bearer (mfp_[\w-]+)$/.exec(request.headers.get("authorization") ?? "")?.[1];

/** The member a `Bearer mfp_…` acts as, with its scopes, or null: unknown, expired, revoked or no longer a member. */
export async function mcpCaller(request: Request, env: Env): Promise<McpCaller | null> {
  const token = bearerOf(request);
  if (!token) return null;
  const hash = await sha256(token);
  const now = Date.now();
  const row = await env.DB.prepare(
    `SELECT m.*, t.id AS t_id, t.scopes AS t_scopes, t.label AS t_label, t.created_at AS t_created, c.name AS c_name
     FROM mcp_tokens t JOIN members m ON m.login = t.login LEFT JOIN oauth_clients c ON c.id = t.client_id
     WHERE t.token_hash = ? AND (t.expires_at IS NULL OR t.expires_at > ?)`,
  ).bind(hash, now).first<MemberRow & { t_id: string; t_scopes: string; t_label: string | null; t_created: number; c_name: string | null }>();
  if (!row) return null;
  // revokeMember deletes the rows; this also refuses any made before a revocation they haven't signed in since.
  if (revoked(row) || (row.revoked_at !== null && row.t_created <= row.revoked_at)) return null;
  const still = await stillMember(env, row);
  if (!still) return null;
  await env.DB.prepare("UPDATE mcp_tokens SET last_used = ? WHERE id = ?").bind(now, row.t_id).run();
  return { member: toMember(still), scopes: parseScopes(row.t_scopes), client: row.c_name ?? row.t_label ?? "MCP client", tokenId: row.t_id };
}

/** The 401 /mcp sends: where to find out how to get a token (RFC 9728 §5.1). */
export function unauthorized(request: Request, env: Env, given: boolean): Response {
  const origin = publicOrigin(request, env);
  const error = given ? `, error="invalid_token"` : "";
  return new Response(JSON.stringify({ jsonrpc: "2.0", id: null, error: { code: -32001, message: given ? "That token isn't valid any more." : "Sign in first." } }), {
    status: 401,
    headers: { "content-type": "application/json", "www-authenticate": `Bearer resource_metadata="${origin}/.well-known/oauth-protected-resource"${error}` },
  });
}

// ---- metadata, registration, authorize, token --------------------------------

const CORS = { "access-control-allow-origin": "*", "access-control-allow-headers": "authorization, content-type, mcp-protocol-version", "access-control-allow-methods": "GET, POST, OPTIONS" };
const json = (body: unknown, status = 200, extra: Record<string, string> = {}) =>
  Response.json(body, { status, headers: { "cache-control": "no-store", ...CORS, ...extra } });
const oauthError = (error: string, description: string, status = 400) => json({ error, error_description: description }, status);

/** What signs the consent form: the session secret, or in local dev a fixed one. */
function consentSecret(env: Env, request: Request): string | null {
  if (env.SESSION_SECRET) return env.SESSION_SECRET;
  const host = new URL(request.url).hostname;
  return env.DEV_LOGIN && (host === "localhost" || host === "127.0.0.1") ? "maple-dev-consent" : null;
}

interface Client { id: string; name: string; redirect_uris: string }

async function client(env: Env, id: string | null): Promise<Client | null> {
  if (!id || id.length > 64) return null;
  return env.DB.prepare("SELECT * FROM oauth_clients WHERE id = ?").bind(id).first<Client>();
}

/** Issues a token pair for a grant (a new row, or `id`'s row rotated in place). */
async function issue(env: Env, grant: { id?: string; login: string; clientId: string; scopes: Scope[] }) {
  const access = randomToken("mfp");
  const refresh = randomToken("mfr");
  const now = Date.now();
  if (grant.id) {
    await env.DB.prepare("UPDATE mcp_tokens SET token_hash = ?, refresh_hash = ?, expires_at = ?, refresh_expires_at = ? WHERE id = ?")
      .bind(await sha256(access), await sha256(refresh), now + ACCESS_TTL, now + REFRESH_TTL, grant.id).run();
  } else {
    await env.DB.prepare(
      `INSERT INTO mcp_tokens (id, token_hash, login, kind, client_id, scopes, created_at, expires_at, refresh_hash, refresh_expires_at)
       VALUES (?, ?, ?, 'oauth', ?, ?, ?, ?, ?, ?)`,
    ).bind(crypto.randomUUID(), await sha256(access), grant.login, grant.clientId, grant.scopes.join(" "), now, now + ACCESS_TTL, await sha256(refresh), now + REFRESH_TTL).run();
  }
  return { access_token: access, token_type: "Bearer", expires_in: ACCESS_TTL / 1000, refresh_token: refresh, scope: grant.scopes.join(" ") };
}

async function formOf(request: Request, max = 16 * 1024): Promise<URLSearchParams | null> {
  const body = await readCapped(request, max);
  if (!body) return null;
  const raw = new TextDecoder().decode(body);
  if ((request.headers.get("content-type") ?? "").includes("application/json")) {
    try {
      const o = JSON.parse(raw) as Record<string, unknown>;
      return new URLSearchParams(Object.entries(o).filter(([, v]) => typeof v === "string") as [string, string][]);
    } catch {
      return null;
    }
  }
  return new URLSearchParams(raw);
}

const esc = (s: string) => s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

/** Everything under /.well-known/oauth-*, /oauth/* and /api/mcp-tokens; null for any other path. */
export async function handleMcpAuth(request: Request, env: Env): Promise<Response | null> {
  const url = new URL(request.url);
  const path = url.pathname;
  const origin = publicOrigin(request, env);
  const ours = path.startsWith("/.well-known/oauth-") || path.startsWith("/oauth/");
  if (ours && request.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });

  if (path === "/.well-known/oauth-protected-resource" || path === "/.well-known/oauth-protected-resource/mcp") {
    return json({ resource: `${origin}/mcp`, authorization_servers: [origin], scopes_supported: SCOPES, bearer_methods_supported: ["header"], resource_name: "Maple Factory docs" });
  }
  if (path === "/.well-known/oauth-authorization-server" || path === "/.well-known/oauth-authorization-server/mcp") {
    return json({
      issuer: origin,
      authorization_endpoint: `${origin}/oauth/authorize`,
      token_endpoint: `${origin}/oauth/token`,
      registration_endpoint: `${origin}/oauth/register`,
      response_types_supported: ["code"],
      grant_types_supported: ["authorization_code", "refresh_token"],
      code_challenge_methods_supported: ["S256"],
      token_endpoint_auth_methods_supported: ["none"],
      scopes_supported: SCOPES,
    });
  }

  if (path === "/oauth/register" && request.method === "POST") {
    const body = await readCapped(request, MAX_REGISTRATION);
    if (!body) return oauthError("invalid_client_metadata", `At most ${MAX_REGISTRATION} bytes.`, 413);
    let meta: { client_name?: unknown; redirect_uris?: unknown };
    try {
      meta = JSON.parse(new TextDecoder().decode(body));
    } catch {
      return oauthError("invalid_client_metadata", "Expected JSON.");
    }
    const uris = meta.redirect_uris;
    if (!Array.isArray(uris) || !uris.length || uris.length > MAX_REDIRECTS || !uris.every(redirectUriOk)) {
      return oauthError("invalid_redirect_uri", `1–${MAX_REDIRECTS} redirect URIs, each https or http on localhost/127.0.0.1.`);
    }
    const name = typeof meta.client_name === "string" && meta.client_name.trim() ? meta.client_name.trim().slice(0, MAX_LABEL) : "MCP client";
    const count = (await env.DB.prepare("SELECT COUNT(*) AS n FROM oauth_clients").first<{ n: number }>())?.n ?? 0;
    if (count >= MAX_CLIENTS) {
      // Clients nobody ever authorized go first; if none are left to drop, registration is closed.
      await env.DB.prepare(`DELETE FROM oauth_clients WHERE id IN (SELECT id FROM oauth_clients c WHERE NOT EXISTS
        (SELECT 1 FROM mcp_tokens t WHERE t.client_id = c.id) ORDER BY created_at LIMIT 100)`).run();
      const left = (await env.DB.prepare("SELECT COUNT(*) AS n FROM oauth_clients").first<{ n: number }>())?.n ?? 0;
      if (left >= MAX_CLIENTS) return oauthError("invalid_client_metadata", "Too many registered clients.", 429);
    }
    const id = `mcpc_${crypto.randomUUID()}`;
    const now = Date.now();
    await env.DB.prepare("INSERT INTO oauth_clients (id, name, redirect_uris, created_at) VALUES (?, ?, ?, ?)").bind(id, name, JSON.stringify(uris), now).run();
    await audit(env, "oauth", "mcp.client_registered", id, { name });
    return json({
      client_id: id, client_id_issued_at: Math.floor(now / 1000), client_name: name, redirect_uris: uris,
      token_endpoint_auth_method: "none", grant_types: ["authorization_code", "refresh_token"], response_types: ["code"],
    }, 201);
  }

  if (path === "/oauth/authorize" && (request.method === "GET" || request.method === "POST")) return authorize(request, env, url, origin);

  if (path === "/oauth/token" && request.method === "POST") {
    const form = await formOf(request);
    if (!form) return oauthError("invalid_request", "Unreadable or too large.");
    const grant = form.get("grant_type");
    const clientId = form.get("client_id");
    if (grant === "authorization_code") {
      const code = form.get("code") ?? "";
      // Single use: the row goes as it's read, so a replayed code finds nothing.
      const row = await env.DB.prepare("DELETE FROM oauth_codes WHERE code_hash = ? RETURNING *").bind(await sha256(code))
        .first<{ client_id: string; login: string; scopes: string; code_challenge: string; redirect_uri: string; expires_at: number }>();
      if (!row || row.expires_at < Date.now()) return oauthError("invalid_grant", "That code is unknown, used or expired.");
      if (row.client_id !== clientId) return oauthError("invalid_grant", "That code was issued to another client.");
      if (row.redirect_uri !== form.get("redirect_uri")) return oauthError("invalid_grant", "redirect_uri doesn't match the one authorized.");
      if (!(await verifyPkce(form.get("code_verifier") ?? "", row.code_challenge))) return oauthError("invalid_grant", "PKCE verification failed.");
      const member = await env.DB.prepare("SELECT * FROM members WHERE login = ?").bind(row.login).first<MemberRow>();
      if (!member || revoked(member)) return oauthError("invalid_grant", "That member's access was revoked.");
      const out = await issue(env, { login: row.login, clientId: row.client_id, scopes: parseScopes(row.scopes) });
      await audit(env, row.login, "mcp.token_issued", row.client_id, { kind: "oauth", scopes: row.scopes });
      return json(out);
    }
    if (grant === "refresh_token") {
      const row = await env.DB.prepare("SELECT * FROM mcp_tokens WHERE refresh_hash = ? AND kind = 'oauth'").bind(await sha256(form.get("refresh_token") ?? ""))
        .first<{ id: string; login: string; client_id: string; scopes: string; refresh_expires_at: number }>();
      if (!row || row.refresh_expires_at < Date.now() || row.client_id !== clientId) return oauthError("invalid_grant", "That refresh token is unknown, used or expired.");
      const member = await env.DB.prepare("SELECT * FROM members WHERE login = ?").bind(row.login).first<MemberRow>();
      if (!member || revoked(member)) return oauthError("invalid_grant", "That member's access was revoked.");
      // Rotated in place: the old access and refresh tokens stop working now.
      return json(await issue(env, { id: row.id, login: row.login, clientId: row.client_id, scopes: parseScopes(row.scopes) }));
    }
    return oauthError("unsupported_grant_type", "authorization_code or refresh_token.");
  }

  if (path === "/api/mcp-tokens" || path.startsWith("/api/mcp-tokens/")) return tokensApi(request, env, path);
  if (ours) return text("Not found.", 404);
  return null;
}

/** GET shows the consent page; POST (same origin, with the signed form) approves or denies it. Errors about the
 *  client or redirect URI are shown here and never redirected (no open redirect). */
async function authorize(request: Request, env: Env, url: URL, origin: string): Promise<Response> {
  const secret = consentSecret(env, request);
  if (!secret) return text("Sign-in isn't set up on this factory yet.", 503);
  const params = request.method === "POST" ? await formOf(request) : url.searchParams;
  if (!params) return text("Unreadable request.", 400);
  if (request.method === "POST") {
    // The approve button: our own page posting back, signed in as the member it was signed for.
    const o = request.headers.get("origin");
    if (!o || o !== new URL(request.url).origin) return text("Bad origin.", 403);
  }
  const c = await client(env, params.get("client_id"));
  if (!c) return text("Unknown client. Add the connector again so it can register.", 400);
  const redirect = params.get("redirect_uri") ?? "";
  if (!(JSON.parse(c.redirect_uris) as string[]).includes(redirect)) return text("That redirect URI isn't one this client registered.", 400);
  const back = (q: Record<string, string>) => {
    const to = new URL(redirect);
    for (const [k, v] of Object.entries(q)) to.searchParams.set(k, v);
    const state = params.get("state");
    if (state) to.searchParams.set("state", state);
    to.searchParams.set("iss", origin);
    return new Response(null, { status: 302, headers: { location: to.toString(), "cache-control": "no-store" } });
  };
  if (params.get("response_type") !== "code") return back({ error: "unsupported_response_type" });
  const challenge = params.get("code_challenge") ?? "";
  if (params.get("code_challenge_method") !== "S256" || !/^[A-Za-z0-9_-]{43}$/.test(challenge)) return back({ error: "invalid_request", error_description: "PKCE with S256 is required." });
  const scopes = parseScopes(params.get("scope"));
  if (!scopes.length) return back({ error: "invalid_scope" });

  const me = request.headers.get("authorization") ? null : await currentMember(request, env);
  if (!me) {
    if (request.method === "POST") return text("Sign in first.", 401);
    const next = `/oauth/authorize?${url.searchParams.toString().replace(/\+/g, "%20")}`;
    return new Response(null, { status: 302, headers: { location: `/auth/login?next=${encodeURIComponent(next)}` } });
  }
  const bound = { login: me.login, client: c.id, redirect, challenge, scopes: scopes.join(" ") };

  if (request.method === "POST") {
    const signed = await verify<typeof bound & { exp: number }>(params.get("consent") ?? undefined, secret);
    if (!signed || signed.login !== bound.login || signed.client !== bound.client || signed.redirect !== bound.redirect
      || signed.challenge !== bound.challenge || signed.scopes !== bound.scopes) return text("That approval expired or wasn't for this. Start again from the app.", 400);
    if (params.get("decision") !== "approve") {
      await audit(env, me.login, "mcp.oauth_denied", c.id);
      return back({ error: "access_denied" });
    }
    const code = randomToken("mfc");
    await env.DB.prepare("INSERT INTO oauth_codes (code_hash, client_id, login, scopes, code_challenge, redirect_uri, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)")
      .bind(await sha256(code), c.id, me.login, bound.scopes, challenge, redirect, Date.now() + CODE_TTL).run();
    await audit(env, me.login, "mcp.oauth_approved", c.id, { scopes: bound.scopes });
    return back({ code });
  }

  const consent = await sign({ ...bound, exp: Math.floor(Date.now() / 1000) + CONSENT_TTL }, secret);
  const hidden = (k: string, v: string) => `<input type="hidden" name="${k}" value="${esc(v)}">`;
  const fields = ["client_id", "redirect_uri", "response_type", "code_challenge", "code_challenge_method", "state", "scope", "resource"]
    .filter((k) => params.get(k) !== null).map((k) => hidden(k, params.get(k)!)).join("");
  const can = scopes.map((s) => `<li>${s === "docs:read" ? "List and read the org's shared docs" : "Comment on docs, reply to and resolve threads, suggest edits and propose decisions (never edit text directly)"}</li>`).join("");
  return html(`<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Connect ${esc(c.name)}</title>
<style>body{font:15px/1.5 system-ui,sans-serif;max-width:32rem;margin:10vh auto;padding:0 16px;color:#222;background:#fafafa}@media(prefers-color-scheme:dark){body{background:#161616;color:#eee}}
.card{border:1px solid #8884;border-radius:12px;padding:20px 24px}button{font:inherit;padding:8px 16px;border-radius:8px;border:1px solid #8886;margin-right:8px;cursor:pointer}
.go{background:#c2410c;color:#fff;border-color:#c2410c}.muted{opacity:.7;font-size:13px}code{word-break:break-all}</style>
<div class="card"><h1 style="font-size:20px;margin-top:0">Let <strong>${esc(c.name)}</strong> act as ${esc(me.login)}?</h1>
<p>It will be able to:</p><ul>${can}</ul>
<p class="muted">Anything it writes shows as you, with a “${esc(c.name)} via MCP” badge. It will send you back to <code>${esc(redirect)}</code>. You can revoke it any time in Settings › Connected apps.</p>
<form method="post" action="/oauth/authorize">${fields}${hidden("consent", consent)}
<button class="go" name="decision" value="approve" type="submit">Allow</button><button name="decision" value="deny" type="submit">Deny</button></form></div>`);
}

// ---- personal tokens and the Connected apps list ---------------------------

interface TokenRow { id: string; kind: string; client_id: string | null; c_name: string | null; label: string | null; scopes: string; created_at: number; expires_at: number | null; refresh_expires_at: number | null; last_used: number | null }

/** GET: your tokens and OAuth grants. POST {label, scopes}: a new personal token, shown once. DELETE /:id: revoke.
 *  Web sessions only (no bearer token of any kind), and same origin. */
async function tokensApi(request: Request, env: Env, path: string): Promise<Response> {
  if (request.headers.get("authorization")) return text("Manage connected apps from the web app's Settings.", 403);
  const o = request.headers.get("origin");
  if (o && o !== new URL(request.url).origin) return text("Bad origin.", 403);
  const me = await currentMember(request, env);
  if (!me) return text("Sign in first.", 401);
  if (path === "/api/mcp-tokens" && request.method === "GET") {
    const { results } = await env.DB.prepare(
      `SELECT t.id, t.kind, t.client_id, c.name AS c_name, t.label, t.scopes, t.created_at, t.expires_at, t.refresh_expires_at, t.last_used
       FROM mcp_tokens t LEFT JOIN oauth_clients c ON c.id = t.client_id WHERE t.login = ? ORDER BY t.created_at DESC`,
    ).bind(me.login).all<TokenRow>();
    return Response.json({
      url: `${publicOrigin(request, env)}/mcp`,
      tokens: results.map((t) => ({
        id: t.id, kind: t.kind, name: t.kind === "oauth" ? (t.c_name ?? "MCP client") : (t.label ?? "Personal token"),
        scopes: parseScopes(t.scopes), createdAt: t.created_at, lastUsed: t.last_used, expiresAt: t.kind === "oauth" ? t.refresh_expires_at : t.expires_at,
      })),
    });
  }
  if (path === "/api/mcp-tokens" && request.method === "POST") {
    if (!o) return text("Bad origin.", 403);
    const body = (await request.json().catch(() => null)) as { label?: unknown; scopes?: unknown } | null;
    const label = typeof body?.label === "string" ? body.label.trim().slice(0, MAX_LABEL) : "";
    const scopes = Array.isArray(body?.scopes) ? SCOPES.filter((s) => (body!.scopes as unknown[]).includes(s)) : [];
    if (!label) return text("Give the token a name, like “Cursor on my laptop”.", 400);
    if (!scopes.length) return text("Pick at least one scope.", 400);
    const n = (await env.DB.prepare("SELECT COUNT(*) AS n FROM mcp_tokens WHERE login = ?").bind(me.login).first<{ n: number }>())?.n ?? 0;
    if (n >= MAX_TOKENS_PER_MEMBER) return text(`You have ${n} connected apps; revoke some first.`, 429);
    const token = randomToken("mfp");
    const id = crypto.randomUUID();
    await env.DB.prepare("INSERT INTO mcp_tokens (id, token_hash, login, kind, label, scopes, created_at) VALUES (?, ?, ?, 'personal', ?, ?, ?)")
      .bind(id, await sha256(token), me.login, label, scopes.join(" "), Date.now()).run();
    await audit(env, me.login, "mcp.token_issued", id, { kind: "personal", label, scopes });
    return Response.json({ id, token, label, scopes, url: `${publicOrigin(request, env)}/mcp` }, { status: 201 });
  }
  const one = /^\/api\/mcp-tokens\/([0-9a-f-]{36})$/.exec(path);
  if (one && request.method === "DELETE") {
    if (!o) return text("Bad origin.", 403);
    const row = await env.DB.prepare("SELECT id FROM mcp_tokens WHERE id = ? AND login = ?").bind(one[1], me.login).first();
    if (!row) return text("No such token.", 404);
    await env.DB.prepare("DELETE FROM mcp_tokens WHERE id = ? AND login = ?").bind(one[1], me.login).run();
    await audit(env, me.login, "mcp.token_revoked", one[1]);
    return new Response(null, { status: 204 });
  }
  return text("Not found.", 404);
}

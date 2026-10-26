// Who may use this factory: members of one GitHub organization (or, when GITHUB_ORG is someone's
// personal account, just them). The web signs in with GitHub's
// OAuth redirect and gets a signed cookie; the apps use GitHub's device flow and get a bearer
// token. Membership is checked with GitHub at every sign-in, and roles and teams come from there.

import type { Env } from "./env.ts";
import type { Member } from "./wire.ts";
import { audit, isLocal, randomToken, sha256, sign, text, verify } from "./util.ts";

const SESSION_TTL = 7 * 24 * 3600; // seconds
const APP_TOKEN_TTL = 30 * 24 * 3600 * 1000; // ms
const STATE_TTL = 600;
const UA = "maple-factory";

export interface MemberRow {
  login: string;
  github_id: number;
  name: string | null;
  avatar_url: string | null;
  role: string;
  teams: string;
}

export function toMember(row: MemberRow): Member {
  return { login: row.login, name: row.name, avatarUrl: row.avatar_url, role: row.role, teams: JSON.parse(row.teams) };
}

function cookieName(url: URL, name: string) {
  return url.protocol === "https:" ? `__Host-maple_${name}` : `maple_${name}`;
}

export function cookie(url: URL, name: string, value: string, maxAge: number) {
  const secure = url.protocol === "https:";
  // Lax so the session survives GitHub's redirect back to us; state-changing APIs check Origin.
  return `${cookieName(url, name)}=${value}; Path=/; HttpOnly; SameSite=Lax; Max-Age=${maxAge}${secure ? "; Secure" : ""}`;
}

export function readCookie(request: Request, name: string): string | undefined {
  const want = cookieName(new URL(request.url), name);
  for (const part of (request.headers.get("cookie") ?? "").split(/;\s*/)) {
    const i = part.indexOf("=");
    if (i > 0 && part.slice(0, i) === want) return part.slice(i + 1);
  }
}

export function authConfigured(env: Env) {
  return Boolean(env.GITHUB_CLIENT_ID && env.GITHUB_CLIENT_SECRET && env.SESSION_SECRET && env.GITHUB_ORG);
}

/** Browsers send Origin on writes and WebSocket upgrades; it must be us. Apps send none. */
export function sameOrigin(request: Request): boolean {
  const origin = request.headers.get("origin");
  return !origin || origin === new URL(request.url).origin;
}

async function memberRow(env: Env, login: string) {
  return env.DB.prepare("SELECT * FROM members WHERE login = ?").bind(login).first<MemberRow>();
}

/** The signed-in member, from a session cookie, an app token, or local dev's DEV_LOGIN. */
export async function currentMember(request: Request, env: Env): Promise<Member | null> {
  const bearer = /^Bearer (mft_[\w-]+)$/.exec(request.headers.get("authorization") ?? "")?.[1];
  if (bearer) {
    const row = await env.DB.prepare(
      `SELECT m.* FROM app_tokens t JOIN members m ON m.login = t.login WHERE t.token_hash = ? AND t.expires_at > ?`,
    ).bind(await sha256(bearer), Date.now()).first<MemberRow>();
    if (!row) return null;
    await env.DB.prepare("UPDATE app_tokens SET last_used = ? WHERE token_hash = ?").bind(Date.now(), await sha256(bearer)).run();
    return toMember(row);
  }
  if (env.SESSION_SECRET) {
    const session = await verify<{ login: string; exp: number }>(readCookie(request, "session"), env.SESSION_SECRET);
    if (session) {
      const row = await memberRow(env, session.login);
      if (row) return toMember(row);
    }
  }
  if (env.DEV_LOGIN && isLocal(request)) {
    await upsertMember(env, { id: 0, login: env.DEV_LOGIN, name: env.DEV_LOGIN, avatar_url: null }, "admin", []);
    return toMember((await memberRow(env, env.DEV_LOGIN))!);
  }
  return null;
}

// ---- GitHub ----------------------------------------------------------------

interface Identity {
  id: number;
  login: string;
  name: string | null;
  avatar_url: string | null;
}

async function github<T>(token: string, path: string): Promise<{ status: number; body: T | null }> {
  const res = await fetch(`https://api.github.com${path}`, {
    headers: { authorization: `Bearer ${token}`, accept: "application/vnd.github+json", "user-agent": UA },
  });
  return { status: res.status, body: (await res.json().catch(() => null)) as T | null };
}

type Verdict = { ok: true; member: Member } | { ok: false; status: number; message: string };

/** Checks a GitHub user token against the org, and records the member if they're in. */
async function admit(env: Env, token: string): Promise<Verdict> {
  const me = await github<Identity>(token, "/user");
  if (!me.body?.login) return { ok: false, status: 502, message: "GitHub didn't say who you are." };
  const org = env.GITHUB_ORG;
  // A personal account's factory: its owner, and nobody else. (No org shares a login with a user.)
  if (me.body.login.toLowerCase() === org.toLowerCase()) {
    await upsertMember(env, me.body, "admin", []);
    return { ok: true, member: toMember((await memberRow(env, me.body.login))!) };
  }
  if (env.GITHUB_OWNER_TYPE === "User") {
    await audit(env, `github:${me.body.login}`, "auth.denied", null, { org, personal: true });
    return { ok: false, status: 403, message: `This factory is ${org}'s own: only ${org} can sign in.` };
  }
  const membership = await github<{ state?: string; role?: string }>(token, `/user/memberships/orgs/${encodeURIComponent(org)}`);
  if (membership.status !== 200 || membership.body?.state !== "active") {
    await audit(env, `github:${me.body.login}`, "auth.denied", null, { org, status: membership.status });
    const hint = membership.status === 403
      ? ` If you are a member, the GitHub App needs read access to organization members, and ${org} must approve it.`
      : "";
    return { ok: false, status: 403, message: `${me.body.login} isn't an active member of ${org}.${hint}` };
  }
  const teams = await github<Array<{ slug: string; organization?: { login?: string } }>>(token, "/user/teams?per_page=100");
  const slugs = (teams.body ?? []).filter((t) => t.organization?.login?.toLowerCase() === org.toLowerCase()).map((t) => t.slug);
  const role = membership.body.role === "admin" ? "admin" : "member";
  await upsertMember(env, me.body, role, slugs);
  return { ok: true, member: toMember((await memberRow(env, me.body.login))!) };
}

async function upsertMember(env: Env, who: Identity, role: string, teams: string[]) {
  await env.DB.prepare(
    `INSERT INTO members (login, github_id, name, avatar_url, role, teams, created_at, last_seen)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7)
     ON CONFLICT (login) DO UPDATE SET github_id = ?2, name = ?3, avatar_url = ?4, role = ?5, teams = ?6, last_seen = ?7`,
  ).bind(who.login, who.id, who.name, who.avatar_url, role, JSON.stringify(teams), Date.now()).run();
}

async function exchange(env: Env, params: Record<string, string>) {
  const res = await fetch("https://github.com/login/oauth/access_token", {
    method: "POST",
    headers: { accept: "application/json", "content-type": "application/json", "user-agent": UA },
    body: JSON.stringify({ client_id: env.GITHUB_CLIENT_ID, client_secret: env.GITHUB_CLIENT_SECRET, ...params }),
  });
  return (await res.json().catch(() => ({}))) as { access_token?: string; error?: string; error_description?: string; interval?: number };
}

// ---- routes ----------------------------------------------------------------

export async function handleAuth(request: Request, env: Env): Promise<Response | null> {
  const url = new URL(request.url);
  if (!url.pathname.startsWith("/auth/")) return null;
  if (url.pathname === "/auth/logout" && request.method === "POST") {
    if (!sameOrigin(request)) return text("Bad origin.", 403);
    return new Response(null, { status: 204, headers: { "set-cookie": cookie(url, "session", "", 0) } });
  }
  if (!authConfigured(env)) return text(`GitHub sign-in isn't set up on this factory yet. An owner can finish it at ${url.origin}/setup.`, 503);

  // Web: OAuth redirect.
  if (url.pathname === "/auth/login") {
    // Where to land after: a path on this site only (the web app's task links).
    const asked = url.searchParams.get("next") ?? "/";
    const next = /^\/(?!\/)[\w\-./#?=&%]*$/.test(asked) ? asked : "/";
    const state = await sign({ nonce: crypto.randomUUID(), next, exp: Math.floor(Date.now() / 1000) + STATE_TTL }, env.SESSION_SECRET!);
    const gh = new URL("https://github.com/login/oauth/authorize");
    gh.searchParams.set("client_id", env.GITHUB_CLIENT_ID!);
    gh.searchParams.set("redirect_uri", `${url.origin}/auth/callback`);
    gh.searchParams.set("state", state);
    return new Response(null, { status: 302, headers: { location: gh.toString(), "set-cookie": cookie(url, "oauth", state, STATE_TTL) } });
  }
  if (url.pathname === "/auth/callback") {
    const state = url.searchParams.get("state") ?? "";
    const code = url.searchParams.get("code") ?? "";
    const signed = await verify<{ exp: number; next?: string }>(state, env.SESSION_SECRET!);
    if (!code || state !== readCookie(request, "oauth") || !signed) {
      return text("That sign-in link expired or didn't come from this browser. Try again.", 400);
    }
    const token = await exchange(env, { code, redirect_uri: `${url.origin}/auth/callback` });
    if (!token.access_token) return text(`GitHub didn't sign you in: ${token.error_description ?? "no token returned"}.`, 502);
    const verdict = await admit(env, token.access_token);
    if (!verdict.ok) return text(verdict.message, verdict.status);
    await audit(env, verdict.member.login, "auth.login", null, { via: "web" });
    const session = await sign({ login: verdict.member.login, exp: Math.floor(Date.now() / 1000) + SESSION_TTL }, env.SESSION_SECRET!);
    const headers = new Headers({ location: signed.next || "/" });
    headers.append("set-cookie", cookie(url, "session", session, SESSION_TTL));
    headers.append("set-cookie", cookie(url, "oauth", "", 0));
    return new Response(null, { status: 302, headers });
  }

  // Apps: device flow. The app shows the code, opens github.com/login/device, and polls.
  if (url.pathname === "/auth/device/start" && request.method === "POST") {
    const res = await fetch("https://github.com/login/device/code", {
      method: "POST",
      headers: { accept: "application/json", "content-type": "application/json", "user-agent": UA },
      body: JSON.stringify({ client_id: env.GITHUB_CLIENT_ID }),
    });
    const body = (await res.json().catch(() => ({}))) as {
      device_code?: string; user_code?: string; verification_uri?: string; interval?: number; expires_in?: number; error_description?: string;
    };
    if (!body.device_code) return text(`GitHub didn't start a sign-in: ${body.error_description ?? res.status}. Is device flow enabled on the GitHub App?`, 502);
    return Response.json({
      deviceCode: body.device_code,
      userCode: body.user_code,
      verificationUri: body.verification_uri,
      interval: body.interval ?? 5,
      expiresIn: body.expires_in ?? 900,
    });
  }
  if (url.pathname === "/auth/device/poll" && request.method === "POST") {
    const { deviceCode, label } = ((await request.json().catch(() => ({}))) ?? {}) as { deviceCode?: string; label?: string };
    if (!deviceCode) return text("Missing deviceCode.", 400);
    const token = await exchange(env, { device_code: deviceCode, grant_type: "urn:ietf:params:oauth:grant-type:device_code" });
    if (token.error === "authorization_pending" || token.error === "slow_down") {
      return Response.json({ pending: true, interval: token.interval }, { status: 202 });
    }
    if (!token.access_token) return text(token.error_description ?? "GitHub didn't sign you in.", 400);
    const verdict = await admit(env, token.access_token);
    if (!verdict.ok) return text(verdict.message, verdict.status);
    const appToken = randomToken("mft");
    await env.DB.prepare("INSERT INTO app_tokens (token_hash, login, label, created_at, expires_at) VALUES (?, ?, ?, ?, ?)")
      .bind(await sha256(appToken), verdict.member.login, label ?? null, Date.now(), Date.now() + APP_TOKEN_TTL).run();
    await audit(env, verdict.member.login, "auth.login", null, { via: "app", label });
    return Response.json({ token: appToken, member: verdict.member, org: env.GITHUB_ORG });
  }
  return null;
}

/** Local dev: an app token for DEV_LOGIN without GitHub, so the Mac app can sign in to `wrangler dev`. */
/** Local dev: an app token for DEV_LOGIN, or (`?as=<login>`) for a made-up teammate, to try multiplayer alone. */
export async function devToken(request: Request, env: Env): Promise<Response> {
  if (!env.DEV_LOGIN || !isLocal(request)) return text("Not found.", 404);
  await currentMember(request, env);
  const as = new URL(request.url).searchParams.get("as");
  if (as && !/^[\w-]{1,39}$/.test(as)) return text("Not a GitHub login.", 400);
  const login = as ?? env.DEV_LOGIN;
  if (as && !(await memberRow(env, as))) await upsertMember(env, { login: as, id: 0, name: null, avatar_url: null }, "member", []);
  const appToken = randomToken("mft");
  await env.DB.prepare("INSERT INTO app_tokens (token_hash, login, label, created_at, expires_at) VALUES (?, ?, 'dev', ?, ?)")
    .bind(await sha256(appToken), login, Date.now(), Date.now() + APP_TOKEN_TTL).run();
  return Response.json({ token: appToken, member: toMember((await memberRow(env, login))!), org: env.GITHUB_ORG || "local" });
}

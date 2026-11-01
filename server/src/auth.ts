// Who may use this factory: members of one GitHub organization (or, when GITHUB_ORG is someone's
// personal account, just them), and anyone in GITHUB_ALLOWED_LOGINS, who signs in as a member. The web signs in with GitHub's
// OAuth redirect and gets a signed cookie; the apps use GitHub's device flow and get a bearer
// token. Membership is checked with GitHub at every sign-in, and again on a request (or, for apps left open, by the
// org hub's alarm) once that check is MEMBERSHIP_RECHECK_MS old; someone who has left is revoked then (revokeMember),
// as an admin can do by hand.
// Roles and teams come from GitHub; an admin can also make someone admin here (members.admin_granted_by),
// which raises their role but never lets them in.

import type { Env } from "./env.ts";
import { API, apiBase, githubApp, GitHubError, orgRole } from "./github.ts";
import type { Member } from "./wire.ts";
import { aesKey, secretsKey } from "./secrets.ts";
import { audit, b64url, isLocal, machineHub, orgHub, randomToken, sha256, sign, text, verify } from "./util.ts";

const SESSION_TTL = 7 * 24 * 3600; // seconds
const APP_TOKEN_TTL = 30 * 24 * 3600 * 1000; // ms
const STATE_TTL = 600;
/** How old a member's last membership check may get before a request asks GitHub again (ms). */
const MEMBERSHIP_RECHECK_MS = 10 * 60 * 1000;
const UA = "maple-factory";

export interface MemberRow {
  login: string;
  github_id: number;
  name: string | null;
  avatar_url: string | null;
  /** GitHub's role, rewritten at each sign-in and membership re-check. */
  role: string;
  teams: string;
  /** Who made them admin here; NULL: nobody. A sign-in leaves it alone. */
  admin_granted_by: string | null;
  /** When their access was revoked (ms); sessions issued before it don't work. NULL: never. */
  revoked_at: number | null;
  /** When GitHub last confirmed they may sign in (ms). */
  checked_at: number | null;
  /** Their last sign-in (ms). */
  last_seen: number | null;
}

/** A member as the apps see them: admin when GitHub says they're an owner, or an admin made them one here. */
export function toMember(row: MemberRow): Member {
  const adminSource = row.role === "admin" ? "github" : row.admin_granted_by ? "granted" : null;
  return {
    login: row.login,
    name: row.name,
    avatarUrl: row.avatar_url,
    role: adminSource ? "admin" : "member",
    teams: JSON.parse(row.teams),
    adminSource,
    adminGrantedBy: row.admin_granted_by,
  };
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

/** GITHUB_ALLOWED_LOGINS, lowercased. */
function allowedLogins(env: Env): Set<string> {
  return new Set((env.GITHUB_ALLOWED_LOGINS ?? "").split(/[\s,]+/).filter(Boolean).map((l) => l.toLowerCase()));
}

/** Whether a signed-in member still may: a personal factory checks its owner and list on every request, so
 *  taking someone off the list signs them out. (An org's members are checked at sign-in.) */
function stillAllowed(env: Env, login: string): boolean {
  if (env.GITHUB_OWNER_TYPE !== "User") return true;
  return login.toLowerCase() === env.GITHUB_ORG.toLowerCase() || allowedLogins(env).has(login.toLowerCase());
}

/** Whether `login` could sign in today: on the list, the personal account's owner, or (asked of GitHub) in the org. */
export async function maySignIn(env: Env, login: string): Promise<boolean> {
  if (env.GITHUB_OWNER_TYPE === "User") return stillAllowed(env, login);
  if (allowedLogins(env).has(login.toLowerCase())) return true;
  const app = githubApp(env);
  if (!app) throw new GitHubError("no_app", "The factory has no GitHub App to ask who's in the org.");
  return (await orgRole(app, env.GITHUB_ORG, login)) !== null;
}

/** The role GitHub gives `login` today, as a sign-in would set it, or null if they couldn't sign in. Someone on the
 *  list who isn't in the org is a member. */
async function githubRole(env: Env, login: string): Promise<"admin" | "member" | null> {
  const listed = allowedLogins(env).has(login.toLowerCase());
  if (env.GITHUB_OWNER_TYPE === "User") return login.toLowerCase() === env.GITHUB_ORG.toLowerCase() ? "admin" : listed ? "member" : null;
  const app = githubApp(env);
  if (!app) throw new GitHubError("no_app", "The factory has no GitHub App to ask who's in the org.");
  return (await orgRole(app, env.GITHUB_ORG, login)) ?? (listed ? "member" : null);
}

async function memberRow(env: Env, login: string) {
  return env.DB.prepare("SELECT * FROM members WHERE login = ?").bind(login).first<MemberRow>();
}

/** Cuts someone off now: their app tokens go, web sessions issued before now stop working, their machines go
 *  offline and can't reconnect (authenticateRunner) until they sign in again, and (with `notify`) the org hub closes
 *  their open sockets and terminals. A later sign-in, if GitHub still lets them, works as usual. */
export async function revokeMember(env: Env, login: string, by: string, notify = true) {
  await env.DB.prepare("DELETE FROM app_tokens WHERE login = ?").bind(login).run();
  await env.DB.prepare("DELETE FROM member_github_tokens WHERE login = ?").bind(login).run();
  await env.DB.prepare("DELETE FROM slack_links WHERE login = ?").bind(login).run();
  await env.DB.prepare("UPDATE members SET revoked_at = ?, admin_granted_by = NULL, admin_granted_at = NULL WHERE login = ?").bind(Date.now(), login).run();
  await audit(env, by, "member.revoked", login);
  const { results } = await env.DB.prepare("SELECT id FROM machines WHERE owner = ?").bind(login).all<{ id: string }>();
  await Promise.all(results.map((m) => machineHub(env, m.id).fetch("https://hub/disconnect", { method: "POST" })));
  if (notify) await orgHub(env).fetch("https://org/revoked", { method: "POST", body: login });
}

/** Whether `row` was revoked and hasn't signed in since (a sign-in sets last_seen). */
export function revoked(row: Pick<MemberRow, "revoked_at" | "last_seen">): boolean {
  return row.revoked_at !== null && (row.last_seen ?? 0) <= row.revoked_at;
}

/** How old a membership check may get (ms): MEMBERSHIP_RECHECK_MS in the env (the e2e tests set 0), else 10 minutes. */
export function recheckEvery(env: Env): number {
  return env.MEMBERSHIP_RECHECK_MS ? Number(env.MEMBERSHIP_RECHECK_MS) : MEMBERSHIP_RECHECK_MS;
}

/** `row` as it stands if they may still use the factory, else null: asks GitHub again once the last answer is
 *  stale, revokes them if they've left, and takes up a role GitHub changed (so a demoted owner stops being an
 *  admin). `notify` tells the org hub of either, which the hub itself skips. checked_at is claimed before the call,
 *  so concurrent requests from one member ask GitHub once; when GitHub can't say, the claim is undone and the last
 *  answer stands, so an outage signs nobody out. Teams are only read at sign-in. */
export async function stillMember(env: Env, row: MemberRow, notify = true): Promise<MemberRow | null> {
  if (!stillAllowed(env, row.login)) return null;
  const now = Date.now();
  if (row.checked_at !== null && now - row.checked_at < recheckEvery(env)) return row;
  const claim = await env.DB.prepare("UPDATE members SET checked_at = ? WHERE login = ? AND checked_at IS ?")
    .bind(now, row.login, row.checked_at).run();
  if (!claim.meta.changes) return row; // Another request is asking GitHub now.
  let role: "admin" | "member" | null;
  try {
    role = await githubRole(env, row.login);
  } catch {
    await env.DB.prepare("UPDATE members SET checked_at = ? WHERE login = ? AND checked_at = ?").bind(row.checked_at, row.login, now).run();
    return row;
  }
  if (!role) {
    await revokeMember(env, row.login, "github", notify);
    return null;
  }
  if (role === row.role) return { ...row, checked_at: now };
  await env.DB.prepare("UPDATE members SET role = ? WHERE login = ?").bind(role, row.login).run();
  await audit(env, "github", "member.role_changed", row.login, { from: row.role, to: role });
  if (notify) await orgHub(env).fetch("https://org/member-changed", { method: "POST", body: row.login });
  return { ...row, role, checked_at: now };
}

/** The signed-in member, from a session cookie, an app token, or local dev's DEV_LOGIN. */
export async function currentMember(request: Request, env: Env): Promise<Member | null> {
  const bearer = /^Bearer (mft_[\w-]+)$/.exec(request.headers.get("authorization") ?? "")?.[1];
  if (bearer) {
    const row = await env.DB.prepare(
      `SELECT m.* FROM app_tokens t JOIN members m ON m.login = t.login WHERE t.token_hash = ? AND t.expires_at > ?`,
    ).bind(await sha256(bearer), Date.now()).first<MemberRow>();
    const still = row && (await stillMember(env, row));
    if (!still) return null;
    await env.DB.prepare("UPDATE app_tokens SET last_used = ? WHERE token_hash = ?").bind(Date.now(), await sha256(bearer)).run();
    return toMember(still);
  }
  if (env.SESSION_SECRET) {
    // iat is in ms; a session from before it was kept counts as issued a full SESSION_TTL before it expires.
    const session = await verify<{ login: string; exp: number; iat?: number }>(readCookie(request, "session"), env.SESSION_SECRET);
    if (session) {
      const row = await memberRow(env, session.login);
      const issued = session.iat ?? (session.exp - SESSION_TTL) * 1000;
      const still = row && (row.revoked_at === null || issued > row.revoked_at) && (await stillMember(env, row));
      if (still) return toMember(still);
    }
  }
  if (env.DEV_LOGIN && isLocal(request)) {
    await upsertMember(env, { id: 0, login: env.DEV_LOGIN, name: env.DEV_LOGIN, avatar_url: null }, "admin", []);
    return toMember((await memberRow(env, env.DEV_LOGIN))!);
  }
  return null;
}

// ---- members' GitHub tokens -------------------------------------------------
// Each member's user token from their last sign-in, so the factory can approve a pull request as them. Sealed like
// repo secrets (secrets.ts): AES-GCM under a key SECRETS_KEY derives for this use, a fresh IV each, and the login as
// additional data, so a row copied onto someone else won't open.

const TOKEN_INFO = "member-github-token v1";
const enc = new TextEncoder();
const dec = new TextDecoder();
/** Refresh this long before GitHub says a token expires (ms). */
const EXPIRY_SLACK_MS = 60_000;

/** A user token as GitHub hands it over at sign-in or refresh. */
export interface UserToken {
  access_token?: string;
  refresh_token?: string;
  /** Seconds the access token lasts; absent: it doesn't expire. */
  expires_in?: number;
  error?: string;
  error_description?: string;
}

const tokenAad = (login: string) => enc.encode(`member\n${login.toLowerCase()}`);

async function seal(env: Env, login: string, value: string): Promise<string> {
  const key = await aesKey(await secretsKey(env), TOKEN_INFO);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const sealed = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv, additionalData: tokenAad(login) }, key, enc.encode(value)));
  const out = new Uint8Array(iv.length + sealed.length);
  out.set(iv);
  out.set(sealed, iv.length);
  return b64url(out);
}

async function unseal(env: Env, login: string, sealed: string): Promise<string | null> {
  try {
    const bytes = Uint8Array.from(atob(sealed.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0));
    const key = await aesKey(await secretsKey(env), TOKEN_INFO);
    const opened = await crypto.subtle.decrypt({ name: "AES-GCM", iv: bytes.slice(0, 12), additionalData: tokenAad(login) }, key, bytes.slice(12));
    return dec.decode(opened);
  } catch {
    return null;
  }
}

/** Keeps `login`'s user token from a sign-in or refresh, sealed. */
export async function saveUserToken(env: Env, login: string, token: UserToken) {
  if (!token.access_token) return;
  const expiresAt = token.expires_in ? Date.now() + token.expires_in * 1000 : null;
  await env.DB.prepare(
    `INSERT INTO member_github_tokens (login, access_token, refresh_token, expires_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5)
     ON CONFLICT (login) DO UPDATE SET access_token = ?2, refresh_token = ?3, expires_at = ?4, updated_at = ?5`,
  ).bind(
    login, await seal(env, login, token.access_token), token.refresh_token ? await seal(env, login, token.refresh_token) : null, expiresAt, Date.now(),
  ).run();
}

/** `login`'s GitHub user token, refreshed (and the new pair kept) once it has expired; null when there's none that
 *  works: they haven't signed in since tokens were kept, it won't open, or GitHub won't refresh it. */
export async function userToken(env: Env, login: string): Promise<string | null> {
  const row = await env.DB.prepare("SELECT * FROM member_github_tokens WHERE login = ?").bind(login)
    .first<{ access_token: string; refresh_token: string | null; expires_at: number | null }>();
  if (!row) return null;
  if (row.expires_at === null || row.expires_at - EXPIRY_SLACK_MS > Date.now()) return unseal(env, login, row.access_token);
  const refresh = row.refresh_token && (await unseal(env, login, row.refresh_token));
  if (!refresh) return null;
  const fresh = await exchange(env, { grant_type: "refresh_token", refresh_token: refresh }).catch(() => ({} as UserToken));
  if (!fresh.access_token) return null;
  await saveUserToken(env, login, fresh);
  return fresh.access_token;
}

// ---- GitHub ----------------------------------------------------------------

interface Identity {
  id: number;
  login: string;
  name: string | null;
  avatar_url: string | null;
}

async function github<T>(env: Env, token: string, path: string): Promise<{ status: number; body: T | null }> {
  const res = await fetch(`${apiBase(env.GITHUB_API_URL)}${path}`, {
    headers: { authorization: `Bearer ${token}`, accept: "application/vnd.github+json", "user-agent": UA },
  });
  return { status: res.status, body: (await res.json().catch(() => null)) as T | null };
}

type Verdict = { ok: true; member: Member } | { ok: false; status: number; message: string };

/** Checks a GitHub user token against the org, and records the member if they're in. */
async function admit(env: Env, token: string): Promise<Verdict> {
  const me = await github<Identity>(env, token, "/user");
  if (!me.body?.login) return { ok: false, status: 502, message: "GitHub didn't say who you are." };
  const org = env.GITHUB_ORG;
  // A personal account's factory: its owner is its admin. (No org shares a login with a user.)
  if (me.body.login.toLowerCase() === org.toLowerCase()) {
    await upsertMember(env, me.body, "admin", []);
    return { ok: true, member: toMember((await memberRow(env, me.body.login))!) };
  }
  const listed = allowedLogins(env).has(me.body.login.toLowerCase());
  if (env.GITHUB_OWNER_TYPE !== "User") {
    const membership = await github<{ state?: string; role?: string }>(env, token, `/user/memberships/orgs/${encodeURIComponent(org)}`);
    if (membership.status === 200 && membership.body?.state === "active") {
      const teams = await github<Array<{ slug: string; organization?: { login?: string } }>>(env, token, "/user/teams?per_page=100");
      const slugs = (teams.body ?? []).filter((t) => t.organization?.login?.toLowerCase() === org.toLowerCase()).map((t) => t.slug);
      await upsertMember(env, me.body, membership.body.role === "admin" ? "admin" : "member", slugs);
      return { ok: true, member: toMember((await memberRow(env, me.body.login))!) };
    }
    if (!listed) {
      await audit(env, `github:${me.body.login}`, "auth.denied", null, { org, status: membership.status });
      const hint = membership.status === 403
        ? ` If you are a member, the GitHub App needs read access to organization members, and ${org} must approve it.`
        : "";
      return { ok: false, status: 403, message: `${me.body.login} isn't an active member of ${org}.${hint}` };
    }
  }
  if (!listed) {
    await audit(env, `github:${me.body.login}`, "auth.denied", null, { org, personal: true });
    return { ok: false, status: 403, message: `This factory is ${org}'s own: ${me.body.login} isn't on its list of who may sign in (GITHUB_ALLOWED_LOGINS).` };
  }
  await audit(env, `github:${me.body.login}`, "auth.allowed_login", null, { org });
  await upsertMember(env, me.body, "member", []);
  return { ok: true, member: toMember((await memberRow(env, me.body.login))!) };
}

/** Records a sign-in, which is a membership check too. It sets GitHub's role and never touches an admin grant, so a
 *  grant survives every sign-in, nor revoked_at, so only sessions issued after a revocation work. */
async function upsertMember(env: Env, who: Identity, role: string, teams: string[]) {
  await env.DB.prepare(
    `INSERT INTO members (login, github_id, name, avatar_url, role, teams, created_at, last_seen, checked_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7, ?7)
     ON CONFLICT (login) DO UPDATE SET github_id = ?2, name = ?3, avatar_url = ?4, role = ?5, teams = ?6, last_seen = ?7, checked_at = ?7`,
  ).bind(who.login, who.id, who.name, who.avatar_url, role, JSON.stringify(teams), Date.now()).run();
}

/** A sign-in's code (or device code) for a user token. A local test server stands in for github.com too. */
async function exchange(env: Env, params: Record<string, string>) {
  const base = apiBase(env.GITHUB_API_URL);
  const res = await fetch(base === API ? "https://github.com/login/oauth/access_token" : `${base}/login/oauth/access_token`, {
    method: "POST",
    headers: { accept: "application/json", "content-type": "application/json", "user-agent": UA },
    body: JSON.stringify({ client_id: env.GITHUB_CLIENT_ID, client_secret: env.GITHUB_CLIENT_SECRET, ...params }),
  });
  return (await res.json().catch(() => ({}))) as UserToken & { interval?: number };
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
    await saveUserToken(env, verdict.member.login, token);
    await audit(env, verdict.member.login, "auth.login", null, { via: "web" });
    const session = await sign({ login: verdict.member.login, iat: Date.now(), exp: Math.floor(Date.now() / 1000) + SESSION_TTL }, env.SESSION_SECRET!);
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
    await saveUserToken(env, verdict.member.login, token);
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

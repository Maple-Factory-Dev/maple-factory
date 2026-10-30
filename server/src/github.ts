// The org's GitHub App, acting as itself: installation tokens for the runners to fetch and push a
// task's branch, then the task's pull request, its CI, its merge, and closing it if the task is
// cancelled. Without the app (GITHUB_APP_ID + GITHUB_APP_PRIVATE_KEY), tasks push with the machine's
// own credentials and merge locally (runner `task.merge`).
//
// The Worker signs a short JWT with the app's private key (RS256, WebCrypto), finds the app's
// installation on the repo, and mints a token for that one repo with only the permissions the job
// needs. GITHUB_API_URL can point all of it at a fake GitHub for tests; it's only honored on localhost.

import type { Env } from "./env.ts";
import type { GitHubAppInfo, OrgRepo, ReviewThread } from "./wire.ts";

export const API = "https://api.github.com";
const USER_AGENT = "maple-factory";

export interface GitHubApp {
  /** The JWT issuer: the App ID, or the app's Client ID (GitHub accepts either). */
  issuer: string;
  privateKey: string;
  api: string;
}

/** What went wrong, for the runner and the UI. */
export type GitHubErrorCode = "no_app" | "not_installed" | "api";

export class GitHubError extends Error {
  constructor(public code: GitHubErrorCode, message: string, public status = 0) {
    super(message);
  }
}

/** The app, when GITHUB_APP_PRIVATE_KEY and an issuer (GITHUB_APP_ID or GITHUB_CLIENT_ID) are set. */
export function githubApp(env: Env): GitHubApp | null {
  const issuer = (env.GITHUB_APP_ID || env.GITHUB_CLIENT_ID || "").trim();
  const privateKey = env.GITHUB_APP_PRIVATE_KEY?.trim();
  if (!issuer || !privateKey) return null;
  return { issuer, privateKey, api: apiBase(env.GITHUB_API_URL) };
}

/** The app's settings page on GitHub (under the org, or the personal account that owns it). */
export function appSettingsUrl(env: Env, slug: string): string {
  return env.GITHUB_OWNER_TYPE === "User"
    ? `https://github.com/settings/apps/${encodeURIComponent(slug)}`
    : `https://github.com/organizations/${encodeURIComponent(env.GITHUB_ORG)}/settings/apps/${encodeURIComponent(slug)}`;
}

/** The app's links for the apps, when /setup recorded its slug: where it's made public, and installed. */
export function githubAppInfo(env: Env): GitHubAppInfo | null {
  const slug = env.GITHUB_APP_SLUG?.trim();
  if (!slug || !env.GITHUB_ORG) return null;
  return {
    slug,
    ownerType: env.GITHUB_OWNER_TYPE ?? null,
    settingsUrl: `${appSettingsUrl(env, slug)}/advanced`,
    installUrl: `https://github.com/apps/${encodeURIComponent(slug)}/installations/new`,
  };
}

/** The API base: GITHUB_API_URL only when it's a local test server, else api.github.com. */
export function apiBase(override: string | undefined): string {
  if (!override) return API;
  try {
    const u = new URL(override);
    if ((u.hostname === "localhost" || u.hostname === "127.0.0.1") && (u.protocol === "http:" || u.protocol === "https:")) {
      return u.toString().replace(/\/+$/, "");
    }
  } catch {}
  return API;
}

// ---- the app's JWT ----

const enc = new TextEncoder();

function b64url(bytes: Uint8Array | ArrayBuffer): string {
  return btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function derLength(n: number): number[] {
  if (n < 0x80) return [n];
  const out: number[] = [];
  for (let v = n; v > 0; v >>= 8) out.unshift(v & 0xff);
  return [0x80 | out.length, ...out];
}

function der(tag: number, body: Uint8Array): Uint8Array {
  const len = derLength(body.length);
  const out = new Uint8Array(1 + len.length + body.length);
  out[0] = tag;
  out.set(len, 1);
  out.set(body, 1 + len.length);
  return out;
}

function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let i = 0;
  for (const p of parts) {
    out.set(p, i);
    i += p.length;
  }
  return out;
}

/** rsaEncryption AlgorithmIdentifier: SEQUENCE { OID 1.2.840.113549.1.1.1, NULL }. */
const RSA_ALGORITHM = new Uint8Array([0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00]);

/** Wraps a PKCS#1 RSAPrivateKey (what GitHub gives you) in the PKCS#8 WebCrypto imports. */
export function pkcs1ToPkcs8(pkcs1: Uint8Array): Uint8Array {
  return der(0x30, concat(new Uint8Array([0x02, 0x01, 0x00]), RSA_ALGORITHM, der(0x04, pkcs1)));
}

/** The private key as PKCS#8 DER, from a PEM with real newlines or literal `\n`s, PKCS#1 or PKCS#8. */
export function privateKeyDer(pem: string): Uint8Array {
  const text = pem.replace(/\\r/g, "").replace(/\\n/g, "\n").replace(/^["']|["']$/g, "").trim();
  const m = text.match(/-----BEGIN (RSA )?PRIVATE KEY-----([\s\S]*?)-----END (RSA )?PRIVATE KEY-----/);
  if (!m) throw new GitHubError("no_app", "GITHUB_APP_PRIVATE_KEY isn't a PEM private key (-----BEGIN RSA PRIVATE KEY-----).");
  let bytes: Uint8Array;
  try {
    bytes = Uint8Array.from(atob(m[2].replace(/\s+/g, "")), (c) => c.charCodeAt(0));
  } catch {
    throw new GitHubError("no_app", "GITHUB_APP_PRIVATE_KEY isn't valid base64 inside the PEM.");
  }
  return m[1] ? pkcs1ToPkcs8(bytes) : bytes;
}

/** A JWT for the app itself: RS256, issued a minute ago (clock drift), valid for 9 minutes. */
export async function appJwt(app: Pick<GitHubApp, "issuer" | "privateKey">, now = Date.now()): Promise<string> {
  const key = await crypto.subtle.importKey("pkcs8", privateKeyDer(app.privateKey), { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const iat = Math.floor(now / 1000) - 60;
  const header = b64url(enc.encode(JSON.stringify({ alg: "RS256", typ: "JWT" })));
  const payload = b64url(enc.encode(JSON.stringify({ iat, exp: iat + 600, iss: app.issuer })));
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, enc.encode(`${header}.${payload}`));
  return `${header}.${payload}.${b64url(signature)}`;
}

// ---- calls ----

async function call(app: GitHubApp, method: string, path: string, auth: string, body?: unknown): Promise<Response> {
  return fetch(`${app.api}${path}`, {
    method,
    headers: {
      authorization: auth,
      accept: "application/vnd.github+json",
      "x-github-api-version": "2022-11-28",
      "user-agent": USER_AGENT,
      ...(body === undefined ? {} : { "content-type": "application/json" }),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

async function failure(res: Response, what: string): Promise<GitHubError> {
  const text = await res.text().catch(() => "");
  let message = text.slice(0, 300);
  try {
    const j = JSON.parse(text) as { message?: string; errors?: { message?: string }[] };
    message = [j.message, ...(j.errors ?? []).map((e) => e.message)].filter(Boolean).join(": ");
  } catch {}
  return new GitHubError("api", `GitHub refused to ${what} (${res.status}${message ? `: ${message}` : ""}).`, res.status);
}

const seg = (s: string) => encodeURIComponent(s);

/** The app's installation on owner/repo. A 404 means the app isn't installed there. */
/** The repos of the app's installations on the accounts `allowed` says yes to. A public app can be
 *  installed by anyone, so the others are skipped without a token being made for them. */
export async function installedRepos(app: GitHubApp, allowed: (login: string) => boolean): Promise<OrgRepo[]> {
  const jwt = `Bearer ${await appJwt(app)}`;
  const res = await call(app, "GET", "/app/installations?per_page=100", jwt);
  if (!res.ok) throw await failure(res, "listing the app's installations");
  const repos: OrgRepo[] = [];
  for (const installation of (await res.json()) as { id: number; account?: { login?: string } | null }[]) {
    if (!allowed(installation.account?.login ?? "")) continue;
    const tokenRes = await call(app, "POST", `/app/installations/${installation.id}/access_tokens`, jwt, { permissions: { metadata: "read" } });
    if (!tokenRes.ok) throw await failure(tokenRes, "reading an installation's repos");
    const { token } = (await tokenRes.json()) as { token: string };
    for (let page = 1; ; page++) {
      const list = await call(app, "GET", `/installation/repositories?per_page=100&page=${page}`, `token ${token}`);
      if (!list.ok) throw await failure(list, "listing an installation's repos");
      const { repositories } = (await list.json()) as { repositories: { full_name: string; default_branch?: string; private?: boolean }[] };
      for (const r of repositories) repos.push({ name: r.full_name, defaultBranch: r.default_branch ?? null, isPrivate: r.private ?? false, source: "github" });
      if (repositories.length < 100) break;
    }
  }
  return repos;
}

export async function installationId(app: GitHubApp, owner: string, repo: string): Promise<number> {
  const res = await call(app, "GET", `/repos/${seg(owner)}/${seg(repo)}/installation`, `Bearer ${await appJwt(app)}`);
  if (res.status === 404) throw new GitHubError("not_installed", `The GitHub App isn't installed on ${owner}/${repo}.`, 404);
  if (res.status === 401) throw new GitHubError("no_app", "GitHub didn't accept the app's credentials. Check GITHUB_APP_PRIVATE_KEY and GITHUB_APP_ID.", 401);
  if (!res.ok) throw await failure(res, `find the app's installation on ${owner}/${repo}`);
  const { id } = (await res.json()) as { id?: number };
  if (!id) throw new GitHubError("api", "GitHub didn't say which installation covers this repository.");
  return id;
}

/** Whether `login` is in `org` now, asked as the app on the org's installation (it reads members there). */
export async function orgMember(app: GitHubApp, org: string, login: string): Promise<boolean> {
  const jwt = `Bearer ${await appJwt(app)}`;
  const inst = await call(app, "GET", `/orgs/${seg(org)}/installation`, jwt);
  if (inst.status === 404) throw new GitHubError("not_installed", `The GitHub App isn't installed on ${org}.`, 404);
  if (!inst.ok) throw await failure(inst, `find the app's installation on ${org}`);
  const { id } = (await inst.json()) as { id: number };
  const tokenRes = await call(app, "POST", `/app/installations/${id}/access_tokens`, jwt, { permissions: { members: "read" } });
  if (!tokenRes.ok) throw await failure(tokenRes, `give a token to read ${org}'s members`);
  const { token } = (await tokenRes.json()) as { token: string };
  const res = await call(app, "GET", `/orgs/${seg(org)}/members/${seg(login)}`, `token ${token}`);
  if (res.status === 204) return true;
  if (res.status === 404 || res.status === 302) return false;
  throw await failure(res, `say whether ${login} is in ${org}`);
}

/** What each job may do with its token. */
export const PERMISSIONS = {
  /** A runner fetching (or cloning) a task's repo. */
  fetch: { contents: "read" },
  /** A runner pushing a task's branch (finishing, or handing it off). */
  push: { contents: "write" },
  /** The factory opening, merging and closing the pull request. */
  pulls: { contents: "write", pull_requests: "write" },
  /** Reading CI, and asking for failed checks again. */
  checks: { checks: "write", statuses: "read", actions: "write" },
} as const satisfies Record<string, Record<string, "read" | "write">>;

/** A token for owner/repo alone, with `permissions`. It lasts an hour. */
export async function repoToken(app: GitHubApp, owner: string, repo: string, permissions: Record<string, "read" | "write">): Promise<{ token: string; expiresAt: string }> {
  const id = await installationId(app, owner, repo);
  const res = await call(app, "POST", `/app/installations/${id}/access_tokens`, `Bearer ${await appJwt(app)}`, { repositories: [repo], permissions });
  if (res.status === 422 || res.status === 403) {
    throw await failure(res, `give a token for ${owner}/${repo} (${Object.keys(permissions).join(", ")}): check the app's repository permissions are approved on the installation`);
  }
  if (!res.ok) throw await failure(res, `give a token for ${owner}/${repo}`);
  const j = (await res.json()) as { token?: string; expires_at?: string };
  if (!j.token) throw new GitHubError("api", "GitHub didn't return an installation token.");
  return { token: j.token, expiresAt: j.expires_at ?? "" };
}

// ---- pull requests ----

/** Opens a pull request, or finds the open one for this branch. */
export async function createPullRequest(app: GitHubApp, owner: string, repo: string, pr: { title: string; head: string; base: string; body: string }): Promise<{ url: string; number: number }> {
  const auth = `token ${(await repoToken(app, owner, repo, PERMISSIONS.pulls)).token}`;
  const res = await call(app, "POST", `/repos/${seg(owner)}/${seg(repo)}/pulls`, auth, { ...pr, maintainer_can_modify: true });
  if (res.ok) {
    const j = (await res.json()) as { html_url: string; number: number };
    return { url: j.html_url, number: j.number };
  }
  if (res.status === 422) {
    const list = await call(app, "GET", `/repos/${seg(owner)}/${seg(repo)}/pulls?state=open&head=${seg(`${owner}:${pr.head}`)}`, auth);
    const open = list.ok ? ((await list.json()) as { html_url: string; number: number }[]) : [];
    if (open[0]) return { url: open[0].html_url, number: open[0].number };
  }
  throw await failure(res, `open a pull request from ${pr.head} into ${pr.base}`);
}

/** Squash-merges a pull request pinned to `sha`, so GitHub refuses (409) if the head moved. */
const MERGE_RETRIES = 4;
const MERGE_RETRY_MS = 1500;

export async function mergePullRequest(app: GitHubApp, owner: string, repo: string, number: number, pr: { sha: string | null; title: string }): Promise<{ sha: string | null }> {
  const auth = `token ${(await repoToken(app, owner, repo, PERMISSIONS.pulls)).token}`;
  const body = { ...(pr.sha ? { sha: pr.sha } : {}), merge_method: "squash", commit_title: `${pr.title} (#${number})`.slice(0, 250) };
  // GitHub works out whether a pull request can merge in the background after each push, and says
  // 405 "not mergeable" until it has: so a 405 soon after a push gets a few more tries.
  let res = await call(app, "PUT", `/repos/${seg(owner)}/${seg(repo)}/pulls/${number}/merge`, auth, body);
  for (let attempt = 1; res.status === 405 && attempt <= MERGE_RETRIES; attempt++) {
    await new Promise((r) => setTimeout(r, attempt * MERGE_RETRY_MS));
    res = await call(app, "PUT", `/repos/${seg(owner)}/${seg(repo)}/pulls/${number}/merge`, auth, body);
  }
  if (!res.ok) throw await failure(res, `merge pull request #${number}`);
  const j = (await res.json().catch(() => ({}))) as { merged?: boolean; sha?: string; message?: string };
  if (j.merged === false) throw new GitHubError("api", `GitHub didn't merge pull request #${number}${j.message ? `: ${j.message}` : ""}.`, 405);
  return { sha: typeof j.sha === "string" ? j.sha : null };
}

/** Closes a pull request without merging, after saying why in a comment on it. */
export async function closePullRequest(app: GitHubApp, owner: string, repo: string, number: number, comment: string): Promise<void> {
  const auth = `token ${(await repoToken(app, owner, repo, PERMISSIONS.pulls)).token}`;
  await call(app, "POST", `/repos/${seg(owner)}/${seg(repo)}/issues/${number}/comments`, auth, { body: comment });
  const res = await call(app, "PATCH", `/repos/${seg(owner)}/${seg(repo)}/pulls/${number}`, auth, { state: "closed" });
  if (!res.ok) throw await failure(res, `close pull request #${number}`);
}

/** Reopens a closed pull request, after saying why in a comment on it. */
export async function reopenPullRequest(app: GitHubApp, owner: string, repo: string, number: number, comment: string): Promise<void> {
  const auth = `token ${(await repoToken(app, owner, repo, PERMISSIONS.pulls)).token}`;
  const res = await call(app, "PATCH", `/repos/${seg(owner)}/${seg(repo)}/pulls/${number}`, auth, { state: "open" });
  if (!res.ok) throw await failure(res, `reopen pull request #${number}`);
  await call(app, "POST", `/repos/${seg(owner)}/${seg(repo)}/issues/${number}/comments`, auth, { body: comment });
}

/** Permission to read a pull request's review threads. */
const READ_PULLS = { pull_requests: "read" } as const;

const THREADS_QUERY = `query($owner: String!, $repo: String!, $number: Int!, $after: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id path line startLine diffSide isResolved isOutdated
          comments(first: 100) { nodes { author { login } body createdAt } }
        }
      }
    }
  }
}`;

interface ThreadNode {
  id: string;
  path: string;
  line: number | null;
  startLine: number | null;
  diffSide: "LEFT" | "RIGHT";
  isResolved: boolean;
  isOutdated: boolean;
  comments: { nodes: { author: { login: string } | null; body: string; createdAt: string }[] };
}

/** A pull request's review threads (GraphQL: REST has no notion of a thread). */
export async function reviewThreads(app: GitHubApp, owner: string, repo: string, number: number): Promise<ReviewThread[]> {
  const auth = `token ${(await repoToken(app, owner, repo, READ_PULLS)).token}`;
  const threads: ReviewThread[] = [];
  for (let after: string | null = null; ; ) {
    const res = await call(app, "POST", "/graphql", auth, { query: THREADS_QUERY, variables: { owner, repo, number, after } });
    if (!res.ok) throw await failure(res, `read pull request #${number}'s review threads`);
    const j = (await res.json()) as { data?: { repository?: { pullRequest?: { reviewThreads: { pageInfo: { hasNextPage: boolean; endCursor: string | null }; nodes: ThreadNode[] } } | null } | null }; errors?: { message: string }[] };
    const page = j.data?.repository?.pullRequest?.reviewThreads;
    if (!page) throw new GitHubError("api", `GitHub didn't return pull request #${number}'s review threads${j.errors?.length ? `: ${j.errors.map((e) => e.message).join("; ")}` : ""}.`);
    for (const t of page.nodes) {
      threads.push({
        id: t.id,
        path: t.path,
        line: t.line ?? null,
        startLine: t.startLine ?? null,
        side: t.diffSide === "LEFT" ? "old" : "new",
        resolved: t.isResolved,
        outdated: t.isOutdated,
        comments: t.comments.nodes.map((c) => ({ author: c.author?.login ?? "ghost", body: c.body, at: Date.parse(c.createdAt) || 0 })),
      });
    }
    if (!page.pageInfo.hasNextPage || !page.pageInfo.endCursor) break;
    after = page.pageInfo.endCursor;
  }
  return threads;
}

// ---- branches ----

export type BranchDeletion = "deleted" | "gone" | "moved";

/** Deletes a branch, but only while it still points at `expectSha`: a branch that moved is kept ("moved").
 *  One that's already gone (the repo deletes head branches itself, say) counts as done ("gone"). */
export async function deleteBranch(app: GitHubApp, owner: string, repo: string, branch: string, expectSha: string): Promise<BranchDeletion> {
  const auth = `token ${(await repoToken(app, owner, repo, PERMISSIONS.pulls)).token}`;
  const ref = branch.split("/").map(seg).join("/");
  const got = await call(app, "GET", `/repos/${seg(owner)}/${seg(repo)}/git/ref/heads/${ref}`, auth);
  if (got.status === 404) return "gone";
  if (!got.ok) throw await failure(got, `read branch ${branch}`);
  const j = (await got.json()) as { object?: { sha?: string } } | { object?: { sha?: string } }[];
  // A prefix match returns a list of refs rather than the ref itself: then this branch isn't there.
  if (Array.isArray(j)) return "gone";
  if (j.object?.sha !== expectSha) return "moved";
  const res = await call(app, "DELETE", `/repos/${seg(owner)}/${seg(repo)}/git/refs/heads/${ref}`, auth);
  if (res.status === 404 || res.status === 422) return "gone";
  if (!res.ok) throw await failure(res, `delete branch ${branch}`);
  return "deleted";
}

// ---- CI ----

/** A check on a commit, as the apps show it. */
export interface Check {
  name: string;
  status: "queued" | "running" | "passed" | "failed";
  duration: string | null;
  /** How to ask for it again: a check suite, or (GitHub Actions) a workflow run. */
  suite: number | null;
  run: number | null;
  /** The check run (none for a commit status). */
  id?: number | null;
  /** The GitHub Actions job: for Actions the check run's id is the job's. */
  job?: number | null;
  /** Its page on GitHub: the job's, or where a commit status points. */
  url?: string | null;
}

const RUN_FAILED = new Set(["failure", "timed_out", "cancelled", "action_required", "startup_failure"]);

function duration(started: unknown, completed: unknown): string | null {
  const a = typeof started === "string" ? Date.parse(started) : NaN;
  const b = typeof completed === "string" ? Date.parse(completed) : NaN;
  if (Number.isNaN(a) || Number.isNaN(b) || b < a) return null;
  const s = Math.round((b - a) / 1000);
  return s < 60 ? `${s}s` : `${Math.floor(s / 60)}m ${s % 60}s`;
}

/** A commit's check runs and commit statuses, newest of each name. */
export async function checks(app: GitHubApp, owner: string, repo: string, sha: string): Promise<Check[]> {
  const auth = `token ${(await repoToken(app, owner, repo, PERMISSIONS.checks)).token}`;
  const out = new Map<string, Check>();
  const runs = await call(app, "GET", `/repos/${seg(owner)}/${seg(repo)}/commits/${seg(sha)}/check-runs?per_page=100`, auth);
  if (!runs.ok) throw await failure(runs, `list the checks of ${sha.slice(0, 7)}`);
  for (const r of ((await runs.json()) as { check_runs?: any[] }).check_runs ?? []) {
    if (typeof r?.name !== "string" || out.has(r.name)) continue;
    const done = r.status === "completed";
    const run = /\/actions\/runs\/(\d+)/.exec(String(r.details_url ?? ""))?.[1];
    const id = typeof r.id === "number" ? r.id : null;
    const actions = r.app?.slug === "github-actions" || run !== undefined;
    out.set(r.name, {
      name: r.name,
      status: !done ? (r.status === "in_progress" ? "running" : "queued") : RUN_FAILED.has(r.conclusion) ? "failed" : "passed",
      duration: done ? duration(r.started_at, r.completed_at) : null,
      suite: typeof r.check_suite?.id === "number" ? r.check_suite.id : null,
      run: run ? Number(run) : null,
      id,
      job: actions ? id : null,
      url: str(r.html_url) ?? str(r.details_url),
    });
  }
  const statuses = await call(app, "GET", `/repos/${seg(owner)}/${seg(repo)}/commits/${seg(sha)}/status?per_page=100`, auth);
  if (statuses.ok) {
    for (const s of ((await statuses.json()) as { statuses?: any[] }).statuses ?? []) {
      if (typeof s?.context !== "string" || out.has(s.context)) continue;
      out.set(s.context, {
        name: s.context,
        status: s.state === "success" ? "passed" : s.state === "pending" ? "running" : "failed",
        duration: null,
        suite: null,
        run: null,
        id: null,
        job: null,
        url: str(s.target_url),
      });
    }
  }
  return [...out.values()];
}

/** Asks for failed checks again: a workflow run's failed jobs, or the check suite. Returns how many it asked for. */
export async function rerunFailed(app: GitHubApp, owner: string, repo: string, failed: Check[]): Promise<number> {
  const auth = `token ${(await repoToken(app, owner, repo, PERMISSIONS.checks)).token}`;
  const asked = new Set<string>();
  for (const c of failed) {
    const path = c.run
      ? `/repos/${seg(owner)}/${seg(repo)}/actions/runs/${c.run}/rerun-failed-jobs`
      : c.suite
        ? `/repos/${seg(owner)}/${seg(repo)}/check-suites/${c.suite}/rerequest`
        : null;
    if (!path || asked.has(path)) continue;
    const res = await call(app, "POST", path, auth);
    if (!res.ok) throw await failure(res, `run ${c.name} again`);
    asked.add(path);
  }
  return asked.size;
}

const str = (v: unknown): string | null => (typeof v === "string" && v ? v : null);

/** How much of a job's log is kept: its end, where a failure usually is. */
export const LOG_LIMIT = 200_000;

/** A check's log: the job's (GitHub Actions), or the check run's output for another app. */
export interface CheckLog {
  text: string;
  truncated: boolean;
  /** The first line GitHub marked `##[error]`, without the marker. */
  failedStep: string | null;
}

/** A job log's lines without the timestamp GitHub puts in front of each, and its byte-order mark. */
export function cleanLog(raw: string): string {
  return raw.replace(/^\uFEFF/, "").replace(/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z ?/gm, "");
}

/** The log's last `limit` characters, cut at a line, and the first error in it. */
export function trimLog(text: string, limit = LOG_LIMIT): CheckLog {
  let out = text;
  let truncated = false;
  if (out.length > limit) {
    out = out.slice(out.length - limit);
    const nl = out.indexOf("\n");
    if (nl >= 0 && nl < 2000) out = out.slice(nl + 1);
    truncated = true;
  }
  const failed = /^.*##\[error\](.*)$/m.exec(out);
  return { text: out, truncated, failedStep: failed ? failed[1].trim() || "Error" : null };
}

/** Reads a check's log. Throws a GitHubError when there's none (a commit status, or an expired log). */
export async function checkLog(app: GitHubApp, owner: string, repo: string, c: Check): Promise<CheckLog> {
  const auth = `token ${(await repoToken(app, owner, repo, PERMISSIONS.checks)).token}`;
  if (c.job) {
    // Answered with a redirect to the plain text log; fetch follows it (and drops the token on the way).
    const res = await call(app, "GET", `/repos/${seg(owner)}/${seg(repo)}/actions/jobs/${c.job}/logs`, auth);
    if (res.status === 404 || res.status === 410) throw new GitHubError("api", `GitHub has no log for ${c.name} (it may have expired)${c.url ? `: see ${c.url}` : ""}.`, res.status);
    if (!res.ok) throw await failure(res, `read ${c.name}'s log`);
    return trimLog(cleanLog(await res.text()));
  }
  if (c.id) {
    const res = await call(app, "GET", `/repos/${seg(owner)}/${seg(repo)}/check-runs/${c.id}`, auth);
    if (!res.ok) throw await failure(res, `read ${c.name}`);
    const out = ((await res.json()) as { output?: { title?: string | null; summary?: string | null; text?: string | null } }).output ?? {};
    const text = [out.title, out.summary, out.text].filter((x): x is string => typeof x === "string" && x.trim() !== "").join("\n\n");
    if (!text) throw new GitHubError("api", `${c.name} didn't report any output${c.url ? `: see ${c.url}` : ""}.`);
    return trimLog(text);
  }
  throw new GitHubError("api", `${c.name} is a commit status, with no log on GitHub${c.url ? `: see ${c.url}` : ""}.`);
}

/** Asks for one check again: its GitHub Actions job, or its check run. */
export async function rerunCheck(app: GitHubApp, owner: string, repo: string, c: Check): Promise<void> {
  const path = c.job
    ? `/repos/${seg(owner)}/${seg(repo)}/actions/jobs/${c.job}/rerun`
    : c.id
      ? `/repos/${seg(owner)}/${seg(repo)}/check-runs/${c.id}/rerequest`
      : null;
  if (!path) throw new GitHubError("api", `${c.name} is a commit status; GitHub can't run it again from here${c.url ? `: see ${c.url}` : ""}.`);
  const auth = `token ${(await repoToken(app, owner, repo, PERMISSIONS.checks)).token}`;
  const res = await call(app, "POST", path, auth);
  if (!res.ok) throw await failure(res, `run ${c.name} again`);
}

// ---- webhooks ----

/** Checks GitHub's X-Hub-Signature-256 ("sha256=<hex HMAC of the raw body>") in constant time. */
export async function verifyWebhook(secret: string, body: ArrayBuffer | Uint8Array, signature: string | null): Promise<boolean> {
  const m = /^sha256=([0-9a-f]{64})$/i.exec(signature?.trim() ?? "");
  if (!m || !secret) return false;
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, body));
  const given = m[1].toLowerCase();
  let diff = 0;
  for (let i = 0; i < mac.length; i++) diff |= mac[i] ^ parseInt(given.slice(i * 2, i * 2 + 2), 16);
  return diff === 0;
}

#!/usr/bin/env node
// A fake GitHub API, so the factory's GitHub App paths run locally without touching github.com.
//
//   node server/test/fake-github.mjs --port 18803 --public-key app.pub.pem --installed acme/greeter \
//     --remotes '/tmp/mfgh/remotes/{owner}/{repo}.git' --webhook-url http://localhost:8788/integrations/github \
//     --webhook-secret dev-gh-secret [--ci test] [--user afomera] [--member acme:alice]
//
// Point the server at it with GITHUB_API_URL=http://localhost:18803 (only honored on localhost) and
// the runner's pushes at the bare repos with MAPLE_TASK_PUSH_URL / MAPLE_TASK_FETCH_URL. It checks
// what GitHub checks: the app's JWT (RS256, against --public-key), and that an installation token
// covers the repo and the permission a call needs. It answers:
//
//   GET  /repos/:o/:r/installation                       app JWT → { id } or 404
//   POST /app/installations/:id/access_tokens            app JWT → { token } for { repositories, permissions }
//   GET  /app/installations, GET /installation/repositories   the app's installations, and an installation's repos
//   POST /repos/:o/:r/pulls, GET …/pulls?head=, GET/PATCH …/pulls/:n (close or reopen), POST …/issues/:n/comments
//   PUT  /repos/:o/:r/pulls/:n/merge                     squash-merges into the bare repo (409 if `sha` isn't the head)
//   GET  /repos/:o/:r/commits/:sha/check-runs, …/status  every commit has the --ci checks, queued until set
//   POST /repos/:o/:r/check-suites/:id/rerequest         failed runs in the suite queue again, then pass
//   POST /app-manifests/:code/conversions                /setup's new app; code `app-<owner>` makes one owned by <owner>
//   GET  /users/:login                                   a personal account for each --user, otherwise an organization
//   POST /login/oauth/access_token                       sign-in: code `as-<login>` is <login>'s user token
//   GET  /user, /user/memberships/orgs/:org, /user/teams  who that token is; active in an org for each --member org:login
//
// and, for the test driver: GET /_log, POST /_checks { sha, owner, repo, runs: [{ name, conclusion }] },
// which finishes checks the way CI would and delivers the signed check_run webhook (not with `quiet`,
// like a server webhooks can't reach), and POST /_deleteBranch { owner, repo, branch }, after which
// GitHub won't reopen that branch's closed pull request.

import { execFileSync } from "node:child_process";
import { createHmac, createPublicKey, createVerify, randomBytes } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseArgs } from "node:util";

const { values } = parseArgs({
  options: {
    port: { type: "string", default: "18803" },
    "public-key": { type: "string" },
    installed: { type: "string", multiple: true, default: [] },
    remotes: { type: "string" },
    "webhook-url": { type: "string" },
    "webhook-secret": { type: "string", default: "" },
    ci: { type: "string", multiple: true, default: [] },
    user: { type: "string", multiple: true, default: [] },
    member: { type: "string", multiple: true, default: [] },
  },
});

const publicKey = createPublicKey(readFileSync(values["public-key"], "utf8"));
const users = new Set(values.user.map((u) => u.toLowerCase()));
const ownerType = (login) => (users.has(login.toLowerCase()) ? "User" : "Organization");
const members = new Set(values.member.map((m) => m.toLowerCase()));
const installed = new Map(values.installed.map((r, i) => [r.toLowerCase(), 1000 + i]));
const log = [];
const tokens = new Map(); // token → { repositories, permissions }
const pulls = [];
const runs = new Map(); // `${owner}/${repo}@${sha}` → [{ id, name, status, conclusion, suite }]
let lastNumber = 0;
let lastRun = 0;

const bare = (owner, repo) => values.remotes.replace("{owner}", owner).replace("{repo}", repo);
const git = (dir, ...args) => execFileSync("git", ["--git-dir", dir, ...args], { encoding: "utf8" }).trim();
const headOf = (p) => {
  try {
    return git(bare(p.owner, p.repo), "rev-parse", "--verify", "--quiet", `refs/heads/${p.head}`);
  } catch {
    return null;
  }
};
const pullJson = (p) => ({
  number: p.number, html_url: p.html_url, state: p.state, merged: Boolean(p.merged), title: p.title,
  head: { ref: p.head, sha: headOf(p) }, base: { ref: p.base },
});

function checkRunsFor(owner, repo, sha) {
  const key = `${owner}/${repo}@${sha}`;
  if (!runs.has(key)) runs.set(key, values.ci.map((name) => ({ id: ++lastRun, name, status: "queued", conclusion: null, suite: 1 })));
  return runs.get(key);
}

async function deliver(kind, payload) {
  if (!values["webhook-url"]) return null;
  const body = JSON.stringify(payload);
  const res = await fetch(values["webhook-url"], {
    method: "POST",
    headers: {
      "content-type": "application/json", "x-github-event": kind, "x-github-delivery": crypto.randomUUID(),
      "x-hub-signature-256": `sha256=${createHmac("sha256", values["webhook-secret"]).update(body).digest("hex")}`,
    },
    body,
  });
  return res.status;
}
const repository = (owner, repo) => ({ name: repo, full_name: `${owner}/${repo}`, owner: { login: owner } });

const b64 = (s) => Buffer.from(s, "base64url");
function verifyJwt(auth) {
  const m = /^Bearer (.+)$/.exec(auth ?? "");
  if (!m) return "no bearer token";
  const [h, p, s] = m[1].split(".");
  if (!s) return "not a JWT";
  if (JSON.parse(b64(h).toString()).alg !== "RS256") return "not RS256";
  if (!createVerify("RSA-SHA256").update(`${h}.${p}`).verify(publicKey, b64(s))) return "bad signature";
  const payload = JSON.parse(b64(p).toString());
  const now = Math.floor(Date.now() / 1000);
  if (!(payload.iat <= now + 60 && payload.exp > now && payload.exp - payload.iat <= 600)) return "bad iat/exp";
  return payload.iss ? null : "no iss";
}

/** The grant behind `token …`, if it covers `repo` with `permission` at `level`. */
function grant(req, repo, permission, level) {
  const t = /^token (.+)$/.exec(req.headers.authorization ?? "")?.[1];
  const g = t && tokens.get(t);
  if (!g) return [401, "Bad credentials"];
  const have = g.permissions?.[permission];
  if (!g.repositories?.includes(repo) || !(have === "write" || (level === "read" && have === "read"))) return [403, `Resource not accessible by integration (needs ${permission}:${level})`];
  return null;
}

const send = (res, status, body) => res.writeHead(status, { "content-type": "application/json" }).end(body === undefined ? "" : JSON.stringify(body));

createServer((req, res) => {
  const chunks = [];
  req.on("data", (c) => chunks.push(c));
  req.on("end", async () => {
    const url = new URL(req.url, "http://x");
    const text = Buffer.concat(chunks).toString();
    const body = text ? JSON.parse(text) : undefined;
    log.push({ method: req.method, path: url.pathname, body });
    const deny = (g) => send(res, g[0], { message: g[1] });
    let m;

    if (req.method === "GET" && url.pathname === "/_log") return send(res, 200, { log, pulls: pulls.map(pullJson) });
    if (req.method === "POST" && url.pathname === "/_deleteBranch") {
      git(bare(body.owner, body.repo), "branch", "-D", body.branch);
      return send(res, 200, {});
    }
    if (req.method === "POST" && url.pathname === "/_checks") {
      const list = checkRunsFor(body.owner, body.repo, body.sha);
      for (const r of body.runs) {
        const run = list.find((x) => x.name === r.name);
        Object.assign(run, { status: "completed", conclusion: r.conclusion });
        if (!body.quiet) await deliver("check_run", { action: "completed", check_run: { head_sha: body.sha, name: run.name, conclusion: r.conclusion }, repository: repository(body.owner, body.repo) });
      }
      return send(res, 200, { runs: list });
    }

    if (req.method === "POST" && (m = url.pathname.match(/^\/app-manifests\/app-([\w-]+)\/conversions$/))) {
      const owner = m[1];
      return send(res, 201, {
        id: 4242, slug: `maple-factory-${owner}`, owner: { login: owner, type: ownerType(owner) },
        client_id: "Iv23fakeclient", client_secret: "fake-client-secret", webhook_secret: "fake-webhook-secret",
        pem: "-----BEGIN RSA PRIVATE KEY-----\nfake\n-----END RSA PRIVATE KEY-----\n",
      });
    }
    if (req.method === "POST" && url.pathname === "/login/oauth/access_token") {
      const login = /^as-([\w-]+)$/.exec(body?.code ?? "")?.[1];
      return send(res, 200, login ? { access_token: `ghu_fake_${login}`, token_type: "bearer" } : { error: "bad_verification_code" });
    }
    const me = /^Bearer ghu_fake_([\w-]+)$/.exec(req.headers.authorization ?? "")?.[1];
    if (req.method === "GET" && url.pathname === "/user") {
      return me ? send(res, 200, { id: me.length, login: me, name: me, avatar_url: null }) : send(res, 401, { message: "Bad credentials" });
    }
    if (req.method === "GET" && me && (m = url.pathname.match(/^\/user\/memberships\/orgs\/([\w-]+)$/))) {
      return members.has(`${m[1]}:${me}`.toLowerCase()) ? send(res, 200, { state: "active", role: "member" }) : send(res, 404, { message: "Not Found" });
    }
    if (req.method === "GET" && me && url.pathname === "/user/teams") return send(res, 200, []);
    if (req.method === "GET" && (m = url.pathname.match(/^\/users\/([\w-]+)$/))) {
      return send(res, 200, { login: m[1], type: ownerType(m[1]) });
    }
    if (req.method === "GET" && (m = url.pathname.match(/^\/repos\/([^/]+)\/([^/]+)\/installation$/))) {
      const why = verifyJwt(req.headers.authorization);
      if (why) return send(res, 401, { message: `A JSON web token could not be decoded (${why})` });
      const id = installed.get(`${m[1]}/${m[2]}`.toLowerCase());
      return id ? send(res, 200, { id }) : send(res, 404, { message: "Not Found" });
    }
    if (req.method === "GET" && url.pathname === "/app/installations") {
      const why = verifyJwt(req.headers.authorization);
      if (why) return send(res, 401, { message: why });
      return send(res, 200, [...new Set(installed.values())].map((id) => ({ id, account: { login: [...installed].find(([, i]) => i === id)[0].split("/")[0] } })));
    }
    if (req.method === "GET" && url.pathname === "/installation/repositories") {
      const t = /^token (.+)$/.exec(req.headers.authorization ?? "")?.[1];
      const g = t && tokens.get(t);
      if (!g) return send(res, 401, { message: "Bad credentials" });
      const page = Number(url.searchParams.get("page") ?? 1);
      const mine = [...installed].filter(([, id]) => id === g.installation).map(([name]) => name);
      const repositories = (page === 1 ? mine : []).map((name) => ({ full_name: name, default_branch: "main", private: true }));
      return send(res, 200, { total_count: mine.length, repositories });
    }
    if (req.method === "POST" && (m = url.pathname.match(/^\/app\/installations\/(\d+)\/access_tokens$/))) {
      const why = verifyJwt(req.headers.authorization);
      if (why) return send(res, 401, { message: why });
      const token = `ghs_${randomBytes(18).toString("hex")}`;
      tokens.set(token, { repositories: body?.repositories, permissions: body?.permissions, installation: Number(m[1]) });
      return send(res, 201, { token, expires_at: new Date(Date.now() + 3600_000).toISOString() });
    }

    if ((m = url.pathname.match(/^\/repos\/([^/]+)\/([^/]+)\/pulls$/))) {
      const g = grant(req, m[2], "pull_requests", req.method === "GET" ? "read" : "write");
      if (g) return deny(g);
      if (req.method === "GET") return send(res, 200, pulls.filter((p) => `${p.owner}:${p.head}` === url.searchParams.get("head") && p.state === "open").map(pullJson));
      if (pulls.some((p) => p.owner === m[1] && p.repo === m[2] && p.head === body.head && p.state === "open")) {
        return send(res, 422, { message: "Validation Failed", errors: [{ message: `A pull request already exists for ${m[1]}:${body.head}.` }] });
      }
      const number = ++lastNumber;
      const p = { owner: m[1], repo: m[2], number, state: "open", html_url: `https://github.com/${m[1]}/${m[2]}/pull/${number}`, comments: [], ...body };
      pulls.push(p);
      return send(res, 201, pullJson(p));
    }
    if ((m = url.pathname.match(/^\/repos\/([^/]+)\/([^/]+)\/pulls\/(\d+)(\/merge)?$/))) {
      const p = pulls.find((x) => x.owner === m[1] && x.repo === m[2] && x.number === Number(m[3]));
      const g = grant(req, m[2], "pull_requests", req.method === "GET" ? "read" : "write");
      if (g) return deny(g);
      if (!p) return send(res, 404, { message: "Not Found" });
      if (req.method === "PATCH") {
        if (body.state === "open" && p.state === "merged") return send(res, 422, { message: "Validation Failed: state cannot be changed. The pull request is merged." });
        if (body.state === "open" && p.state === "closed" && !headOf(p)) return send(res, 422, { message: `Validation Failed: state cannot be changed. The ${p.head} branch has been deleted.` });
        Object.assign(p, body.state === "closed" || body.state === "open" ? { state: body.state } : {});
        return send(res, 200, pullJson(p));
      }
      if (req.method === "PUT" && m[4]) {
        if (p.state !== "open") return send(res, 405, { message: "Pull Request is not mergeable" });
        const head = headOf(p);
        if (body.sha && body.sha !== head) return send(res, 409, { message: "Head branch was modified. Review and try the merge again." });
        // Squash it into the base, as GitHub would.
        const work = mkdtempSync(join(tmpdir(), "fake-gh-"));
        try {
          const dir = bare(p.owner, p.repo);
          execFileSync("git", ["clone", "--quiet", "--branch", p.base, dir, work]);
          execFileSync("git", ["-C", work, "merge", "--squash", `origin/${p.head}`], { stdio: "ignore" });
          execFileSync("git", ["-C", work, "-c", "user.name=GitHub", "-c", "user.email=noreply@github.invalid", "commit", "--quiet", "-m", body.commit_title ?? p.title]);
          execFileSync("git", ["-C", work, "push", "--quiet", "origin", `HEAD:${p.base}`]);
          const sha = execFileSync("git", ["-C", work, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
          Object.assign(p, { state: "closed", merged: true });
          return send(res, 200, { sha, merged: true, message: "Pull Request successfully merged" });
        } catch (e) {
          return send(res, 405, { message: `Merge conflict: ${e.message.split("\n")[0]}` });
        } finally {
          rmSync(work, { recursive: true, force: true });
        }
      }
      return send(res, 200, pullJson(p));
    }
    if (req.method === "POST" && (m = url.pathname.match(/^\/repos\/([^/]+)\/([^/]+)\/issues\/(\d+)\/comments$/))) {
      const g = grant(req, m[2], "pull_requests", "write");
      if (g) return deny(g);
      pulls.find((x) => x.number === Number(m[3]))?.comments.push(body.body);
      return send(res, 201, { id: Date.now() });
    }

    if (req.method === "GET" && (m = url.pathname.match(/^\/repos\/([^/]+)\/([^/]+)\/commits\/([0-9a-f]+)\/check-runs$/))) {
      const g = grant(req, m[2], "checks", "read");
      if (g) return deny(g);
      const list = checkRunsFor(m[1], m[2], m[3]);
      return send(res, 200, {
        total_count: list.length,
        check_runs: list.map((r) => ({ id: r.id, name: r.name, status: r.status, conclusion: r.conclusion, check_suite: { id: r.suite }, started_at: new Date(Date.now() - 42_000).toISOString(), completed_at: r.status === "completed" ? new Date().toISOString() : null })),
      });
    }
    if (req.method === "GET" && (m = url.pathname.match(/^\/repos\/([^/]+)\/([^/]+)\/commits\/([0-9a-f]+)\/status$/))) {
      const g = grant(req, m[2], "statuses", "read");
      return g ? deny(g) : send(res, 200, { state: "success", statuses: [] });
    }
    if (req.method === "POST" && (m = url.pathname.match(/^\/repos\/([^/]+)\/([^/]+)\/check-suites\/(\d+)\/rerequest$/))) {
      const g = grant(req, m[2], "checks", "write");
      if (g) return deny(g);
      // The suite's failed runs start again, and pass a moment later.
      for (const [key, list] of runs) {
        const [repoKey, sha] = key.split("@");
        if (repoKey !== `${m[1]}/${m[2]}`) continue;
        for (const r of list.filter((x) => x.suite === Number(m[3]) && x.conclusion === "failure")) {
          Object.assign(r, { status: "in_progress", conclusion: null });
          setTimeout(() => {
            Object.assign(r, { status: "completed", conclusion: "success" });
            deliver("check_run", { action: "completed", check_run: { head_sha: sha, name: r.name, conclusion: "success" }, repository: repository(m[1], m[2]) });
          }, 1500);
        }
      }
      return send(res, 201, {});
    }
    send(res, 404, { message: "Not Found" });
  });
}).listen(Number(values.port), "127.0.0.1", () => console.log(`fake GitHub on http://localhost:${values.port}; installed: ${[...installed.keys()].join(", ") || "none"}`));

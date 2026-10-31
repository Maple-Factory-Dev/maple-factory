#!/usr/bin/env node
// A fake GitHub API, so the factory's GitHub App paths run locally without touching github.com.
//
//   node server/test/fake-github.mjs --port 18803 --public-key app.pub.pem --installed acme/greeter \
//     --remotes '/tmp/mfgh/remotes/{owner}/{repo}.git' --webhook-url http://localhost:8788/integrations/github \
//     --webhook-secret dev-gh-secret [--ci test] [--user afomera] [--member acme:alice] [--owner acme:alice] [--no-workflows]
//
// Point the server at it with GITHUB_API_URL=http://localhost:18803 (only honored on localhost) and
// the runner's pushes at the bare repos with MAPLE_TASK_PUSH_URL / MAPLE_TASK_FETCH_URL. It checks
// what GitHub checks: the app's JWT (RS256, against --public-key), and that an installation token
// covers the repo and the permission a call needs. It answers:
//
//   GET  /repos/:o/:r/installation                       app JWT → { id } or 404
//   POST /app/installations/:id/access_tokens            app JWT → { token } for { repositories, permissions }; with --no-workflows
//                                                        (an install that hasn't approved Workflows: write) a request with
//                                                        `workflows` is a 422. GET /_log's `tokens` lists every request's permissions
//   GET  /app/installations, GET /installation/repositories   the app's installations (one per account, with its
//                                                        login), and an installation's repos
//   GET  /orgs/:org/installation, /orgs/:org/members/:login   an account's installation; 204 if a member (members:read)
//   GET  /orgs/:org/memberships/:login                   { state: "active", role } if a member, else 404 (members:read)
//   POST /repos/:o/:r/pulls, GET …/pulls?head=, GET/PATCH …/pulls/:n (close or reopen), POST …/issues/:n/comments
//   PUT  /repos/:o/:r/pulls/:n/merge                     squash-merges into the bare repo (409 if `sha` isn't the head; 405 on a
//                                                        branch that requires a merge queue)
//   GET  /repos/:o/:r/rules/branches/:branch             [{ type: "merge_queue" }] when /_queue says the branch requires one, else []
//   GET  /repos/:o/:r/git/ref/heads/*, DELETE …/git/refs/heads/*   a branch of the bare repo (404 / 422 once it's gone)
//   GET  /repos/:o/:r/commits/:sha/check-runs, …/status  every commit has the --ci checks, queued until set
//   POST /repos/:o/:r/check-suites/:id/rerequest         failed runs in the suite queue again, then pass
//   POST /repos/:o/:r/actions/runs/:id/rerun-failed-jobs  the same, for the workflow run (every check is a GitHub Actions job)
//   POST /repos/:o/:r/actions/jobs/:id/rerun              that job alone queues again, then passes
//   POST /repos/:o/:r/check-runs/:id/rerequest            that check run alone queues again, then passes
//   GET  /repos/:o/:r/actions/jobs/:id/logs               302 to the job's plain text log (timestamped lines; `##[error]` when it failed)
//   GET  /repos/:o/:r/check-runs/:id                      a check run with its output
//   POST /app-manifests/:code/conversions                /setup's new app; code `app-<owner>` makes one owned by <owner>
//   GET  /users/:login                                   a personal account for each --user, otherwise an organization
//   POST /login/oauth/access_token                       sign-in: code (or device_code) `as-<login>` is <login>'s user token
//   GET  /user, /user/memberships/orgs/:org, /user/teams  who that token is; active in an org for each --member org:login
//                                                        (its admin, for each --owner org:login)
//   POST /graphql                                        repository.pullRequest.reviewThreads, from /_threads; repository.pullRequest.id;
//                                                        enqueuePullRequest (pinned to expectedHeadOid), after which the queue
//                                                        merges it (pull_request `closed`, merged) or takes it out (`dequeued`)
//
// and, for the test driver: GET /_log, POST /_checks { sha, owner, repo, runs: [{ name, conclusion }] },
// which finishes checks the way CI would and delivers the signed check_run webhook (not with `quiet`,
// like a server webhooks can't reach), and POST /_deleteBranch { owner, repo, branch }, after which
// GitHub won't reopen that branch's closed pull request, and POST /_moveOnMerge { owner, repo, branch }: once
// that branch's pull request merges, someone pushes another commit to it, POST /_leave { org, login }: they
// leave the org, POST /_role { org, login, role: "admin"|"member" }: their role there changes, and POST /_threads { owner, repo, number, threads: [{ path, line, startLine?, side?: "LEFT"|"RIGHT",
// resolved?, outdated?, comments: [{ author, body }] }] }, the review threads people left on that pull request, and
// POST /_queue { owner, repo, branch = "main", then: "merge"|"dequeue"|"hold"|"off", reason?, delayMs? }: that branch requires
// a merge queue (not with "off"), and what the queue does with each pull request added to it a moment later, and
// POST /_private { owner, repo, private: false }: the app's repo list says that repo is public (repos are private until then).

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
    owner: { type: "string", multiple: true, default: [] },
    "no-workflows": { type: "boolean", default: false },
  },
});

const publicKey = createPublicKey(readFileSync(values["public-key"], "utf8"));
const users = new Set(values.user.map((u) => u.toLowerCase()));
const ownerType = (login) => (users.has(login.toLowerCase()) ? "User" : "Organization");
const owners = new Set(values.owner.map((m) => m.toLowerCase()));
const members = new Set([...values.member.map((m) => m.toLowerCase()), ...owners]);
// One installation per account, as on GitHub: --installed acme/api --installed acme/web --installed other/x
// is acme's installation (both repos) and other's.
const accounts = [...new Set(values.installed.map((r) => r.split("/")[0].toLowerCase()))];
const installed = new Map(values.installed.map((r) => [r.toLowerCase(), 1000 + accounts.indexOf(r.split("/")[0].toLowerCase())]));
const log = [];
const tokens = new Map(); // token → { repositories, permissions }
const tokenRequests = []; // { installation, repositories, permissions, status }, in order
const pulls = [];
const runs = new Map(); // `${owner}/${repo}@${sha}` → [{ id, name, status, conclusion, suite, log? }]
const moveOnMerge = new Set(); // `${owner}/${repo}:${branch}`
const threads = new Map(); // `${owner}/${repo}#${number}` → [{ path, line, … }]
const queues = new Map(); // `${owner}/${repo}:${branch}` → { then, reason, delayMs }
const publicRepos = new Set(); // `${owner}/${repo}`, lower case: the rest are private
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

/** A job's log as GitHub serves it: every line timestamped, a failure marked `##[error]`. */
function jobLog(r) {
  const at = (i) => new Date(Date.UTC(2026, 9, 29, 12, 0, i)).toISOString().replace("Z", "0000Z");
  const lines = r.log ?? [
    "##[group]Run actions/checkout@v4",
    "Syncing repository: acme/greeter",
    "##[endgroup]",
    `##[group]Run npm ${r.name}`,
    `> greeter@1.0.0 ${r.name}`,
    ...(r.conclusion === "failure"
      ? ["not ok 1 - says hello", "  expected: 'hello'", "  actual: 'helo'", "##[error]Process completed with exit code 1."]
      : ["ok 1 - says hello"]),
    "##[endgroup]",
  ];
  return "\uFEFF" + lines.map((l, i) => `${at(i)} ${l}`).join("\n") + "\n";
}

/** Squash-merges a pull request into its base, as GitHub would; throws on a conflict. */
function squash(p, title) {
  const head = headOf(p);
  const work = mkdtempSync(join(tmpdir(), "fake-gh-"));
  try {
    const dir = bare(p.owner, p.repo);
    execFileSync("git", ["clone", "--quiet", "--branch", p.base, dir, work]);
    execFileSync("git", ["-C", work, "merge", "--squash", `origin/${p.head}`], { stdio: "ignore" });
    execFileSync("git", ["-C", work, "-c", "user.name=GitHub", "-c", "user.email=noreply@github.invalid", "commit", "--quiet", "-m", title]);
    execFileSync("git", ["-C", work, "push", "--quiet", "origin", `HEAD:${p.base}`]);
    const sha = execFileSync("git", ["-C", work, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
    Object.assign(p, { state: "closed", merged: true });
    if (moveOnMerge.delete(`${p.owner}/${p.repo}:${p.head}`)) {
      const moved = execFileSync("git", ["--git-dir", dir, "-c", "user.name=Someone", "-c", "user.email=someone@example.invalid", "commit-tree", `${head}^{tree}`, "-p", head, "-m", "A push after the merge"], { encoding: "utf8" }).trim();
      git(dir, "update-ref", `refs/heads/${p.head}`, moved);
    }
    return sha;
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}

const queueOf = (p) => queues.get(`${p.owner}/${p.repo}:${p.base}`.toLowerCase());
const pullEvent = (action, p, extra = {}) =>
  deliver("pull_request", { action, number: p.number, pull_request: { number: p.number, head: { ref: p.head, sha: headOf(p) }, base: { ref: p.base }, merged: Boolean(p.merged) }, repository: repository(p.owner, p.repo), ...extra });

/** A pull request joins its base's merge queue; a moment later the queue merges it or takes it out. */
function enqueue(p) {
  const q = queueOf(p);
  p.queued = true;
  pullEvent("enqueued", p);
  if (q.then === "hold") return;
  setTimeout(async () => {
    if (!p.queued || p.state !== "open") return;
    p.queued = false;
    if (q.then === "dequeue") return void (await pullEvent("dequeued", p, { reason: q.reason ?? "CI_FAILURE" }));
    try {
      squash(p, `${p.title} (#${p.number})`);
    } catch {
      return void (await pullEvent("dequeued", p, { reason: "MERGE_CONFLICT" }));
    }
    await pullEvent("closed", p);
  }, q.delayMs ?? 1500);
}

/** Where a run is: every fake check is a GitHub Actions job in workflow run 7. */
const RUN = 7;
const findRun = (owner, repo, id) => {
  for (const [key, list] of runs) {
    if (!key.startsWith(`${owner}/${repo}@`)) continue;
    const r = list.find((x) => x.id === id);
    if (r) return { r, sha: key.split("@")[1] };
  }
  return null;
};

/** A run starts again, and passes a moment later. */
function restart(owner, repo, sha, r) {
  Object.assign(r, { status: "in_progress", conclusion: null });
  setTimeout(() => {
    Object.assign(r, { status: "completed", conclusion: "success" });
    deliver("check_run", { action: "completed", check_run: { head_sha: sha, name: r.name, conclusion: "success" }, repository: repository(owner, repo) });
  }, 1500);
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

    if (req.method === "GET" && url.pathname === "/_log") return send(res, 200, { log, pulls: pulls.map(pullJson), tokens: tokenRequests });
    if (req.method === "POST" && url.pathname === "/_deleteBranch") {
      git(bare(body.owner, body.repo), "branch", "-D", body.branch);
      return send(res, 200, {});
    }
    if (req.method === "POST" && url.pathname === "/_moveOnMerge") {
      moveOnMerge.add(`${body.owner}/${body.repo}:${body.branch}`);
      return send(res, 200, {});
    }
    if (req.method === "POST" && url.pathname === "/_private") {
      if (body.private === false) publicRepos.add(`${body.owner}/${body.repo}`.toLowerCase());
      else publicRepos.delete(`${body.owner}/${body.repo}`.toLowerCase());
      return send(res, 204);
    }
    if (req.method === "POST" && url.pathname === "/_queue") {
      const key = `${body.owner}/${body.repo}:${body.branch ?? "main"}`.toLowerCase();
      if (body.then === "off") queues.delete(key);
      else queues.set(key, { then: body.then ?? "merge", reason: body.reason, delayMs: body.delayMs });
      return send(res, 204);
    }
    if (req.method === "POST" && url.pathname === "/_threads") {
      threads.set(`${body.owner}/${body.repo}#${body.number}`, body.threads);
      return send(res, 204);
    }
    if (req.method === "POST" && url.pathname === "/graphql") {
      const { owner, repo, number } = body.variables ?? {};
      if (/enqueuePullRequest/.test(body.query ?? "")) {
        const { id, head } = body.variables ?? {};
        const p = pulls.find((x) => `PR_${x.owner}_${x.repo}_${x.number}` === id);
        if (!p) return send(res, 200, { data: { enqueuePullRequest: null }, errors: [{ message: `Could not resolve to a node with the global id of '${id}'` }] });
        const g = grant(req, p.repo, "pull_requests", "write");
        if (g) return deny(g);
        const fail = (message) => send(res, 200, { data: { enqueuePullRequest: null }, errors: [{ type: "UNPROCESSABLE", message }] });
        if (!queueOf(p)) return fail("Merge queue is not enabled for this branch");
        if (p.state !== "open") return fail("Pull request is not open");
        if (head && head !== headOf(p)) return fail("Expected head oid does not match the pull request's head");
        if (!p.queued) enqueue(p);
        return send(res, 200, { data: { enqueuePullRequest: { mergeQueueEntry: { position: 1, state: "QUEUED" } } } });
      }
      if (/pullRequest\(number: \$number\) \{ id \}/.test(body.query ?? "")) {
        const g = grant(req, repo, "pull_requests", "read");
        if (g) return deny(g);
        const p = pulls.find((x) => x.owner === owner && x.repo === repo && x.number === number);
        return send(res, 200, { data: { repository: { pullRequest: p ? { id: `PR_${owner}_${repo}_${number}` } : null } } });
      }
      if (!/reviewThreads/.test(body.query ?? "")) return send(res, 200, { errors: [{ message: "The fake only answers reviewThreads, pullRequest.id and enqueuePullRequest." }] });
      const g = grant(req, repo, "pull_requests", "read");
      if (g) return deny(g);
      const pull = pulls.find((p) => p.owner === owner && p.repo === repo && p.number === number);
      if (!pull) return send(res, 200, { data: { repository: { pullRequest: null } }, errors: [{ message: `Could not resolve to a PullRequest with the number of ${number}.` }] });
      const nodes = (threads.get(`${owner}/${repo}#${number}`) ?? []).map((t, i) => ({
        id: `PRRT_${number}_${i}`, path: t.path, line: t.line ?? null, startLine: t.startLine ?? null, diffSide: t.side ?? "RIGHT",
        isResolved: Boolean(t.resolved), isOutdated: Boolean(t.outdated),
        comments: { nodes: t.comments.map((c) => ({ author: { login: c.author }, body: c.body, createdAt: c.at ?? new Date().toISOString() })) },
      }));
      return send(res, 200, { data: { repository: { pullRequest: { reviewThreads: { pageInfo: { hasNextPage: false, endCursor: null }, nodes } } } } });
    }
    if (req.method === "POST" && url.pathname === "/_leave") {
      const key = `${body.org}:${body.login}`.toLowerCase();
      members.delete(key);
      owners.delete(key);
      return send(res, 200, {});
    }
    if (req.method === "POST" && url.pathname === "/_role") {
      const key = `${body.org}:${body.login}`.toLowerCase();
      if (body.role === "admin") owners.add(key);
      else owners.delete(key);
      return send(res, 200, {});
    }
    if (req.method === "POST" && url.pathname === "/_checks") {
      const list = checkRunsFor(body.owner, body.repo, body.sha);
      for (const r of body.runs) {
        const run = list.find((x) => x.name === r.name);
        Object.assign(run, { status: "completed", conclusion: r.conclusion, ...(r.log ? { log: r.log } : {}) });
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
      const login = /^as-([\w-]+)$/.exec(body?.code ?? body?.device_code ?? "")?.[1];
      return send(res, 200, login ? { access_token: `ghu_fake_${login}`, token_type: "bearer" } : { error: "bad_verification_code" });
    }
    const me = /^Bearer ghu_fake_([\w-]+)$/.exec(req.headers.authorization ?? "")?.[1];
    if (req.method === "GET" && url.pathname === "/user") {
      return me ? send(res, 200, { id: me.length, login: me, name: me, avatar_url: null }) : send(res, 401, { message: "Bad credentials" });
    }
    if (req.method === "GET" && me && (m = url.pathname.match(/^\/user\/memberships\/orgs\/([\w-]+)$/))) {
      const key = `${m[1]}:${me}`.toLowerCase();
      return members.has(key) ? send(res, 200, { state: "active", role: owners.has(key) ? "admin" : "member" }) : send(res, 404, { message: "Not Found" });
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
    if (req.method === "GET" && (m = url.pathname.match(/^\/orgs\/([\w-]+)\/installation$/))) {
      const why = verifyJwt(req.headers.authorization);
      if (why) return send(res, 401, { message: why });
      const i = accounts.indexOf(m[1].toLowerCase());
      return i < 0 ? send(res, 404, { message: "Not Found" }) : send(res, 200, { id: 1000 + i });
    }
    if (req.method === "GET" && (m = url.pathname.match(/^\/orgs\/([\w-]+)\/members\/([\w-]+)$/))) {
      const t = /^token (.+)$/.exec(req.headers.authorization ?? "")?.[1];
      const g = t && tokens.get(t);
      if (!g) return send(res, 401, { message: "Bad credentials" });
      if (!g.permissions?.members || g.installation !== 1000 + accounts.indexOf(m[1].toLowerCase())) return send(res, 403, { message: "Resource not accessible by integration (needs members:read)" });
      return members.has(`${m[1]}:${m[2]}`.toLowerCase()) ? send(res, 204) : send(res, 404, { message: "Not Found" });
    }
    if (req.method === "GET" && (m = url.pathname.match(/^\/orgs\/([\w-]+)\/memberships\/([\w-]+)$/))) {
      const t = /^token (.+)$/.exec(req.headers.authorization ?? "")?.[1];
      const g = t && tokens.get(t);
      if (!g) return send(res, 401, { message: "Bad credentials" });
      if (!g.permissions?.members || g.installation !== 1000 + accounts.indexOf(m[1].toLowerCase())) return send(res, 403, { message: "Resource not accessible by integration (needs members:read)" });
      const key = `${m[1]}:${m[2]}`.toLowerCase();
      return members.has(key) ? send(res, 200, { state: "active", role: owners.has(key) ? "admin" : "member" }) : send(res, 404, { message: "Not Found" });
    }
    if (req.method === "GET" && url.pathname === "/app/installations") {
      const why = verifyJwt(req.headers.authorization);
      if (why) return send(res, 401, { message: why });
      return send(res, 200, accounts.map((login, i) => ({ id: 1000 + i, account: { login, type: ownerType(login) } })));
    }
    if (req.method === "GET" && url.pathname === "/installation/repositories") {
      const t = /^token (.+)$/.exec(req.headers.authorization ?? "")?.[1];
      const g = t && tokens.get(t);
      if (!g) return send(res, 401, { message: "Bad credentials" });
      const page = Number(url.searchParams.get("page") ?? 1);
      const mine = [...installed].filter(([, id]) => id === g.installation).map(([name]) => name);
      const repositories = (page === 1 ? mine : []).map((name) => ({ full_name: name, default_branch: "main", private: !publicRepos.has(name.toLowerCase()) }));
      return send(res, 200, { total_count: mine.length, repositories });
    }
    if (req.method === "POST" && (m = url.pathname.match(/^\/app\/installations\/(\d+)\/access_tokens$/))) {
      const why = verifyJwt(req.headers.authorization);
      if (why) return send(res, 401, { message: why });
      const asked = { installation: Number(m[1]), repositories: body?.repositories, permissions: body?.permissions };
      if (values["no-workflows"] && body?.permissions && "workflows" in body.permissions) {
        tokenRequests.push({ ...asked, status: 422 });
        return send(res, 422, { message: "The permissions requested are not granted to this installation.", documentation_url: "https://docs.github.com/rest/apps/apps#create-an-installation-access-token-for-an-app" });
      }
      tokenRequests.push({ ...asked, status: 201 });
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
        if (queueOf(p)) return send(res, 405, { message: "Repository rule violations found\n\nChanges must be made through the merge queue" });
        if (body.sha && body.sha !== headOf(p)) return send(res, 409, { message: "Head branch was modified. Review and try the merge again." });
        try {
          const sha = squash(p, body.commit_title ?? p.title);
          return send(res, 200, { sha, merged: true, message: "Pull Request successfully merged" });
        } catch (e) {
          return send(res, 405, { message: `Merge conflict: ${e.message.split("\n")[0]}` });
        }
      }
      return send(res, 200, pullJson(p));
    }
    if (req.method === "GET" && (m = url.pathname.match(/^\/repos\/([^/]+)\/([^/]+)\/rules\/branches\/(.+)$/))) {
      const g = grant(req, m[2], "contents", "read");
      if (g) return deny(g);
      const q = queues.get(`${m[1]}/${m[2]}:${decodeURIComponent(m[3])}`.toLowerCase());
      return send(res, 200, q ? [{ type: "merge_queue", ruleset_source_type: "Repository", ruleset_source: `${m[1]}/${m[2]}`, ruleset_id: 1, parameters: { merge_method: "SQUASH" } }] : []);
    }
    if ((m = url.pathname.match(/^\/repos\/([^/]+)\/([^/]+)\/git\/(ref|refs)\/heads\/(.+)$/))) {
      const g = grant(req, m[2], "contents", req.method === "GET" ? "read" : "write");
      if (g) return deny(g);
      const dir = bare(m[1], m[2]);
      const branch = decodeURIComponent(m[4]);
      const sha = headOf({ owner: m[1], repo: m[2], head: branch });
      if (req.method === "GET" && m[3] === "ref") {
        return sha ? send(res, 200, { ref: `refs/heads/${branch}`, object: { type: "commit", sha } }) : send(res, 404, { message: "Not Found" });
      }
      if (req.method === "DELETE" && m[3] === "refs") {
        if (!sha) return send(res, 422, { message: "Reference does not exist" });
        git(dir, "update-ref", "-d", `refs/heads/${branch}`);
        return send(res, 204);
      }
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
        check_runs: list.map((r) => ({
          id: r.id, name: r.name, status: r.status, conclusion: r.conclusion, check_suite: { id: r.suite }, app: { slug: "github-actions" },
          html_url: `https://github.com/${m[1]}/${m[2]}/actions/runs/${RUN}/job/${r.id}`, details_url: `https://github.com/${m[1]}/${m[2]}/actions/runs/${RUN}/job/${r.id}`,
          started_at: new Date(Date.now() - 42_000).toISOString(), completed_at: r.status === "completed" ? new Date().toISOString() : null,
        })),
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
        for (const r of list.filter((x) => x.suite === Number(m[3]) && x.conclusion === "failure")) restart(m[1], m[2], sha, r);
      }
      return send(res, 201, {});
    }
    if (req.method === "POST" && (m = url.pathname.match(/^\/repos\/([^/]+)\/([^/]+)\/actions\/runs\/(\d+)\/rerun-failed-jobs$/))) {
      const g = grant(req, m[2], "actions", "write");
      if (g) return deny(g);
      if (Number(m[3]) !== RUN) return send(res, 404, { message: "Not Found" });
      for (const [key, list] of runs) {
        const [repoKey, sha] = key.split("@");
        if (repoKey !== `${m[1]}/${m[2]}`) continue;
        for (const r of list.filter((x) => x.conclusion === "failure")) restart(m[1], m[2], sha, r);
      }
      return send(res, 201, {});
    }
    if (req.method === "POST" && (m = url.pathname.match(/^\/repos\/([^/]+)\/([^/]+)\/(actions\/jobs|check-runs)\/(\d+)\/(rerun|rerequest)$/))) {
      const actions = m[3] === "actions/jobs";
      if (actions !== (m[5] === "rerun")) return send(res, 404, { message: "Not Found" });
      const g = grant(req, m[2], actions ? "actions" : "checks", "write");
      if (g) return deny(g);
      const found = findRun(m[1], m[2], Number(m[4]));
      if (!found) return send(res, 404, { message: "Not Found" });
      if (found.r.status !== "completed") return send(res, 403, { message: "This job is already running." });
      restart(m[1], m[2], found.sha, found.r);
      return send(res, 201, {});
    }
    if (req.method === "GET" && (m = url.pathname.match(/^\/repos\/([^/]+)\/([^/]+)\/actions\/jobs\/(\d+)\/logs$/))) {
      const g = grant(req, m[2], "actions", "read");
      if (g) return deny(g);
      const found = findRun(m[1], m[2], Number(m[3]));
      if (!found) return send(res, 404, { message: "Not Found" });
      // GitHub redirects to a short-lived blob URL; this one is on the fake itself and needs no token.
      res.writeHead(302, { location: `http://localhost:${values.port}/_blob/job-logs/${m[1]}/${m[2]}/${m[3]}` }).end();
      return;
    }
    if (req.method === "GET" && (m = url.pathname.match(/^\/_blob\/job-logs\/([^/]+)\/([^/]+)\/(\d+)$/))) {
      // Like Azure Blob behind GitHub's real redirect: a signed URL that refuses any other credentials.
      if (req.headers.authorization) return send(res, 400, { message: "Authorization header not allowed on a signed URL." });
      const found = findRun(m[1], m[2], Number(m[3]));
      if (!found) return send(res, 404, { message: "Not Found" });
      return res.writeHead(200, { "content-type": "text/plain" }).end(jobLog(found.r));
    }
    if (req.method === "GET" && (m = url.pathname.match(/^\/repos\/([^/]+)\/([^/]+)\/check-runs\/(\d+)$/))) {
      const g = grant(req, m[2], "checks", "read");
      if (g) return deny(g);
      const found = findRun(m[1], m[2], Number(m[3]));
      if (!found) return send(res, 404, { message: "Not Found" });
      const r = found.r;
      return send(res, 200, { id: r.id, name: r.name, status: r.status, conclusion: r.conclusion, output: { title: r.conclusion === "failure" ? "1 test failed" : "Passed", summary: jobLog(r), text: null } });
    }
    send(res, 404, { message: "Not Found" });
  });
}).listen(Number(values.port), "127.0.0.1", () => console.log(`fake GitHub on http://localhost:${values.port}; installed: ${[...installed.keys()].join(", ") || "none"}`));

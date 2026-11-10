#!/usr/bin/env node
// maple: sets up and updates a Maple Factory in an org's own Cloudflare account.
//
//   npx maple-factory install [--org acme] [--allow octocat,hubot] [--name maple-factory] [--domain factory.acme.dev] [--channel beta] [--account ID]
//   npx maple-factory update [--name maple-factory] [--allow octocat,hubot] [--force]
//   npx maple-factory status [--name maple-factory]
//   npx maple-factory token          # a link that makes the Cloudflare API token install needs
//
// install --dry-run --org ORG checks the release and builds the deploy without touching Cloudflare.
//
// --target celld (experimental) deploys to a celld fleet bucket instead (github.com/denoland/celld, see
// docs/self-hosting.md): install --target celld --bucket s3://NAME [--endpoint URL] --url https://… --org ORG.
// It needs celld 0.6.x on PATH, or CELLD (a command line, e.g. `docker compose run --rm cli`). Bucket
// credentials come from the AWS_* variables and are never saved.
//
// The server comes from maplefactory.dev's signed feed (scripts/release-server.mjs): the manifest must
// be signed with RELEASE_PUBLIC_KEY and the bundle must match its sha256, so neither the feed's host
// nor anything between can hand you a server of its own. Install creates the R2 bucket (waiting
// while you switch R2 on, if it's off) and the D1 database, applies its migrations, deploys the
// Worker (with a custom domain, if you give one) and opens /setup, where an owner of the GitHub org
// makes the factory's GitHub App. What it made is remembered in
// ~/.config/maple-factory/factories/<name>.json, so update knows where to deploy; the token never is.
//
// --allow lists GitHub logins who may sign in besides the org's members (or the account's owner); update
// --allow changes it, and --allow '' empties it. It's kept with the rest, since every deploy sets the vars.
//
// CLOUDFLARE_API_TOKEN skips the token prompt. MAPLE_FEED (or --feed) points at another feed.

import { execFileSync, spawnSync } from "node:child_process";
import { createHash, createPublicKey, randomBytes, verify } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { createInterface } from "node:readline";
import { parseArgs } from "node:util";
import { buildConfig, checkBucket, checkTarget } from "./config.mjs";

/** The release key's public half (scripts/feed.mjs checks it matches the one releases are signed with). */
const RELEASE_PUBLIC_KEY = "-GzUbxnqGXRDK-1jtr3R8x1RIWORNkg_0CSC2BOG6zQ";
const CF = process.env.CLOUDFLARE_API_BASE_URL ?? "https://api.cloudflare.com/client/v4"; // wrangler reads it too
const HOME = join(homedir(), ".config/maple-factory");

const { positionals, values: opts } = parseArgs({
  allowPositionals: true,
  options: {
    org: { type: "string" },
    allow: { type: "string" },
    name: { type: "string", default: "maple-factory" },
    domain: { type: "string" },
    channel: { type: "string" },
    account: { type: "string" },
    feed: { type: "string" },
    target: { type: "string" },
    bucket: { type: "string" },
    endpoint: { type: "string" },
    url: { type: "string" },
    force: { type: "boolean", default: false },
    "dry-run": { type: "boolean", default: false },
    help: { type: "boolean", short: "h", default: false },
  },
});
const feed = (opts.feed ?? process.env.MAPLE_FEED ?? "https://maplefactory.dev/releases").replace(/\/+$/, "");

// ---- output and prompts ----

const color = process.stdout.isTTY && !process.env.NO_COLOR;
const dim = (s) => (color ? `\x1b[2m${s}\x1b[0m` : s);
const ok = (s) => (color ? `\x1b[32m${s}\x1b[0m` : s);
const step = (label, detail = "") => console.log(`${dim(label.padEnd(18))}${detail}`);
class Stop extends Error {}
/** A Cloudflare API refusal, with its error codes (10042: R2 isn't switched on in the account). */
class CloudflareError extends Stop {
  constructor(message, status, codes) {
    super(message);
    this.status = status;
    this.codes = codes;
  }
}
const fail = (message) => { throw new Stop(message); };

async function ask(question, { secret = false, fallback } = {}) {
  if (!process.stdin.isTTY) fail(`${question.replace(/[:?]\s*$/, "")} is needed (and there's no terminal to ask in).`);
  const rl = createInterface({ input: process.stdin, output: process.stdout, terminal: true });
  if (secret) rl._writeToOutput = (s) => { if (s.includes(question)) process.stdout.write(s); };
  const prompt = fallback ? `${question} ${dim(`(${fallback})`)} ` : `${question} `;
  const answer = await new Promise((resolve) => rl.question(prompt, resolve));
  rl.close();
  if (secret) process.stdout.write("\n");
  return answer.trim() || fallback || "";
}

// ---- Cloudflare ----

const TOKEN_PERMISSIONS = [
  { key: "workers_scripts", type: "edit" },
  { key: "d1", type: "edit" },
  { key: "workers_routes", type: "edit" },
  { key: "workers_r2", type: "edit" },
  { key: "zone", type: "read" },
  { key: "account_settings", type: "read" },
];
const tokenLink = () =>
  `https://dash.cloudflare.com/profile/api-tokens?permissionGroupKeys=${encodeURIComponent(JSON.stringify(TOKEN_PERMISSIONS))}&accountId=*&zoneId=all&name=${encodeURIComponent("Maple Factory installer")}`;

async function cf(token, path, init = {}) {
  const res = await fetch(`${CF}${path}`, {
    ...init,
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json", ...init.headers },
  });
  const body = await res.json().catch(() => null);
  if (!body?.success) {
    const why = body?.errors?.map((e) => e.message).join("; ") || `HTTP ${res.status}`;
    throw new CloudflareError(`Cloudflare said no to ${init.method ?? "GET"} ${path}: ${why}`, res.status, (body?.errors ?? []).map((e) => e.code));
  }
  return body.result;
}

async function cloudflareToken() {
  let token = process.env.CLOUDFLARE_API_TOKEN;
  if (!token) {
    console.log(`A Cloudflare API token lets this set up the factory. Make one here (the permissions are filled in):\n  ${tokenLink()}\n`);
    token = await ask("Cloudflare API token:", { secret: true });
  }
  if (!token) fail("No token, so nothing was changed.");
  return token;
}

async function chooseAccount(token, wanted) {
  const accounts = await cf(token, "/accounts?per_page=50");
  if (!accounts.length) fail("That token can't see any Cloudflare account. Give it access to the account the factory goes in.");
  if (wanted) return accounts.find((a) => a.id === wanted) ?? fail(`That token can't see account ${wanted}.`);
  if (accounts.length === 1) return accounts[0];
  accounts.forEach((a, i) => console.log(`  ${i + 1}. ${a.name} ${dim(a.id)}`));
  const pick = Number(await ask("Which account?", { fallback: "1" }));
  return accounts[pick - 1] ?? fail("That isn't one of them.");
}

const R2_NOT_ENTITLED = 10042;

/** R2 is off in an account until someone switches it on in the dashboard (Cloudflare asks for a
 *  payment method, even for the free tier), so wait while they do. */
async function switchOnR2(accountId) {
  const url = `https://dash.cloudflare.com/${accountId}/r2/overview`;
  console.log(`\nR2 isn't switched on in this Cloudflare account yet. The factory keeps runner releases and files
there, so it needs it. It's free to start, but Cloudflare asks for a payment method:\n  ${url}\n`);
  if (!process.stdin.isTTY) fail("Switch R2 on there, then run this again.");
  openInBrowser(url);
  await ask("Press Enter once R2 is on (Ctrl-C to stop here):");
}

/** The factory's bucket, made if it isn't there. */
async function bucket(token, accountId, name) {
  for (;;) {
    try {
      await cf(token, `/accounts/${accountId}/r2/buckets/${name}`);
      return { created: false };
    } catch (e) {
      if (!(e instanceof CloudflareError)) throw e;
      if (e.codes.includes(R2_NOT_ENTITLED)) { await switchOnR2(accountId); continue; }
      if (e.status === 403) fail(`The token can't use R2: give it Workers R2 Storage (Edit). \`maple token\` makes one that can.`);
      if (e.status !== 404) throw e;
    }
    try {
      await cf(token, `/accounts/${accountId}/r2/buckets`, { method: "POST", body: JSON.stringify({ name }) });
      return { created: true };
    } catch (e) {
      if (e instanceof CloudflareError && e.codes.includes(R2_NOT_ENTITLED)) { await switchOnR2(accountId); continue; }
      throw e;
    }
  }
}

async function database(token, account, name) {
  const found = (await cf(token, `/accounts/${account}/d1/database?name=${encodeURIComponent(name)}`)).find((d) => d.name === name);
  if (found) return { id: found.uuid, created: false };
  const made = await cf(token, `/accounts/${account}/d1/database`, { method: "POST", body: JSON.stringify({ name }) });
  return { id: made.uuid, created: true };
}

async function workersDevUrl(token, account, name) {
  try {
    const { subdomain } = await cf(token, `/accounts/${account}/workers/subdomain`);
    return subdomain ? `https://${name}.${subdomain}.workers.dev` : null;
  } catch {
    return null;
  }
}

// ---- the server bundle ----

function publicKey() {
  return createPublicKey({ key: { kty: "OKP", crv: "Ed25519", x: RELEASE_PUBLIC_KEY }, format: "jwk" });
}

async function get(path) {
  const res = await fetch(`${feed}/${path}`);
  if (!res.ok) fail(`Couldn't fetch ${feed}/${path} (${res.status}).`);
  return Buffer.from(await res.arrayBuffer());
}

/** The channel's server release, once its signature checks out. */
async function latestServer(channel) {
  const name = channel === "beta" ? "beta" : "latest";
  const manifest = await get(`maple-server/${name}.json`);
  const sig = Buffer.from((await get(`maple-server/${name}.json.sig`)).toString("utf8").trim(), "base64");
  if (!verify(null, manifest, publicKey(), sig)) fail("The server release's signature doesn't match Maple Factory's release key; not installing it.");
  const parsed = JSON.parse(manifest.toString("utf8"));
  if (!/^maple-server\/[\w.+-]+\/maple-server\.tar\.gz$/.test(parsed.path ?? "") || !/^[0-9a-f]{64}$/.test(parsed.sha256 ?? "")) fail("The server release's manifest isn't valid.");
  return parsed;
}

async function unpack(release, dir) {
  const bytes = await get(release.path);
  if (bytes.length !== release.size) fail(`The server download is ${bytes.length} bytes, not ${release.size}.`);
  const sum = createHash("sha256").update(bytes).digest("hex");
  if (sum !== release.sha256) fail(`The server download's sha256 is ${sum}, not the release's ${release.sha256}.`);
  rmSync(dir, { recursive: true, force: true });
  mkdirSync(dir, { recursive: true });
  const tarball = join(dir, "..", `maple-server-${release.version}.tar.gz`);
  writeFileSync(tarball, bytes);
  execFileSync("tar", ["-xzf", tarball, "-C", dir]);
  rmSync(tarball);
  return JSON.parse(readFileSync(join(dir, "config.json"), "utf8"));
}

/** --allow's logins, checked and tidied; null if it wasn't given. */
function allowList() {
  if (opts.allow === undefined) return null;
  const logins = opts.allow.split(/[\s,]+/).filter(Boolean);
  const bad = logins.find((l) => !/^[A-Za-z0-9-]{1,39}$/.test(l));
  if (bad) fail(`${bad} isn't a GitHub login.`);
  return logins;
}

/** The deployment's wrangler config: the release's shared parts plus this org's (config.mjs). */
function writeConfig(dir, shared, factory) {
  const file = join(dir, "wrangler.json");
  writeFileSync(file, JSON.stringify(buildConfig(shared, factory, factory.target ?? "cloudflare"), null, 2) + "\n");
  return file;
}

function wrangler(token, accountId, argv, { input, quiet = false } = {}) {
  const bin = join(dirname(createRequire(import.meta.url).resolve("wrangler/package.json")), "bin/wrangler.js");
  const result = spawnSync(process.execPath, [bin, ...argv], {
    env: { ...process.env, CLOUDFLARE_API_TOKEN: token, CLOUDFLARE_ACCOUNT_ID: accountId, CI: "1", WRANGLER_SEND_METRICS: "false" },
    input,
    stdio: [input == null ? "ignore" : "pipe", quiet ? "pipe" : "inherit", quiet ? "pipe" : "inherit"],
    encoding: "utf8",
  });
  if (result.status !== 0) {
    if (quiet) process.stderr.write(`${result.stdout ?? ""}${result.stderr ?? ""}`);
    fail(`wrangler ${argv[0]} ${argv[1] ?? ""} didn't work (above).`);
  }
  return result.stdout ?? "";
}

/** Migrations, then the Worker: a new server never runs against an old schema. */
function deploy(token, factory, dir, shared) {
  const config = writeConfig(dir, shared, factory);
  wrangler(token, factory.accountId, ["d1", "migrations", "apply", "DB", "--remote", "-c", config], { quiet: true });
  step("Migrations", ok("applied"));
  wrangler(token, factory.accountId, ["deploy", "-c", config], { quiet: true });
  step("Worker", `${factory.name} ${shared.version} ${ok("deployed")}`);
  return config;
}

// ---- celld (experimental: docs/self-hosting.md) ----

const CELLD_LINE = "0.6."; // the line server/celld/install.sh pins

/** celld's command line: CELLD (split on spaces, so `docker compose run --rm cli` works) or celld on PATH. */
function celldCommand() {
  const words = (process.env.CELLD ?? "celld").trim().split(/\s+/);
  return { bin: words[0], pre: words.slice(1) };
}

function celld(argv, { quiet = true } = {}) {
  const { bin, pre } = celldCommand();
  // jemalloc's background thread doesn't start on macOS; this only quiets its warning.
  const result = spawnSync(bin, [...pre, ...argv], { env: { MALLOC_CONF: "background_thread:false", ...process.env }, encoding: "utf8", stdio: ["ignore", quiet ? "pipe" : "inherit", quiet ? "pipe" : "inherit"] });
  if (result.error?.code === "ENOENT") fail(`There's no ${bin} here. Install celld ${CELLD_LINE}x (server/celld/install.sh) or set CELLD; see docs/self-hosting.md.`);
  const output = `${result.stdout ?? ""}${result.stderr ?? ""}`.split("\n").filter((l) => !/jemalloc|celld::memory/.test(l)).join("\n");
  return { ok: result.status === 0, output };
}

function checkCelld() {
  const { ok: ran, output } = celld(["--version"]);
  const version = output.match(/celld (\d+\.\d+\.\d+)/)?.[1];
  if (!ran || !version) fail(`\`${process.env.CELLD ?? "celld"} --version\` didn't work:\n${output.trim()}`);
  if (!version.startsWith(CELLD_LINE)) fail(`This is celld ${version}; the factory runs on celld ${CELLD_LINE}x (server/celld/install.sh installs it; see docs/self-hosting.md).`);
  return version;
}

const bucketArgs = (factory) => ["--bucket", factory.bucket, ...(factory.endpoint ? ["--endpoint", factory.endpoint] : [])];

function celldMigrate(factory, config, { wait = 0 } = {}) {
  const deadline = Date.now() + wait * 1000;
  for (let told = false; ; ) {
    const run = celld(["d1", "migrations", "apply", factory.name, config, ...bucketArgs(factory)]);
    if (run.ok) {
      const applied = run.output.match(/^Applied .*/gm)?.length ?? 0;
      return step("Migrations", ok(applied ? `${applied} applied` : "up to date"));
    }
    // celld d1 goes through a running node, and a node takes its lease once there's a deployment.
    if (!/no node leases/.test(run.output) || Date.now() > deadline) {
      process.stderr.write(run.output);
      fail(/no node leases/.test(run.output) ? `No celld node is running on ${factory.bucket}. Start the fleet (docs/self-hosting.md), then \`maple update --name ${factory.name} --force\`.` : "celld d1 migrations apply didn't work (above).");
    }
    if (!told) { step("Migrations", `waiting for a celld node on ${factory.bucket}…`); told = true; }
    spawnSync("sleep", ["3"]);
  }
}

function celldDeployWorker(factory, config, version) {
  const run = celld(["deploy", config, ...bucketArgs(factory)]);
  if (!run.ok) { process.stderr.write(run.output); fail("celld deploy didn't work (above)."); }
  step("Worker", `${factory.name} ${version} ${ok("deployed")} ${dim(run.output.match(/Version ID: (\w+)/)?.[1] ?? "")}`);
}

/** Migrations, then the Worker, as on Cloudflare. A first install deploys first: celld d1 needs a running
 *  node, and nodes only take a lease once the bucket has a deployment. Nobody can sign in to a new factory
 *  before /setup, so the moment it runs on an empty schema doesn't matter. */
function deployCelld(factory, dir, shared, { first = false } = {}) {
  const config = writeConfig(dir, shared, factory);
  if (first) {
    celldDeployWorker(factory, config, shared.version);
    celldMigrate(factory, config, { wait: 120 });
  } else {
    celldMigrate(factory, config);
    celldDeployWorker(factory, config, shared.version);
  }
  return config;
}

function celldOptions() {
  const bad = checkBucket(opts.bucket);
  if (bad) fail(bad);
  if (opts.endpoint && !/^https?:\/\/\S+$/.test(opts.endpoint)) fail(`${opts.endpoint} isn't a URL: --endpoint is the S3-compatible endpoint, e.g. http://localhost:9000.`);
  if (opts.url && !/^https?:\/\/[^\s/]+$/.test(opts.url.replace(/\/+$/, ""))) fail(`${opts.url} isn't a URL: --url is the factory's public address, e.g. https://maple.acme.dev.`);
  return { bucket: opts.bucket, endpoint: opts.endpoint ?? null, url: opts.url ? opts.url.replace(/\/+$/, "") : null };
}

async function installCelld(name) {
  const where = celldOptions();
  if (!where.url && !opts["dry-run"]) fail("--target celld needs --url, the factory's public address (it's where GitHub sends people back to).");
  const version = checkCelld();
  step("celld", `${version} ${ok("ok")}`);
  const org = opts.org ?? (opts["dry-run"] ? fail("--dry-run needs --org.") : await ask("GitHub organization, or your username for a factory just for you (the acme in github.com/acme):"));
  if (!/^[A-Za-z0-9-]{1,39}$/.test(org)) fail(`${org || "That"} isn't a GitHub login.`);
  const allow = allowList() ?? [];
  const channel = opts.channel ?? "stable";
  if (!["stable", "beta"].includes(channel)) fail("--channel is stable or beta.");
  const release = await latestServer(channel);
  step("Release", `maple-server ${release.version} (${channel}) ${ok("verified")}`);
  const factory = { name, target: "celld", ...where, org, allow, channel, version: release.version };

  if (opts["dry-run"]) {
    const dir = join(serverDir(name), "..", `${name}.dry-run`);
    const shared = await unpack(release, dir);
    const config = writeConfig(dir, shared, factory);
    const run = celld(["deploy", config, "--dry-run", ...bucketArgs(factory)]);
    if (!run.ok) { process.stderr.write(run.output); fail("celld deploy --dry-run didn't accept the config (above)."); }
    step("celld check", `${run.output.match(/Version ID: \w+/)?.[0] ?? ""} ${ok("ok")}`);
    console.log(`\n${ok("The deploy checks out")}; the config is ${config}`);
    return;
  }

  step("Fleet bucket", `${factory.bucket}${factory.endpoint ? ` at ${factory.endpoint}` : ""}`);
  const dir = serverDir(name);
  const shared = await unpack(release, dir);
  deployCelld(factory, dir, shared, { first: true });
  save({ ...factory, installedAt: new Date().toISOString() });
  const health = await healthy(factory.url, 30);
  if (!health) {
    console.log(`\nDeployed to ${factory.bucket}. ${factory.url} isn't answering yet: check the proxy in front of the nodes (docs/self-hosting.md), then open ${factory.url}/setup.`);
    return;
  }
  console.log(`\n${ok(`Your factory is up → ${factory.url}`)} (maple-server ${health.version} on celld)`);
  if (health.signIn !== "github") console.log(`\nLast step, in the browser: create its GitHub App (you need to be an owner of ${org}):\n  ${factory.url}/setup`);
}

async function healthy(url, seconds = 90) {
  const deadline = Date.now() + seconds * 1000;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`${url}/healthz`);
      if (res.ok) return await res.json();
    } catch {}
    await new Promise((r) => setTimeout(r, 3000));
  }
  return null;
}

// ---- remembered factories ----

const statePath = (name) => join(HOME, "factories", `${name}.json`);
const serverDir = (name) => join(HOME, "factories", name);
function load(name) {
  if (!existsSync(statePath(name))) fail(`There's no factory called ${name} set up from this machine. Run \`maple install\` (or pass --name).`);
  return JSON.parse(readFileSync(statePath(name), "utf8"));
}
function save(factory) {
  mkdirSync(join(HOME, "factories"), { recursive: true, mode: 0o700 });
  writeFileSync(statePath(factory.name), JSON.stringify(factory, null, 2) + "\n", { mode: 0o600 });
}

function openInBrowser(url) {
  const opener = process.platform === "darwin" ? "open" : process.platform === "win32" ? "explorer" : "xdg-open";
  spawnSync(opener, [url], { stdio: "ignore" });
}

// ---- commands ----

async function install() {
  const name = opts.name;
  if (!/^[a-z0-9][a-z0-9-]{0,62}$/.test(name)) fail("--name is lowercase letters, digits and dashes (it's the Worker's name).");
  if (existsSync(statePath(name)) && !opts.force) fail(`${name} is already set up from this machine; \`maple update\` updates it (or --force to install over it).`);

  const target = opts.target ?? "cloudflare";
  const badTarget = checkTarget(target);
  if (badTarget) fail(badTarget);
  if (target === "celld") return installCelld(name);
  if (opts["dry-run"]) return dryRun(name);
  const token = await cloudflareToken();
  const account = await chooseAccount(token, opts.account);
  step("Cloudflare", `${account.name} ${ok("ok")}`);

  const org = opts.org ?? (await ask("GitHub organization, or your username for a factory just for you (the acme in github.com/acme):"));
  if (!/^[A-Za-z0-9-]{1,39}$/.test(org)) fail(`${org || "That"} isn't a GitHub login.`);
  const gh = await fetch(`https://api.github.com/users/${org}`, { headers: { "user-agent": "maple-factory" } });
  if (gh.status === 404) fail(`GitHub has no organization or user called ${org}.`);
  const personal = gh.ok && (await gh.json()).type === "User";
  step("GitHub org", `${org}${personal ? " (personal account: you're its admin)" : ""} ${ok("ok")}`);
  const allow = allowList() ?? [];
  if (allow.length) step("Also allowed", allow.join(", "));

  const domain = opts.domain ?? (process.stdin.isTTY ? await ask("Custom domain (blank for workers.dev):", { fallback: "" }) : "");
  if (domain && !/^[a-z0-9.-]+\.[a-z]{2,}$/i.test(domain)) fail(`${domain} isn't a domain name.`);
  const channel = opts.channel ?? "stable";
  if (!["stable", "beta"].includes(channel)) fail("--channel is stable or beta.");

  // Before anything else is made, since it may need the person to switch R2 on.
  const files = await bucket(token, account.id, name);
  step("Storage", `${name} ${ok(files.created ? "created" : "found")}`);

  const release = await latestServer(channel);
  step("Release", `maple-server ${release.version} (${channel}) ${ok("verified")}`);
  const dir = serverDir(name);
  const shared = await unpack(release, dir);

  const db = await database(token, account.id, name);
  step("Database", `${name} ${ok(db.created ? "created" : "found")}`);
  const factory = { name, accountId: account.id, accountName: account.name, databaseId: db.id, bucket: name, org, allow, channel, domain: domain || null, version: release.version };

  deploy(token, factory, dir, shared);
  // A new factory's cookie key. Not over an existing one: everyone would be signed out.
  if (db.created) {
    wrangler(token, account.id, ["secret", "put", "SESSION_SECRET", "-c", join(dir, "wrangler.json")], { input: randomBytes(32).toString("base64url"), quiet: true });
    step("Secrets", ok("set"));
  }

  const url = domain ? `https://${domain}` : await workersDevUrl(token, account.id, name);
  save({ ...factory, url, installedAt: new Date().toISOString() });
  if (!url) {
    console.log("\nDeployed, but the account has no workers.dev subdomain yet. Pick one in the dashboard (Workers → Settings) or add a custom domain, then open /setup there.");
    return;
  }
  const health = await healthy(url);
  if (!health) {
    console.log(`\nDeployed. ${url} isn't answering yet (a new domain's certificate can take a few minutes). Then open ${url}/setup.`);
    return;
  }
  console.log(`\n${ok(`Your factory is up → ${url}`)}`);
  if (health.signIn !== "github") {
    console.log(`\nLast step, in the browser: create its GitHub App (${personal ? `signed in to GitHub as ${org}` : `you need to be an owner of ${org}`}):\n  ${url}/setup`);
    openInBrowser(`${url}/setup`);
  }
  console.log(`\nThen sign in from the Mac app (Connect to a factory → ${url}) and add machines from Machines → Add machine.`);
}

/** The release, verified and unpacked, and wrangler's own check of the deploy; nothing is uploaded. */
async function dryRun(name) {
  if (!opts.org) fail("--dry-run needs --org.");
  const channel = opts.channel ?? "stable";
  const release = await latestServer(channel);
  step("Release", `maple-server ${release.version} (${channel}) ${ok("verified")}`);
  const dir = join(serverDir(name), "..", `${name}.dry-run`);
  const shared = await unpack(release, dir);
  const factory = { name, accountId: "0".repeat(32), databaseId: "00000000-0000-0000-0000-000000000000", bucket: name, org: opts.org, allow: allowList() ?? [], channel, domain: opts.domain ?? null };
  const config = writeConfig(dir, shared, factory);
  wrangler("dry-run", factory.accountId, ["deploy", "--dry-run", "-c", config]);
  console.log(`\n${ok("The deploy checks out")}; it's in ${dir}.`);
}

async function update() {
  const factory = load(opts.name);
  const channel = opts.channel ?? factory.channel;
  const release = await latestServer(channel);
  const allow = allowList() ?? factory.allow ?? [];
  const sameAllow = allow.join(",") === (factory.allow ?? []).join(",");
  if (release.version === factory.version && channel === factory.channel && sameAllow && !opts.force) {
    console.log(`${factory.name} is on maple-server ${release.version}, the latest ${channel} release.`);
    return;
  }
  if (factory.target === "celld") {
    checkCelld();
    step("Release", `maple-server ${factory.version} → ${release.version} (${channel}) ${ok("verified")}`);
    const next = { ...factory, channel, allow, version: release.version };
    if (!sameAllow) step("Also allowed", allow.length ? allow.join(", ") : "(nobody)");
    deployCelld(next, serverDir(factory.name), await unpack(release, serverDir(factory.name)));
    save({ ...next, updatedAt: new Date().toISOString() });
    console.log(`\n${ok(`${factory.name} is on ${release.version}.`)}`);
    return;
  }
  const token = await cloudflareToken();
  step("Release", `maple-server ${factory.version} → ${release.version} (${channel}) ${ok("verified")}`);
  const dir = serverDir(factory.name);
  const shared = await unpack(release, dir);
  // Factories set up before the server had a bucket get one now.
  const next = { ...factory, channel, allow, version: release.version, bucket: factory.bucket ?? factory.name };
  if (!sameAllow) step("Also allowed", allow.length ? allow.join(", ") : "(nobody)");
  if (!factory.bucket) step("Storage", `${next.bucket} ${ok((await bucket(token, factory.accountId, next.bucket)).created ? "created" : "found")}`);
  deploy(token, next, dir, shared);
  save({ ...next, updatedAt: new Date().toISOString() });
  console.log(`\n${ok(`${factory.name} is on ${release.version}.`)}`);
}

async function status() {
  const factory = load(opts.name);
  const release = await latestServer(factory.channel).catch(() => null);
  step("Factory", `${factory.name} in ${factory.target === "celld" ? `celld (bucket ${factory.bucket}${factory.endpoint ? ` at ${factory.endpoint}` : ""})` : factory.accountName ?? factory.accountId}`);
  step("URL", factory.url ?? "(none yet)");
  step("Org", factory.org);
  if (factory.allow?.length) step("Also allowed", factory.allow.join(", "));
  step("Server", `${factory.version} (${factory.channel})${release && release.version !== factory.version ? `, ${release.version} available: maple update` : ""}`);
  const health = factory.url ? await healthy(factory.url, 5) : null;
  step("Health", health ? `${ok("ok")}, sign-in ${health.signIn}` : "not answering");
}

const usage = `maple: set up and update a Maple Factory in your Cloudflare account

  maple install [--org ORG] [--allow LOGIN,...] [--name maple-factory] [--domain DOMAIN] [--channel stable|beta] [--account ID]
  maple update [--name maple-factory] [--allow LOGIN,...] [--channel stable|beta] [--force]
  maple status [--name maple-factory]
  maple token        a link that makes the Cloudflare API token install needs

  Self-host on celld (experimental, docs/self-hosting.md):
  maple install --target celld --bucket s3://NAME [--endpoint URL] --url https://HOST [--org ORG] [--allow LOGIN,...] [--name maple-factory] [--channel stable|beta]
`;

const commands = { install, update, status, token: async () => console.log(tokenLink()) };
const command = commands[positionals[0]];
if (!command || opts.help) {
  process.stdout.write(usage);
  process.exit(command || opts.help ? 0 : 1);
}
try {
  await command();
} catch (e) {
  if (!(e instanceof Stop)) throw e;
  console.error(`\nmaple: ${e.message}`);
  process.exit(1);
}

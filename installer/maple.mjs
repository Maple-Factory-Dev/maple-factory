#!/usr/bin/env node
// maple: sets up and updates a Maple Factory in an org's own Cloudflare account.
//
//   npx maple-factory install [--org acme] [--name maple-factory] [--domain factory.acme.dev] [--channel beta] [--account ID]
//   npx maple-factory update [--name maple-factory] [--force]
//   npx maple-factory status [--name maple-factory]
//   npx maple-factory token          # a link that makes the Cloudflare API token install needs
//
// install --dry-run --org ORG checks the release and builds the deploy without touching Cloudflare.
//
// The server comes from maplefactory.dev's signed feed (scripts/release-server.mjs): the manifest must
// be signed with RELEASE_PUBLIC_KEY and the bundle must match its sha256, so neither the feed's host
// nor anything between can hand you a server of its own. Install creates the R2 bucket (waiting
// while you switch R2 on, if it's off) and the D1 database, applies its migrations, deploys the
// Worker (with a custom domain, if you give one) and opens /setup, where an owner of the GitHub org
// makes the factory's GitHub App. What it made is remembered in
// ~/.config/maple-factory/factories/<name>.json, so update knows where to deploy; the token never is.
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

/** The release key's public half (scripts/feed.mjs checks it matches the one releases are signed with). */
const RELEASE_PUBLIC_KEY = "-GzUbxnqGXRDK-1jtr3R8x1RIWORNkg_0CSC2BOG6zQ";
const CF = process.env.CLOUDFLARE_API_BASE_URL ?? "https://api.cloudflare.com/client/v4"; // wrangler reads it too
const HOME = join(homedir(), ".config/maple-factory");

const { positionals, values: opts } = parseArgs({
  allowPositionals: true,
  options: {
    org: { type: "string" },
    name: { type: "string", default: "maple-factory" },
    domain: { type: "string" },
    channel: { type: "string" },
    account: { type: "string" },
    feed: { type: "string" },
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

/** The deployment's wrangler config: the release's shared parts plus this org's. */
function writeConfig(dir, shared, factory) {
  const { version: _version, ...rest } = shared;
  const config = {
    ...rest,
    name: factory.name,
    account_id: factory.accountId,
    no_bundle: true,
    workers_dev: true,
    d1_databases: [{ binding: "DB", database_name: factory.name, database_id: factory.databaseId, migrations_dir: "migrations" }],
    r2_buckets: [{ binding: "RELEASES", bucket_name: factory.bucket }],
    vars: { GITHUB_ORG: factory.org, RELEASE_CHANNEL: factory.channel },
    ...(factory.domain ? { routes: [{ pattern: factory.domain, custom_domain: true }] } : {}),
  };
  const file = join(dir, "wrangler.json");
  writeFileSync(file, JSON.stringify(config, null, 2) + "\n");
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

  if (opts["dry-run"]) return dryRun(name);
  const token = await cloudflareToken();
  const account = await chooseAccount(token, opts.account);
  step("Cloudflare", `${account.name} ${ok("ok")}`);

  const org = opts.org ?? (await ask("GitHub organization (the acme in github.com/acme):"));
  if (!/^[A-Za-z0-9-]{1,39}$/.test(org)) fail(`${org || "That"} isn't a GitHub organization login.`);
  const gh = await fetch(`https://api.github.com/orgs/${org}`, { headers: { "user-agent": "maple-factory" } });
  if (gh.status === 404) fail(`GitHub has no organization called ${org}.`);
  step("GitHub org", `${org} ${ok("ok")}`);

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
  const factory = { name, accountId: account.id, accountName: account.name, databaseId: db.id, bucket: name, org, channel, domain: domain || null, version: release.version };

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
    console.log(`\nLast step, in the browser: create its GitHub App (you need to be an owner of ${org}):\n  ${url}/setup`);
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
  const factory = { name, accountId: "0".repeat(32), databaseId: "00000000-0000-0000-0000-000000000000", bucket: name, org: opts.org, channel, domain: opts.domain ?? null };
  const config = writeConfig(dir, shared, factory);
  wrangler("dry-run", factory.accountId, ["deploy", "--dry-run", "-c", config]);
  console.log(`\n${ok("The deploy checks out")}; it's in ${dir}.`);
}

async function update() {
  const factory = load(opts.name);
  const channel = opts.channel ?? factory.channel;
  const release = await latestServer(channel);
  if (release.version === factory.version && channel === factory.channel && !opts.force) {
    console.log(`${factory.name} is on maple-server ${release.version}, the latest ${channel} release.`);
    return;
  }
  const token = await cloudflareToken();
  step("Release", `maple-server ${factory.version} → ${release.version} (${channel}) ${ok("verified")}`);
  const dir = serverDir(factory.name);
  const shared = await unpack(release, dir);
  // Factories set up before the server had a bucket get one now.
  const next = { ...factory, channel, version: release.version, bucket: factory.bucket ?? factory.name };
  if (!factory.bucket) step("Storage", `${next.bucket} ${ok((await bucket(token, factory.accountId, next.bucket)).created ? "created" : "found")}`);
  deploy(token, next, dir, shared);
  save({ ...next, updatedAt: new Date().toISOString() });
  console.log(`\n${ok(`${factory.name} is on ${release.version}.`)}`);
}

async function status() {
  const factory = load(opts.name);
  const release = await latestServer(factory.channel).catch(() => null);
  step("Factory", `${factory.name} in ${factory.accountName ?? factory.accountId}`);
  step("URL", factory.url ?? "(none yet)");
  step("Org", factory.org);
  step("Server", `${factory.version} (${factory.channel})${release && release.version !== factory.version ? `, ${release.version} available: maple update` : ""}`);
  const health = factory.url ? await healthy(factory.url, 5) : null;
  step("Health", health ? `${ok("ok")}, sign-in ${health.signIn}` : "not answering");
}

const usage = `maple: set up and update a Maple Factory in your Cloudflare account

  maple install [--org ORG] [--name maple-factory] [--domain DOMAIN] [--channel stable|beta] [--account ID]
  maple update [--name maple-factory] [--channel stable|beta] [--force]
  maple status [--name maple-factory]
  maple token        a link that makes the Cloudflare API token install needs
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

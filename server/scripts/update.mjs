#!/usr/bin/env node
// Brings a factory deployed with the Deploy to Cloudflare button up to the latest maple-server. The
// button copied server/ into a repo of the deployer's own, which nothing ties back to
// Maple-Factory-Dev/maple-factory, so this does what a pull from it would: when maplefactory.dev's
// feed has a newer release than package.json says, it copies that release's server/ (the
// `server-v<version>` tag) over this repo, keeping this deployment's own values: wrangler.jsonc's
// name, database, bucket, vars and routes, and package.json's name. The Maple Factory update workflow
// (.github/workflows/maple-update.yml) runs it and opens a pull request; merging that redeploys.
//
//   node scripts/update.mjs                         # in the repo: the feed's latest on RELEASE_CHANNEL, if newer
//   node scripts/update.mjs --into ~/copy --from ./server --version 0.2.0   # from a local upstream server/
//
// It only writes into the root of a git repo (the copy), never upstream's own server/. MAPLE_FEED and
// MAPLE_UPSTREAM (owner/repo) point elsewhere. In GitHub Actions it sets the `version` output when it
// changed something.

import { execFileSync } from "node:child_process";
import { appendFileSync, cpSync, existsSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const arg = (name) => { const i = process.argv.indexOf(name); return i > 0 ? process.argv[i + 1] : undefined; };
const FEED = (process.env.MAPLE_FEED || "https://maplefactory.dev/releases").replace(/\/+$/, "");
const UPSTREAM = process.env.MAPLE_UPSTREAM || "Maple-Factory-Dev/maple-factory";
/** What a release replaces wholesale; anything else of the repo's own is left alone. */
const OWNED_DIRS = ["src", "migrations", "web", "test", "scripts", ".github"];
const KEPT = new Set(["wrangler.jsonc", "package.json", ".dev.vars", "node_modules", ".wrangler", ".git"]);

/** JSON with comments and trailing commas, as wrangler.jsonc is written. */
function parseJsonc(text) {
  let out = "", inString = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (inString) {
      out += c;
      if (c === "\\") out += text[++i];
      else if (c === '"') inString = false;
    } else if (c === '"') { inString = true; out += c; }
    else if (c === "/" && text[i + 1] === "/") { while (i < text.length && text[i] !== "\n") i++; out += "\n"; }
    else if (c === "/" && text[i + 1] === "*") { i = text.indexOf("*/", i + 2) + 1; }
    else out += c;
  }
  return JSON.parse(out.replace(/,(\s*[}\]])/g, "$1"));
}

const older = (a, b) => {
  const parts = (v) => v.split("-")[0].split(".").map((n) => Number(n) || 0);
  const [x, y] = [parts(a), parts(b)];
  for (let i = 0; i < Math.max(x.length, y.length); i++) if ((x[i] ?? 0) !== (y[i] ?? 0)) return (x[i] ?? 0) < (y[i] ?? 0);
  return false;
};

/** Upstream's wrangler.jsonc with this deployment's own values in it. */
export function mergeConfig(upstream, mine) {
  const out = { ...upstream };
  for (const key of Object.keys(mine)) if (!(key in upstream)) out[key] = mine[key]; // account_id, routes, observability…
  out.name = mine.name ?? upstream.name;
  const keep = (list, ours, fields) => (list ?? []).map((b) => {
    const own = (ours ?? []).find((o) => o.binding === b.binding);
    return own ? { ...b, ...Object.fromEntries(fields.filter((f) => f in own).map((f) => [f, own[f]])) } : b;
  });
  out.d1_databases = keep(upstream.d1_databases, mine.d1_databases, ["database_name", "database_id", "preview_database_id"]);
  out.r2_buckets = keep(upstream.r2_buckets, mine.r2_buckets, ["bucket_name", "preview_bucket_name", "jurisdiction"]);
  out.vars = { ...upstream.vars, ...mine.vars };
  return out;
}

async function main() {
  const into = resolve(arg("--into") ?? process.cwd());
  // A copy's root is its repo's root; upstream's server/ isn't, which keeps this from emptying it.
  if (!existsSync(join(into, ".git")) || !existsSync(join(into, "wrangler.jsonc"))) {
    throw new Error(`${into} isn't the root of a factory's repo (no .git or wrangler.jsonc there).`);
  }
  const config = parseJsonc(readFileSync(join(into, "wrangler.jsonc"), "utf8"));
  const pkg = JSON.parse(readFileSync(join(into, "package.json"), "utf8"));
  let from = arg("--from") && resolve(arg("--from"));
  let version = arg("--version");
  if (!from) {
    const manifest = config.vars?.RELEASE_CHANNEL === "beta" ? "beta.json" : "latest.json";
    const res = await fetch(`${FEED}/maple-server/${manifest}`);
    if (res.status === 404) return console.log("The feed has no maple-server release yet; nothing to do.");
    if (!res.ok) throw new Error(`The feed didn't answer (${res.status}).`);
    version = (await res.json()).version;
    if (!older(pkg.version, version)) return console.log(`maple-server ${pkg.version} is the latest; nothing to do.`);
    const tmp = mkdtempSync(join(tmpdir(), "maple-update-"));
    const tarball = await fetch(`https://codeload.github.com/${UPSTREAM}/tar.gz/refs/tags/server-v${version}`);
    if (!tarball.ok) throw new Error(`${UPSTREAM} has no server-v${version} tag (${tarball.status}).`);
    writeFileSync(join(tmp, "src.tar.gz"), Buffer.from(await tarball.arrayBuffer()));
    execFileSync("tar", ["-xzf", "src.tar.gz"], { cwd: tmp });
    from = join(tmp, readdirSync(tmp).find((n) => n !== "src.tar.gz"), "server");
  }
  if (!version) throw new Error("--from needs --version.");
  if (!existsSync(join(from, "wrangler.jsonc"))) throw new Error(`${from} isn't a maple-server directory.`);
  if (realpathSync(from) === realpathSync(into)) throw new Error("--from and the repo being updated are the same directory.");

  for (const dir of OWNED_DIRS) {
    rmSync(join(into, dir), { recursive: true, force: true });
    if (existsSync(join(from, dir))) cpSync(join(from, dir), join(into, dir), { recursive: true });
  }
  for (const name of readdirSync(from)) {
    if (OWNED_DIRS.includes(name) || KEPT.has(name)) continue;
    cpSync(join(from, name), join(into, name), { recursive: true });
  }
  const upstreamPkg = JSON.parse(readFileSync(join(from, "package.json"), "utf8"));
  writeFileSync(join(into, "package.json"), JSON.stringify({ ...upstreamPkg, name: pkg.name }, null, 2) + "\n");
  const merged = mergeConfig(parseJsonc(readFileSync(join(from, "wrangler.jsonc"), "utf8")), config);
  writeFileSync(join(into, "wrangler.jsonc"),
    `// This factory's Worker. scripts/update.mjs keeps it up to date from ${UPSTREAM}'s server/wrangler.jsonc\n` +
    `// (see there for what each part is), keeping this deployment's name, database, bucket, vars and routes.\n` +
    JSON.stringify(merged, null, 2) + "\n");

  console.log(`Updated to maple-server ${version} (was ${pkg.version}).`);
  if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, `version=${version}\nprevious=${pkg.version}\n`);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((e) => { console.error(`update: ${e.message}`); process.exit(1); });
}

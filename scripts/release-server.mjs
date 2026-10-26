#!/usr/bin/env node
// Builds the factory server into one signed bundle on the feed, which `maple install` and `maple update`
// deploy into an org's Cloudflare account (the Deploy to Cloudflare button builds from the repo instead):
//
//   node scripts/release-server.mjs --to feed [--channel beta] [--notes "…"]
//   node scripts/release-server.mjs --to dir:PATH        # a local feed, to try the installer against
//
// The bundle (maple-server/<version>/maple-server.tar.gz) holds:
//   worker/     the Worker, already bundled by wrangler (deployed with no_bundle)
//   web/        the static assets
//   migrations/ D1 migrations, applied in order before the new Worker goes live
//   config.json what every deploy shares from server/wrangler.jsonc: compatibility, Durable Objects
//               and their migrations. The installer adds the account's own parts (name, D1 id, domain, vars).

import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { cpSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { destination, option, publish, releaseKey, root } from "./feed.mjs";

/** JSON with comments and trailing commas, as wrangler.jsonc is written. */
export function parseJsonc(source) {
  let out = "";
  for (let i = 0; i < source.length; i++) {
    const c = source[i];
    if (c === '"') {
      let j = i + 1;
      while (j < source.length && source[j] !== '"') j += source[j] === "\\" ? 2 : 1;
      out += source.slice(i, j + 1);
      i = j;
    } else if (c === "/" && source[i + 1] === "/") {
      while (i < source.length && source[i] !== "\n") i++;
      out += "\n";
    } else if (c === "/" && source[i + 1] === "*") {
      i = source.indexOf("*/", i + 2) + 1;
    } else out += c;
  }
  return JSON.parse(out.replace(/,(\s*[}\]])/g, "$1"));
}

const where = destination();
const key = releaseKey(["runner/src/update.rs", "installer/maple.mjs"]);
const server = join(root, "server");
const version = JSON.parse(readFileSync(join(server, "package.json"), "utf8")).version;
const dev = parseJsonc(readFileSync(join(server, "wrangler.jsonc"), "utf8"));

const stage = mkdtempSync(join(tmpdir(), `maple-server-${version}-`));
execFileSync("npx", ["wrangler", "deploy", "--dry-run", "--outdir", join(stage, "worker")], { cwd: server, stdio: "inherit" });
rmSync(join(stage, "worker", "README.md"), { force: true }); // wrangler's note about the folder
for (const name of readdirSync(join(stage, "worker"))) if (!/\.(js|mjs|wasm|map)$/.test(name)) throw new Error(`Unexpected file in the bundle: ${name}`);
cpSync(join(server, dev.assets.directory), join(stage, "web"), { recursive: true });
cpSync(join(server, "migrations"), join(stage, "migrations"), { recursive: true });
const config = {
  version,
  main: "worker/index.js",
  compatibility_date: dev.compatibility_date,
  compatibility_flags: dev.compatibility_flags ?? [],
  assets: { ...dev.assets, directory: "web" },
  durable_objects: dev.durable_objects,
  migrations: dev.migrations,
};
writeFileSync(join(stage, "config.json"), JSON.stringify(config, null, 2) + "\n");

const tarball = join(tmpdir(), `maple-server-${version}.tar.gz`);
execFileSync("tar", ["-czf", tarball, "-C", stage, "."], { env: { ...process.env, COPYFILE_DISABLE: "1" } });
const bytes = readFileSync(tarball);
const path = `maple-server/${version}/maple-server.tar.gz`;
const manifest = {
  version,
  published_at: new Date().toISOString(),
  notes: option("--notes") ?? null,
  path,
  sha256: createHash("sha256").update(bytes).digest("hex"),
  size: statSync(tarball).size,
};
const names = await publish("maple-server", manifest, [[path, tarball, "application/gzip"]], key, where);
console.log(`\nReleased maple-server ${version} to ${where.to} (${names.map((n) => `${n}.json`).join(", ")}).`);

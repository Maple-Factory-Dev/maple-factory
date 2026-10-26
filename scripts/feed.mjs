// What release-runner.mjs and release-server.mjs share: the release key, signed manifests, and where
// a release goes (--to):
//
//   feed       maplefactory.dev's feed (the maplefactory-releases bucket), which every factory falls back
//              to and `maple install` deploys from. --channel beta publishes beta.json only; a stable
//              release is latest.json, and beta.json too unless the beta there is newer.
//   factory    one factory's own bucket (maple-releases), for an org that builds its own runners.
//   local      `wrangler dev`'s copy of that bucket.
//   dir:PATH   files in a folder, laid out like the feed (to serve and test against).
//
// The private key lives at ~/.config/maple-factory/release-key.pem (MAPLE_RELEASE_KEY to move it),
// never in the repo; runner/src/update.rs and installer/maple.mjs build in the public half. Without
// that key a stolen Worker or bucket can't push a release anyone will run, so keep a copy somewhere safe.

import { execFileSync } from "node:child_process";
import { createPrivateKey, createPublicKey, generateKeyPairSync, sign } from "node:crypto";
import { copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const root = join(dirname(fileURLToPath(import.meta.url)), "..");
export const FEED_URL = "https://maplefactory.dev/releases";
const keyPath = process.env.MAPLE_RELEASE_KEY ?? join(homedir(), ".config/maple-factory/release-key.pem");

export const args = process.argv.slice(2);
export const flag = (name) => args.includes(name);
export const option = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : undefined; };

/** The raw 32-byte public key, base64url without padding: what RELEASE_PUBLIC_KEY holds. */
const publicHalf = (key) => Buffer.from(createPublicKey(key).export({ format: "jwk" }).x, "base64url").toString("base64url");

export function newKey() {
  if (existsSync(keyPath)) throw new Error(`${keyPath} already exists; releases signed with it would stop verifying if it changed.`);
  const { privateKey } = generateKeyPairSync("ed25519");
  mkdirSync(dirname(keyPath), { recursive: true, mode: 0o700 });
  writeFileSync(keyPath, privateKey.export({ format: "pem", type: "pkcs8" }), { mode: 0o600 });
  console.log(`Wrote ${keyPath}. Back it up; put this in runner/src/update.rs and installer/maple.mjs as RELEASE_PUBLIC_KEY:\n${publicHalf(privateKey)}`);
}

/** The signing key, after checking that `files` (repo paths) all build in its public half. */
export function releaseKey(files) {
  if (!existsSync(keyPath)) throw new Error(`No signing key at ${keyPath}. Make one with --new-key.`);
  const key = createPrivateKey(readFileSync(keyPath));
  for (const file of files) {
    const built = readFileSync(join(root, file), "utf8").match(/RELEASE_PUBLIC_KEY(?:: &str)? = "([^"]+)"/)?.[1];
    if (built !== publicHalf(key)) throw new Error(`${file} has RELEASE_PUBLIC_KEY ${built}, but ${keyPath} is ${publicHalf(key)}; it wouldn't trust this release.`);
  }
  return key;
}

/** Where this release goes, from --to (or --local). */
export function destination() {
  const to = flag("--local") ? "local" : option("--to");
  if (!to || !(["feed", "factory", "local"].includes(to) || to.startsWith("dir:"))) {
    throw new Error("Say where the release goes: --to feed (maplefactory.dev), --to factory (your factory's bucket), --local, or --to dir:PATH.");
  }
  const channel = option("--channel") ?? "stable";
  if (!["stable", "beta"].includes(channel)) throw new Error("--channel is stable or beta.");
  if (channel === "beta" && to !== "feed" && !to.startsWith("dir:")) throw new Error("Only the feed has channels; a factory's bucket serves one release.");
  return { to, channel };
}

const numbers = (v) => v.split(/[.+-]/).map((p) => (/^\d+$/.test(p) ? Number(p) : p));
/** Compares versions like 0.24.0 and 0.25.0-beta.1; a prerelease sorts before its release. */
export function compareVersions(a, b) {
  const [ca, pa = ""] = a.split("-", 2), [cb, pb = ""] = b.split("-", 2);
  const x = numbers(ca), y = numbers(cb);
  for (let i = 0; i < Math.max(x.length, y.length); i++) if ((x[i] ?? 0) !== (y[i] ?? 0)) return (x[i] ?? 0) < (y[i] ?? 0) ? -1 : 1;
  if (pa === pb) return 0;
  if (!pa || !pb) return pa ? -1 : 1;
  return pa < pb ? -1 : 1;
}

function put(to, path, file, type) {
  if (to.startsWith("dir:")) {
    const out = join(to.slice(4), path);
    mkdirSync(dirname(out), { recursive: true });
    copyFileSync(file, out);
    return;
  }
  const [bucket, cwd] = to === "feed" ? ["maplefactory-releases", "apps/site"] : ["maple-releases", "server"];
  execFileSync("npx", ["wrangler", "r2", "object", "put", `${bucket}/${path}`, "--file", file, "--content-type", type, to === "local" ? "--local" : "--remote"],
    { stdio: "inherit", cwd: join(root, cwd) });
}

/** The beta manifest's version in the feed now, or null. */
async function currentBeta(to, product) {
  try {
    if (to.startsWith("dir:")) return JSON.parse(readFileSync(join(to.slice(4), product, "beta.json"), "utf8")).version ?? null;
    const res = await fetch(`${FEED_URL}/${product}/beta.json`);
    return res.ok ? ((await res.json()).version ?? null) : null;
  } catch {
    return null;
  }
}

/** Uploads `files` ([path, file, type]), then the signed manifest for the channel(s), so a manifest
 *  never points at something that isn't there yet. */
export async function publish(product, manifest, files, key, { to, channel }) {
  const out = join(tmpdir(), `maple-release-${product}-${manifest.version}`);
  mkdirSync(out, { recursive: true });
  const manifestFile = join(out, "manifest.json");
  writeFileSync(manifestFile, JSON.stringify(manifest, null, 2) + "\n");
  writeFileSync(`${manifestFile}.sig`, sign(null, readFileSync(manifestFile), key).toString("base64") + "\n");

  const names = [];
  if (channel === "stable") names.push("latest");
  const onFeed = to === "feed" || to.startsWith("dir:");
  if (onFeed) {
    const beta = await currentBeta(to, product);
    if (channel === "beta" || !beta || compareVersions(beta, manifest.version) < 0) names.push("beta");
    else console.log(`(beta.json stays at ${beta}, which is newer.)`);
  }
  for (const [path, file, type] of files) put(to, path, file, type);
  for (const name of names) {
    put(to, `${product}/${name}.json.sig`, `${manifestFile}.sig`, "text/plain");
    put(to, `${product}/${name}.json`, manifestFile, "application/json");
  }
  return names;
}

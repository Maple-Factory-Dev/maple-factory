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
// The private key comes from MAPLE_RELEASE_KEY_PEM (the PEM text itself, for CI; RELEASING.md), else the
// file at MAPLE_RELEASE_KEY, else ~/.config/maple-factory/release-key.pem; never from the repo.
// runner/src/update.rs and installer/maple.mjs build in the public half. Without that key a stolen Worker
// or bucket can't push a release anyone will run, so keep a copy somewhere safe.
//
// Uploads run `npx --no-install wrangler`: with CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID set it needs
// no login and never prompts (neither wrangler.jsonc names an account, so the token needs the ID beside it);
// without them it uses your `wrangler login`.

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

/** The private signing key and where it came from (named in errors; the key itself never is). */
export function signingKey() {
  const pem = process.env.MAPLE_RELEASE_KEY_PEM;
  if (pem) {
    try {
      return { key: createPrivateKey(pem.replace(/\\n/g, "\n")), source: "MAPLE_RELEASE_KEY_PEM" };
    } catch {
      throw new Error("MAPLE_RELEASE_KEY_PEM isn't a PEM private key.");
    }
  }
  if (!existsSync(keyPath)) throw new Error(`No signing key: set MAPLE_RELEASE_KEY_PEM, or make one at ${keyPath} with --new-key.`);
  try {
    return { key: createPrivateKey(readFileSync(keyPath)), source: keyPath };
  } catch {
    throw new Error(`${keyPath} isn't a PEM private key.`);
  }
}

/** The signing key, after checking that `files` (repo paths) all build in its public half. */
export function releaseKey(files) {
  const { key, source } = signingKey();
  for (const file of files) {
    const built = readFileSync(join(root, file), "utf8").match(/RELEASE_PUBLIC_KEY(?:: &str)? = "([^"]+)"/)?.[1];
    if (built !== publicHalf(key)) throw new Error(`${file} has RELEASE_PUBLIC_KEY ${built}, but ${source} is ${publicHalf(key)}; it wouldn't trust this release.`);
  }
  return key;
}

/** Fails before any upload when a Cloudflare token is set without its account (wrangler would go
 *  looking for the account, which a CI token may not be allowed to do). */
export function checkCloudflareEnv() {
  if (process.env.CLOUDFLARE_API_TOKEN && !process.env.CLOUDFLARE_ACCOUNT_ID) {
    throw new Error("CLOUDFLARE_API_TOKEN is set without CLOUDFLARE_ACCOUNT_ID; set both (RELEASING.md).");
  }
}

/** Runs wrangler from the repo's install, never fetching it or asking to. */
export function wrangler(argv, opts) {
  checkCloudflareEnv();
  return execFileSync("npx", ["--no-install", "wrangler", ...argv], opts);
}

/** Tags HEAD `<prefix><version>` and pushes the tag to origin, after checking `paths` are committed,
 *  HEAD is on origin, and the tag isn't there yet. Release bases are these pushed tags, so CI sees them. */
export function tagRelease(prefix, version, paths, message = `${prefix}${version}`) {
  const git = (...argv) => execFileSync("git", argv, { cwd: root, encoding: "utf8" }).trim();
  const tag = `${prefix}${version}`;
  if (git("status", "--porcelain", "--", ...paths)) throw new Error(`${paths.join(", ")} has uncommitted changes; the release is tagged from what's committed.`);
  git("fetch", "-q", "origin");
  if (git("branch", "-r", "--contains", "HEAD") === "") throw new Error("Push this commit first: the release is tagged from what's on GitHub.");
  if (git("ls-remote", "--tags", "origin", tag)) throw new Error(`${tag} is already released; bump the version.`);
  git("tag", "-a", tag, "-m", message);
  git("push", "-q", "origin", tag);
  console.log(`Tagged ${tag}.`);
  return tag;
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
  if (!to.startsWith("dir:")) checkCloudflareEnv(); // before a build, not at its first upload
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
  wrangler(["r2", "object", "put", `${bucket}/${path}`, "--file", file, "--content-type", type, to === "local" ? "--local" : "--remote"],
    { stdio: "inherit", cwd: join(root, cwd) });
}

/** A file already at `path` where this release goes (parsed as JSON), or null when there's none. */
export async function fetchJson(to, path) {
  try {
    if (to.startsWith("dir:")) return JSON.parse(readFileSync(join(to.slice(4), path), "utf8"));
    if (to === "feed") {
      const res = await fetch(`${FEED_URL}/${path}`);
      return res.ok ? await res.json() : null;
    }
    const file = join(tmpdir(), `maple-get-${process.pid}.json`);
    wrangler(["r2", "object", "get", `maple-releases/${path}`, "--file", file, to === "local" ? "--local" : "--remote"],
      { stdio: "ignore", cwd: join(root, "server") });
    return JSON.parse(readFileSync(file, "utf8"));
  } catch {
    return null;
  }
}

/** Uploads `value` as JSON to `path`. */
export function putJson(to, path, value) {
  const file = join(tmpdir(), `maple-put-${process.pid}-${path.replace(/\W+/g, "-")}`);
  writeFileSync(file, JSON.stringify(value, null, 2) + "\n");
  put(to, path, file, "application/json");
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

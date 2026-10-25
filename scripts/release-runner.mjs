#!/usr/bin/env node
// Builds maple-runner for each target, signs a manifest for them and uploads both to the releases
// bucket, where `/install.sh` and every runner's self-update find them:
//
//   node scripts/release-runner.mjs [--local] [--targets aarch64-apple-darwin,…] [--notes "…"]
//   node scripts/release-runner.mjs --new-key        # once: makes the signing key, prints its public half
//
// The private key lives at ~/.config/maple-factory/release-key.pem (MAPLE_RELEASE_KEY to move it),
// never in the repo; runner/src/update.rs builds in the public half. Without that key a stolen
// Worker or bucket can't push a runner anyone will run, so keep a copy somewhere safe.
// --local uploads to `wrangler dev`'s bucket instead of the real one. Linux targets build in Docker
// (the official rust image), so it needs to be running.

import { execFileSync } from "node:child_process";
import { createHash, createPrivateKey, createPublicKey, generateKeyPairSync, sign } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const keyPath = process.env.MAPLE_RELEASE_KEY ?? join(homedir(), ".config/maple-factory/release-key.pem");
const args = process.argv.slice(2);
const flag = (name) => args.includes(name);
const option = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : undefined; };

/** The raw 32-byte public key, base64url without padding: what RELEASE_PUBLIC_KEY holds. */
const publicHalf = (key) => Buffer.from(createPublicKey(key).export({ format: "jwk" }).x, "base64url").toString("base64url");

if (flag("--new-key")) {
  if (existsSync(keyPath)) throw new Error(`${keyPath} already exists; releases signed with it would stop verifying if it changed.`);
  const { privateKey } = generateKeyPairSync("ed25519");
  mkdirSync(dirname(keyPath), { recursive: true, mode: 0o700 });
  writeFileSync(keyPath, privateKey.export({ format: "pem", type: "pkcs8" }), { mode: 0o600 });
  console.log(`Wrote ${keyPath}. Back it up; put this in runner/src/update.rs as RELEASE_PUBLIC_KEY:\n${publicHalf(privateKey)}`);
  process.exit(0);
}

if (!existsSync(keyPath)) throw new Error(`No signing key at ${keyPath}. Make one with --new-key.`);
const key = createPrivateKey(readFileSync(keyPath));
const built = readFileSync(join(root, "runner/src/update.rs"), "utf8").match(/RELEASE_PUBLIC_KEY: &str = "([^"]+)"/)?.[1];
if (built !== publicHalf(key)) throw new Error(`runner/src/update.rs has RELEASE_PUBLIC_KEY ${built}, but ${keyPath} is ${publicHalf(key)}; runners wouldn't trust this release.`);

const host = execFileSync("rustc", ["-vV"], { encoding: "utf8" }).match(/^host: (.+)$/m)[1];
const targets = (option("--targets") ?? "aarch64-apple-darwin,x86_64-apple-darwin,x86_64-unknown-linux-gnu,aarch64-unknown-linux-gnu").split(",");
const version = readFileSync(join(root, "runner/Cargo.toml"), "utf8").match(/^version = "([^"]+)"/m)[1];
const run = (cmd, argv, opts = {}) => execFileSync(cmd, argv, { stdio: "inherit", cwd: join(root, "runner"), ...opts });

const manifest = { version, published_at: new Date().toISOString(), notes: option("--notes") ?? null, targets: {} };
const uploads = [];
for (const target of targets) {
  const linux = target.includes("linux");
  console.log(`\n▸ ${target}`);
  if (linux) {
    // In the official Rust image for that platform (emulated when it isn't this Mac's), on bullseye so
    // the binary's glibc (2.31) is old enough for most distros still in use.
    const platform = target.startsWith("aarch64") ? "linux/arm64" : "linux/amd64";
    run("docker", ["run", "--rm", "--platform", platform, "-v", `${join(root, "runner")}:/src`, "-v", `maple-cargo-${platform.split("/")[1]}:/usr/local/cargo/registry`,
      "-w", "/src", "rust:1-bullseye", "cargo", "build", "--release", "--target-dir", `target/docker-${target}`]);
  } else {
    if (target !== host) run("rustup", ["target", "add", target]);
    run("cargo", ["build", "--release", "--target", target]);
  }
  const file = linux ? join(root, "runner/target", `docker-${target}`, "release/maple-runner") : join(root, "runner/target", target, "release/maple-runner");
  // macOS kills unsigned binaries on Apple silicon; sign with the Developer ID when there is one.
  if (!linux) run("codesign", ["--force", "--options", "runtime", "--sign", process.env.SIGN_IDENTITY ?? "-", file]);
  const bytes = readFileSync(file);
  const path = `maple-runner/${version}/${target}/maple-runner`;
  manifest.targets[target] = { path, sha256: createHash("sha256").update(bytes).digest("hex"), size: statSync(file).size };
  uploads.push([path, file, "application/octet-stream"]);
}

const out = join(tmpdir(), `maple-release-${version}`);
mkdirSync(out, { recursive: true });
const manifestFile = join(out, "latest.json");
writeFileSync(manifestFile, JSON.stringify(manifest, null, 2) + "\n");
writeFileSync(`${manifestFile}.sig`, sign(null, readFileSync(manifestFile), key).toString("base64") + "\n");
// Binaries first, so the manifest never points at something that isn't there yet.
uploads.push(["maple-runner/latest.json.sig", `${manifestFile}.sig`, "text/plain"], ["maple-runner/latest.json", manifestFile, "application/json"]);
for (const [path, file, type] of uploads) {
  run("npx", ["wrangler", "r2", "object", "put", `maple-releases/${path}`, "--file", file, "--content-type", type, flag("--local") ? "--local" : "--remote"], { cwd: join(root, "server") });
}
chmodSync(manifestFile, 0o644);
console.log(`\nReleased maple-runner ${version} for ${targets.join(", ")}${flag("--local") ? " (local bucket)" : ""}.`);

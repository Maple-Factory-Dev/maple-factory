#!/usr/bin/env node
// Builds maple-runner for each target, signs a manifest for them and uploads both, where `/install.sh`
// and every runner's self-update find them (scripts/feed.mjs says where --to can send it):
//
//   node scripts/release-runner.mjs --to feed [--channel beta] [--targets aarch64-apple-darwin,…] [--notes "…"]
//   node scripts/release-runner.mjs --to factory | --local | --to dir:PATH
//   node scripts/release-runner.mjs --new-key        # once: makes the signing key, prints its public half
//
// Linux targets build in Docker (the official rust image), so it needs to be running.

import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { destination, flag, newKey, option, publish, releaseKey, root } from "./feed.mjs";

if (flag("--new-key")) {
  newKey();
  process.exit(0);
}

const where = destination();
const key = releaseKey(["runner/src/update.rs"]);
if (where.to === "feed" && !process.env.SIGN_IDENTITY) throw new Error("The feed's macOS runners are signed with the Developer ID: set SIGN_IDENTITY.");

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

const names = await publish("maple-runner", manifest, uploads, key, where);
console.log(`\nReleased maple-runner ${version} for ${targets.join(", ")} to ${where.to} (${names.map((n) => `${n}.json`).join(", ")}).`);

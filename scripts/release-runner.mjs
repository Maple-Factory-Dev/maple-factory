#!/usr/bin/env node
// Builds maple-runner for each target, signs a manifest for them and uploads both, where `/install.sh`
// and every runner's self-update find them (scripts/feed.mjs says where --to can send it):
//
//   node scripts/release-runner.mjs --to feed [--channel beta] [--targets aarch64-apple-darwin,…] [--notes "…"]
//   node scripts/release-runner.mjs --to factory | --local | --to dir:PATH
//   node scripts/release-runner.mjs --new-key        # once: makes the signing key, prints its public half
//
// The manifest's notes are runner/CHANGELOG.md's section for the version (--notes overrides them), and the
// release goes to the front of maple-runner/changes.json, the list of releases the Mac app shows as What's new.
//
// Linux targets build in Docker (the official rust image), so it needs to be running.

import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { compareVersions, destination, fetchJson, flag, newKey, option, publish, putJson, releaseKey, root } from "./feed.mjs";

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

/** CHANGELOG.md's section for `v` (the lines under its `## v — date` heading), or null. */
function changelogNotes(markdown, v) {
  const lines = markdown.split("\n");
  const start = lines.findIndex((l) => new RegExp(`^## ${v.replace(/\./g, "\\.")}(\\s|$)`).test(l));
  if (start < 0) return null;
  const end = lines.findIndex((l, i) => i > start && l.startsWith("## "));
  return lines.slice(start + 1, end < 0 ? undefined : end).join("\n").trim() || null;
}

/** Every section of CHANGELOG.md as a release entry, its date as publishedAt: changes.json's start on a feed that has none. */
function changelogReleases(markdown) {
  return [...markdown.matchAll(/^## (\S+)(?: — (\d{4}-\d{2}-\d{2}))?\s*$/gm)].map(([, v, date]) => ({
    version: v, publishedAt: date ? `${date}T00:00:00.000Z` : null, notes: changelogNotes(markdown, v),
  }));
}

/** changes.json with this release at the front: newest first, one entry per version, 50 at most. */
function withRelease(changes, entry) {
  const rest = (Array.isArray(changes?.releases) ? changes.releases : []).filter((r) => r?.version && r.version !== entry.version);
  return { releases: [entry, ...rest].sort((a, b) => compareVersions(b.version, a.version)).slice(0, 50) };
}

const changelog = readFileSync(join(root, "runner/CHANGELOG.md"), "utf8");
const notes = option("--notes") ?? changelogNotes(changelog, version);
if (!notes) console.warn(`(runner/CHANGELOG.md has no section for ${version}; the release goes out without notes.)`);
const manifest = { version, published_at: new Date().toISOString(), notes, targets: {} };
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
const changes = (await fetchJson(where.to, "maple-runner/changes.json")) ?? { releases: changelogReleases(changelog) };
putJson(where.to, "maple-runner/changes.json", withRelease(changes, { version, publishedAt: manifest.published_at, notes }));
console.log(`\nReleased maple-runner ${version} for ${targets.join(", ")} to ${where.to} (${[...names.map((n) => `${n}.json`), "changes.json"].join(", ")}).`);

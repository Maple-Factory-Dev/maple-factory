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
// A feed release is tagged runner-v<version> on GitHub first (the next release's base), so runner/ has to be
// committed and pushed, and that tag must not exist yet.
//
// Linux targets build in Docker (the official rust image), so it needs to be running.
// Every target builds at once, each logging to runner/target/release-logs/<target>.log; --serial builds them
// one at a time with the output in the terminal (for debugging, or a Docker VM that runs out of memory).

import { execFileSync, spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { createWriteStream, mkdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { compareVersions, destination, fetchJson, flag, newKey, option, publish, putJson, releaseKey, root, tagRelease } from "./feed.mjs";

if (flag("--new-key")) {
  newKey();
  process.exit(0);
}

const where = destination();
const key = releaseKey(["runner/src/update.rs"]);
if (where.to === "feed" && !process.env.SIGN_IDENTITY) throw new Error("The feed's macOS runners are signed with the Developer ID: set SIGN_IDENTITY.");

const host = execFileSync("rustc", ["-vV"], { encoding: "utf8" }).match(/^host: (.+)$/m)[1];
// Apple silicon only on macOS: there's no Intel Mac build.
const targets = (option("--targets") ?? "aarch64-apple-darwin,x86_64-unknown-linux-gnu,aarch64-unknown-linux-gnu").split(",");
const version = readFileSync(join(root, "runner/Cargo.toml"), "utf8").match(/^version = "([^"]+)"/m)[1];
// Release builds report errors to Maple Factory's Sentry project; the DSN is built in (runner/src/telemetry.rs).
const sentryDsn = JSON.parse(readFileSync(join(root, "server/web/sentry.json"), "utf8")).projects.runner.dsn;
if (where.to === "feed" && !sentryDsn) throw new Error("server/web/sentry.json has no runner DSN.");
if (where.to === "feed") tagRelease("runner-v", version, ["runner"], `maple-runner ${version}`);
const run = (cmd, argv, opts = {}) => execFileSync(cmd, argv, { stdio: "inherit", cwd: join(root, "runner"), env: { ...process.env, MAPLE_SENTRY_DSN: sentryDsn }, ...opts });

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
const serial = flag("--serial");
const env = { ...process.env, MAPLE_SENTRY_DSN: sentryDsn };
const logDir = join(root, "runner/target/release-logs");
const logFile = (target) => join(logDir, `${target}.log`);
const elapsed = (ms) => { const s = Math.round(ms / 1000); return s >= 60 ? `${Math.floor(s / 60)}m${String(s % 60).padStart(2, "0")}s` : `${s}s`; };
const builtFile = (target) => target.includes("linux")
  ? join(root, "runner/target", `docker-${target}`, "release/maple-runner")
  : join(root, "runner/target", target, "release/maple-runner");

/** The command that builds `target`: cargo here, or cargo in Docker for Linux. */
function buildCommand(target) {
  if (!target.includes("linux")) return ["cargo", ["build", "--release", "--target", target]];
  // In the official Rust image for that platform (emulated when it isn't this Mac's), on bullseye so
  // the binary's glibc (2.31) is old enough for most distros still in use.
  const platform = { aarch64: "linux/arm64", x86_64: "linux/amd64" }[target.split("-")[0]];
  if (!platform) throw new Error(`No Docker platform for ${target}: Linux targets are x86_64-… or aarch64-….`);
  return ["docker", ["run", "--rm", "--platform", platform, "-v", `${join(root, "runner")}:/src`, "-v", `maple-cargo-${platform.split("/")[1]}:/usr/local/cargo/registry`,
    "-e", "MAPLE_SENTRY_DSN", "-w", "/src", "rust:1-bullseye", "cargo", "build", "--release", "--target-dir", `target/docker-${target}`]];
}

/** Builds `target`, its output going to its log (or the terminal with --serial). Resolves with the built file. */
function buildTarget(target) {
  return new Promise((resolve, reject) => {
    const started = Date.now();
    const log = serial ? null : createWriteStream(logFile(target));
    let settled = false;
    const fail = (message) => { if (settled) return; settled = true; log?.end(`\n${message}\n`); reject(new Error(message)); };
    let cmd, argv;
    try { [cmd, argv] = buildCommand(target); } catch (e) { return fail(e.message); }
    console.log(serial ? `\n▸ ${target} started` : `▸ ${target} started`);
    log?.write(`$ ${cmd} ${argv.join(" ")}\n`);
    const child = spawn(cmd, argv, { cwd: join(root, "runner"), env, stdio: serial ? "inherit" : ["ignore", "pipe", "pipe"] });
    child.stdout?.pipe(log, { end: false });
    child.stderr?.pipe(log, { end: false });
    child.on("error", (e) => fail(`${cmd} didn't start: ${e.message}`));
    child.on("close", (code, signal) => {
      if (code !== 0) return fail(`${cmd} exited with ${signal ?? code}`);
      if (settled) return;
      settled = true;
      log?.end();
      console.log(`✓ ${target} built in ${elapsed(Date.now() - started)}`);
      resolve(builtFile(target));
    });
  });
}

/** The last `n` lines of `target`'s log. */
function logTail(target, n = 40) {
  try { return readFileSync(logFile(target), "utf8").trimEnd().split("\n").slice(-n).join("\n"); } catch { return "(no log)"; }
}

mkdirSync(logDir, { recursive: true });
const toAdd = targets.filter((t) => !t.includes("linux") && t !== host);
if (toAdd.length) run("rustup", ["target", "add", ...toAdd]);

const buildStart = Date.now();
const results = [];
if (serial) {
  for (const target of targets) results.push(await buildTarget(target).then((value) => ({ status: "fulfilled", value }), (reason) => ({ status: "rejected", reason })));
} else {
  const pending = new Set(targets);
  const heartbeat = setInterval(() => console.log(`… still building ${[...pending].join(", ")} (${elapsed(Date.now() - buildStart)})`), 30_000);
  results.push(...await Promise.allSettled(targets.map((t) => buildTarget(t).finally(() => pending.delete(t)))));
  clearInterval(heartbeat);
}
const failed = targets.filter((_, i) => results[i].status === "rejected");
if (failed.length) {
  for (const target of failed) {
    console.error(`\n✗ ${target} failed: ${results[targets.indexOf(target)].reason.message}`);
    if (!serial) console.error(`--- last 40 lines of ${logFile(target)} ---\n${logTail(target)}\n---`);
  }
  console.error(`\nNothing was signed or published: ${failed.join(", ")} didn't build.`);
  process.exit(1);
}
console.log(`\nBuilt ${targets.length} target${targets.length === 1 ? "" : "s"} in ${elapsed(Date.now() - buildStart)}${serial ? " (serial)" : ""}.`);

const manifest = { version, published_at: new Date().toISOString(), notes, targets: {} };
const uploads = [];
for (const [i, target] of targets.entries()) {
  const file = results[i].value;
  // macOS kills unsigned binaries on Apple silicon; sign with the Developer ID when there is one.
  if (!target.includes("linux")) run("codesign", ["--force", "--options", "runtime", "--sign", process.env.SIGN_IDENTITY ?? "-", file]);
  const bytes = readFileSync(file);
  const path = `maple-runner/${version}/${target}/maple-runner`;
  manifest.targets[target] = { path, sha256: createHash("sha256").update(bytes).digest("hex"), size: statSync(file).size };
  uploads.push([path, file, "application/octet-stream"]);
}

const names = await publish("maple-runner", manifest, uploads, key, where);
const changes = (await fetchJson(where.to, "maple-runner/changes.json")) ?? { releases: changelogReleases(changelog) };
putJson(where.to, "maple-runner/changes.json", withRelease(changes, { version, publishedAt: manifest.published_at, notes }));
console.log(`\nReleased maple-runner ${version} for ${targets.join(", ")} to ${where.to} (${[...names.map((n) => `${n}.json`), "changes.json"].join(", ")}).`);

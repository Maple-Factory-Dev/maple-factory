#!/usr/bin/env node
// Builds maple-runner for each target, signs a manifest for them and uploads both, where `/install.sh`
// and every runner's self-update find them (scripts/feed.mjs says where --to can send it):
//
//   node scripts/release-runner.mjs --to feed [--channel beta] [--targets aarch64-apple-darwin,…] [--notes "…"]
//   node scripts/release-runner.mjs --to factory | --local | --to dir:PATH
//   node scripts/release-runner.mjs --new-key        # once: makes the signing key, prints its public half
//
// That is `build` for every target into runner/target/release-dist, then `publish` from there. CI
// (.github/workflows/release-runner.yml) runs the two halves on different machines:
//
//   node scripts/release-runner.mjs build --target <triple> --out DIR
//       one target into DIR/<triple>/maple-runner and maple-runner.sha256 (macOS signed with SIGN_IDENTITY)
//   node scripts/release-runner.mjs publish --from DIR --to … [--channel beta] [--targets …] [--notes "…"]
//       checks every target's binary against its .sha256, signs the manifest, uploads
//
// The manifest's notes are runner/CHANGELOG.md's section for the version (--notes overrides them), and the
// release goes to the front of maple-runner/changes.json, the list of releases the Mac app shows as What's new.
//
// A feed release is tagged runner-v<version> on GitHub (the next release's base), so runner/ has to be
// committed and pushed. With no subcommand that tag must not exist yet; `publish` also accepts it when it
// already points at HEAD (CI pushes it before the builds start).
//
// A target for this machine's own OS and arch builds with cargo here (CI's legs, and Linux inside the
// rust:1-bullseye container); other Linux targets build in Docker (the official rust image), so it needs to
// be running. Every target builds at once, each logging to runner/target/release-logs/<target>.log; --serial
// builds them one at a time with the output in the terminal (for debugging, or a Docker VM that runs out of memory).

import { execFileSync, spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { copyFileSync, createWriteStream, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { args, compareVersions, destination, fetchJson, flag, newKey, option, publish, putJson, releaseKey, root, tagRelease } from "./feed.mjs";

if (flag("--new-key")) {
  newKey();
  process.exit(0);
}

const command = ["build", "publish"].includes(args[0]) ? args[0] : null;
// Apple silicon only on macOS: there's no Intel Mac build.
const ALL_TARGETS = ["aarch64-apple-darwin", "x86_64-unknown-linux-gnu", "aarch64-unknown-linux-gnu"];
const version = readFileSync(join(root, "runner/Cargo.toml"), "utf8").match(/^version = "([^"]+)"/m)[1];
const serial = flag("--serial");
const logDir = join(root, "runner/target/release-logs");
const logFile = (target) => join(logDir, `${target}.log`);
const elapsed = (ms) => { const s = Math.round(ms / 1000); return s >= 60 ? `${Math.floor(s / 60)}m${String(s % 60).padStart(2, "0")}s` : `${s}s`; };
const sha256 = (file) => createHash("sha256").update(readFileSync(file)).digest("hex");

/** Release builds report errors to Maple Factory's Sentry project; the DSN is built in (runner/src/telemetry.rs). */
function sentryDsn() {
  return process.env.MAPLE_SENTRY_DSN || JSON.parse(readFileSync(join(root, "server/web/sentry.json"), "utf8")).projects.runner.dsn;
}

const host = () => execFileSync("rustc", ["-vV"], { encoding: "utf8" }).match(/^host: (.+)$/m)[1];
/** Same arch and OS as this machine (`x86_64-unknown-linux-gnu` and `x86_64-unknown-linux-gnu`, say). */
const native = (target, h) => target.split("-")[0] === h.split("-")[0] && target.includes("linux") === h.includes("linux") && target.includes("darwin") === h.includes("darwin");

/** The command that builds `target` and the file it writes: cargo here, or cargo in Docker for a Linux
 *  target that isn't this machine's. */
function buildCommand(target, h) {
  if (!target.includes("linux") || native(target, h)) {
    return [["cargo", ["build", "--release", "--target", target]], join(root, "runner/target", target, "release/maple-runner")];
  }
  // In the official Rust image for that platform (emulated when it isn't this Mac's), on bullseye so
  // the binary's glibc (2.31) is old enough for most distros still in use.
  const platform = { aarch64: "linux/arm64", x86_64: "linux/amd64" }[target.split("-")[0]];
  if (!platform) throw new Error(`No Docker platform for ${target}: Linux targets are x86_64-… or aarch64-….`);
  return [["docker", ["run", "--rm", "--platform", platform, "-v", `${join(root, "runner")}:/src`, "-v", `maple-cargo-${platform.split("/")[1]}:/usr/local/cargo/registry`,
    "-e", "MAPLE_SENTRY_DSN", "-w", "/src", "rust:1-bullseye", "cargo", "build", "--release", "--target-dir", `target/docker-${target}`]],
    join(root, "runner/target", `docker-${target}`, "release/maple-runner")];
}

/** Builds `target`, its output going to its log (or the terminal with --serial). Resolves with the built file. */
function buildTarget(target, h, env, toLog) {
  return new Promise((resolve, reject) => {
    const started = Date.now();
    const log = toLog ? createWriteStream(logFile(target)) : null;
    let settled = false;
    const fail = (message) => { if (settled) return; settled = true; log?.end(`\n${message}\n`); reject(new Error(message)); };
    let cmd, argv, built;
    try { [[cmd, argv], built] = buildCommand(target, h); } catch (e) { return fail(e.message); }
    console.log(toLog ? `▸ ${target} started` : `\n▸ ${target} started`);
    log?.write(`$ ${cmd} ${argv.join(" ")}\n`);
    const child = spawn(cmd, argv, { cwd: join(root, "runner"), env, stdio: toLog ? ["ignore", "pipe", "pipe"] : "inherit" });
    child.stdout?.pipe(log, { end: false });
    child.stderr?.pipe(log, { end: false });
    child.on("error", (e) => fail(`${cmd} didn't start: ${e.message}`));
    child.on("close", (code, signal) => {
      if (code !== 0) return fail(`${cmd} exited with ${signal ?? code}`);
      if (settled) return;
      settled = true;
      log?.end();
      console.log(`✓ ${target} built in ${elapsed(Date.now() - started)}`);
      resolve(built);
    });
  });
}

/** The last `n` lines of `target`'s log. */
function logTail(target, n = 40) {
  try { return readFileSync(logFile(target), "utf8").trimEnd().split("\n").slice(-n).join("\n"); } catch { return "(no log)"; }
}

/** Copies a built binary to `out`/<target>/maple-runner (signing it first for macOS) and writes its sha256 beside it. */
function stage(target, built, out) {
  const dir = join(out, target);
  rmSync(dir, { recursive: true, force: true });
  mkdirSync(dir, { recursive: true });
  const file = join(dir, "maple-runner");
  copyFileSync(built, file);
  // macOS kills unsigned binaries on Apple silicon; sign with the Developer ID when there is one.
  if (target.includes("darwin")) {
    if (!process.env.SIGN_IDENTITY) console.warn(`(No SIGN_IDENTITY: ${target} is signed ad hoc, which only this Mac trusts.)`);
    execFileSync("codesign", ["--force", "--options", "runtime", "--sign", process.env.SIGN_IDENTITY ?? "-", file], { stdio: "inherit" });
  }
  writeFileSync(`${file}.sha256`, `${sha256(file)}  maple-runner\n`);
  return file;
}

/** Builds `targets` and stages each into `out`. Exits when any fails, before anything is staged. */
async function buildAll(targets, out, { toLog }) {
  const h = host();
  const env = { ...process.env, MAPLE_SENTRY_DSN: sentryDsn() };
  if (!env.MAPLE_SENTRY_DSN) throw new Error("server/web/sentry.json has no runner DSN.");
  mkdirSync(logDir, { recursive: true });
  const toAdd = targets.filter((t) => !t.includes("linux") || native(t, h)).filter((t) => t !== h);
  if (toAdd.length) execFileSync("rustup", ["target", "add", ...toAdd], { stdio: "inherit" });

  const buildStart = Date.now();
  const results = [];
  if (!toLog) {
    for (const target of targets) results.push(await buildTarget(target, h, env, false).then((value) => ({ status: "fulfilled", value }), (reason) => ({ status: "rejected", reason })));
  } else {
    const pending = new Set(targets);
    const heartbeat = setInterval(() => console.log(`… still building ${[...pending].join(", ")} (${elapsed(Date.now() - buildStart)})`), 30_000);
    results.push(...await Promise.allSettled(targets.map((t) => buildTarget(t, h, env, true).finally(() => pending.delete(t)))));
    clearInterval(heartbeat);
  }
  const failed = targets.filter((_, i) => results[i].status === "rejected");
  if (failed.length) {
    for (const target of failed) {
      console.error(`\n✗ ${target} failed: ${results[targets.indexOf(target)].reason.message}`);
      if (toLog) console.error(`--- last 40 lines of ${logFile(target)} ---\n${logTail(target)}\n---`);
    }
    console.error(`\nNothing was signed or published: ${failed.join(", ")} didn't build.`);
    process.exit(1);
  }
  console.log(`\nBuilt ${targets.length} target${targets.length === 1 ? "" : "s"} in ${elapsed(Date.now() - buildStart)}${toLog ? "" : " (serial)"}.`);
  for (const [i, target] of targets.entries()) console.log(`  ${stage(target, results[i].value, out)}`);
}

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

/** runner-v<version> on origin: tags HEAD when it isn't there yet; when it is, it has to be HEAD
 *  (CI's prepare job pushed it), or this would publish a tree other than the tagged one. */
function ensureTag() {
  const git = (...argv) => execFileSync("git", argv, { cwd: root, encoding: "utf8" }).trim();
  const tag = `runner-v${version}`;
  const remote = git("ls-remote", "--tags", "origin", `refs/tags/${tag}`, `refs/tags/${tag}^{}`);
  if (!remote) return tagRelease("runner-v", version, ["runner"], `maple-runner ${version}`);
  // An annotated tag lists its commit on the ^{} line.
  const lines = remote.split("\n").map((l) => l.split(/\s+/));
  const commit = (lines.find(([, ref]) => ref.endsWith("^{}")) ?? lines[0])[0];
  const head = git("rev-parse", "HEAD");
  if (commit !== head) throw new Error(`${tag} is already on origin at ${commit.slice(0, 10)}, not HEAD (${head.slice(0, 10)}); bump the version, or publish from that commit.`);
  console.log(`${tag} is on origin at HEAD.`);
  return tag;
}

/** Checks the binaries in `from`, signs their manifest and uploads it all to `where`. */
async function publishFrom(from, targets, where, key, { tag }) {
  const files = {};
  const problems = [];
  for (const target of targets) {
    const file = join(from, target, "maple-runner");
    if (!existsSync(file) || !existsSync(`${file}.sha256`)) { problems.push(`${target}: no ${file} with its .sha256`); continue; }
    const want = readFileSync(`${file}.sha256`, "utf8").trim().split(/\s+/)[0];
    const got = sha256(file);
    if (want !== got) { problems.push(`${target}: maple-runner's sha256 is ${got}, but maple-runner.sha256 says ${want}`); continue; }
    files[target] = { file, sha256: got };
  }
  const extra = existsSync(from) ? readdirSync(from).filter((d) => statSync(join(from, d)).isDirectory() && !targets.includes(d)) : [];
  if (extra.length) console.warn(`(Not publishing ${extra.join(", ")}: not in --targets.)`);
  if (problems.length) throw new Error(`Nothing was published:\n  ${problems.join("\n  ")}`);

  const changelog = readFileSync(join(root, "runner/CHANGELOG.md"), "utf8");
  const notes = option("--notes") ?? changelogNotes(changelog, version);
  if (!notes) console.warn(`(runner/CHANGELOG.md has no section for ${version}; the release goes out without notes.)`);
  if (tag) ensureTag();

  const manifest = { version, published_at: new Date().toISOString(), notes, targets: {} };
  const uploads = [];
  for (const target of targets) {
    const { file, sha256: hash } = files[target];
    const path = `maple-runner/${version}/${target}/maple-runner`;
    manifest.targets[target] = { path, sha256: hash, size: statSync(file).size };
    uploads.push([path, file, "application/octet-stream"]);
  }
  const names = await publish("maple-runner", manifest, uploads, key, where);
  const changes = (await fetchJson(where.to, "maple-runner/changes.json")) ?? { releases: changelogReleases(changelog) };
  putJson(where.to, "maple-runner/changes.json", withRelease(changes, { version, publishedAt: manifest.published_at, notes }));
  console.log(`\nReleased maple-runner ${version} for ${targets.join(", ")} to ${where.to} (${[...names.map((n) => `${n}.json`), "changes.json"].join(", ")}).`);
}

const targetsOption = () => (option("--targets") ?? ALL_TARGETS.join(",")).split(",");

if (command === "build") {
  const target = option("--target");
  const out = option("--out");
  if (!target || !out) throw new Error("build --target <triple> --out DIR");
  await buildAll([target], resolve(out), { toLog: false });
} else if (command === "publish") {
  const from = option("--from");
  if (!from) throw new Error("publish --from DIR --to …");
  const where = destination();
  const key = releaseKey(["runner/src/update.rs"]);
  await publishFrom(resolve(from), targetsOption(), where, key, { tag: where.to === "feed" });
} else {
  const where = destination();
  const key = releaseKey(["runner/src/update.rs"]);
  if (where.to === "feed" && !process.env.SIGN_IDENTITY) throw new Error("The feed's macOS runners are signed with the Developer ID: set SIGN_IDENTITY.");
  const targets = targetsOption();
  // Tagged before building, as before: a tag already on origin stops the release here.
  if (where.to === "feed") tagRelease("runner-v", version, ["runner"], `maple-runner ${version}`);
  const out = join(root, "runner/target/release-dist");
  await buildAll(targets, out, { toLog: !serial });
  await publishFrom(out, targets, where, key, { tag: where.to === "feed" });
}

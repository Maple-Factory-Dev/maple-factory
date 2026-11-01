#!/usr/bin/env node
// Releases Maple Factory.app: a notarized DMG and the Sparkle appcast every install checks (every 6
// hours, and from Maple Factory > Check for Updates…). Each stage is its own command, so one that
// fails late (a notarization timeout, an expired R2 token) can be run again without the ones before it:
//
//   node apps/mac/scripts/release.mjs new 0.2.0 [--channel beta]   # releases/0.2.0/notes.md, and bumps version.json
//   node apps/mac/scripts/release.mjs ship 0.2.0 [--yes]           # build → notarize → dmg → sign → appcast → publish
//
// What a person decided (version, build, channel, notes) is releases/<v>/notes.md; what was measured
// from the DMG (its length and EdDSA signature) is releases/<v>/release.json. Both are committed, so
// the appcast can be made again from the repo with no DMG at hand. One appcast carries both channels:
// a beta is tagged <sparkle:channel>beta</sparkle:channel>, a release isn't (an untagged item is the
// one every install takes).
//
// Credentials and where it goes come from the environment, then apps/mac/.env.release (gitignored, and
// optional when the environment has them all; see .env.release.example and RELEASING.md). Notarizing uses
// NOTARY_PROFILE (a keychain profile) or else an App Store Connect API key (NOTARY_KEY_ID, NOTARY_ISSUER_ID,
// NOTARY_KEY: the .p8 text or its path). The DMG and notes are signed with the Sparkle key in
// SPARKLE_PRIVATE_KEY (its text), SPARKLE_KEY_FILE, or the login keychain (the one Screenie uses);
// bundle.sh builds in its public half as SUPublicEDKey. Nothing prompts once `ship` has --yes.
//
// `build` tags the tree it built mac-v<version> and pushes it to origin: the next release's base. A
// rehearsal (MAPLE_RELEASES_DIR set) or --no-tag doesn't.

import { execFileSync } from "node:child_process";
import { copyFileSync, cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { createInterface } from "node:readline/promises";
import { fileURLToPath } from "node:url";

const here = join(dirname(fileURLToPath(import.meta.url)), "..");
// Both movable, to rehearse a release in a scratch folder without touching the repo's.
const RELEASES = process.env.MAPLE_RELEASES_DIR ?? join(here, "releases");
const SITE = process.env.MAPLE_SITE_DIR ?? join(here, "build/updates-site");
const APP = join(here, "build/Maple Factory.app");
const NAME = "Maple Factory";
const MINIMUM_SYSTEM = "15.0";

const [command, version] = process.argv.slice(2);
const option = (name) => { const i = process.argv.indexOf(name); return i > 0 ? process.argv[i + 1] : undefined; };
const run = (cmd, argv, opts = {}) => { console.log(`  $ ${cmd} ${argv.join(" ")}`); execFileSync(cmd, argv, { stdio: "inherit", cwd: here, ...opts }); };
const capture = (cmd, argv) => execFileSync(cmd, argv, { cwd: here, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
const heading = (text) => console.log(`\n── ${text} ${"─".repeat(Math.max(0, 60 - text.length))}`);
const ok = (text) => console.log(`  ✓ ${text}`);
const fail = (text) => { throw new Error(text); };
const flag = (name) => process.argv.includes(name);
// Every stage says how long it took, and `ship` ends with them all and a total: where a release's time goes.
const stages = [];
const elapsed = (ms) => { const s = Math.round(ms / 1000); return s >= 60 ? `${Math.floor(s / 60)}m${String(s % 60).padStart(2, "0")}s` : `${s}s`; };
function timed(name, fn) {
  const start = Date.now();
  const result = fn();
  stages.push([name, Date.now() - start]);
  ok(`${name} in ${elapsed(Date.now() - start)}`);
  return result;
}
function timings() {
  heading("Timings");
  for (const [name, ms] of stages) console.log(`  ${name.padEnd(28)} ${elapsed(ms)}`);
  console.log(`  ${"total".padEnd(28)} ${elapsed(stages.reduce((sum, [, ms]) => sum + ms, 0))}`);
}

/** .env.release into process.env, without overriding what's already set. Optional: in CI the
 *  environment has it all, and need() says what's missing from both. */
function loadEnv() {
  const file = join(here, ".env.release");
  for (const line of existsSync(file) ? readFileSync(file, "utf8").split("\n") : []) {
    const [, key, value] = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/) ?? [];
    if (key && !process.env[key]) process.env[key] = value.replace(/^"(.*)"$/, "$1");
  }
  secretFiles();
}
function need(...names) {
  const missing = names.filter((n) => !process.env[n]);
  if (missing.length) fail(`Missing in the environment or .env.release: ${missing.join(", ")}`);
  return names.map((n) => process.env[n]);
}

// Secrets passed as text (SPARKLE_PRIVATE_KEY, NOTARY_KEY) go to 0600 files in a 0700 folder that's
// removed on exit, since the tools only read keys from files.
let secretsDir = null;
function secretFile(name, text) {
  if (!secretsDir) {
    secretsDir = mkdtempSync(join(tmpdir(), "maple-release-secrets-"));
    process.on("exit", () => rmSync(secretsDir, { recursive: true, force: true }));
  }
  const file = join(secretsDir, name);
  writeFileSync(file, text.replace(/\\n/g, "\n").trimEnd() + "\n", { mode: 0o600 });
  return file;
}
function secretFiles() {
  if (process.env.SPARKLE_PRIVATE_KEY && !process.env.SPARKLE_KEY_FILE) {
    process.env.SPARKLE_KEY_FILE = secretFile("sparkle-key", process.env.SPARKLE_PRIVATE_KEY);
  }
}
secretFiles(); // SPARKLE_PRIVATE_KEY from the environment, even for a stage that doesn't load .env.release

/** notarytool's credentials: the keychain profile when NOTARY_PROFILE is set, else the API key. */
function notaryArgs() {
  if (process.env.NOTARY_PROFILE) return ["--keychain-profile", process.env.NOTARY_PROFILE];
  if (!(process.env.NOTARY_KEY_ID || process.env.NOTARY_ISSUER_ID || process.env.NOTARY_KEY)) {
    fail("Missing in the environment or .env.release: NOTARY_PROFILE, or NOTARY_KEY_ID + NOTARY_ISSUER_ID + NOTARY_KEY");
  }
  const [id, issuer, key] = need("NOTARY_KEY_ID", "NOTARY_ISSUER_ID", "NOTARY_KEY");
  const file = key.includes("BEGIN PRIVATE KEY") ? secretFile(`AuthKey_${id}.p8`, key) : key;
  if (!existsSync(file)) fail("NOTARY_KEY is neither a .p8 key's text nor the path of one.");
  return ["--key", file, "--key-id", id, "--issuer", issuer];
}
const updatesURL = () => (process.env.UPDATES_URL || "https://updates.maplefactory.dev").replace(/\/+$/, "");
const signIdentity = () => process.env.SIGN_IDENTITY || "Developer ID Application: Andrea Fomera (TU4485Z3KR)";
const sparkleBin = (name) => {
  const path = join(here, ".build/artifacts/sparkle/Sparkle/bin", name);
  if (!existsSync(path)) fail(`No ${path}: run \`swift build\` in apps/mac first.`);
  return path;
};

// MARK: releases

function loadRelease(dir) {
  const raw = readFileSync(join(dir, "notes.md"), "utf8");
  const [, front, body] = raw.match(/^---\s*\n([\s\S]*?\n)---\s*\n([\s\S]*)$/) ?? fail(`${dir}/notes.md has no frontmatter.`);
  const meta = Object.fromEntries(front.split("\n").filter((l) => l.includes(":")).map((l) => {
    const i = l.indexOf(":");
    return [l.slice(0, i).trim(), l.slice(i + 1).trim().replace(/^"(.*)"$/, "$1")];
  }));
  const channel = meta.channel ?? "stable";
  if (!["stable", "beta"].includes(channel)) fail(`${dir}: channel is stable or beta, not ${channel}.`);
  const artifacts = existsSync(join(dir, "release.json")) ? JSON.parse(readFileSync(join(dir, "release.json"), "utf8")) : null;
  const v = meta.version;
  const dmgName = `Maple-Factory-${v}.dmg`;
  return {
    dir, version: v, build: Number(meta.build), channel, date: meta.date, markdown: body,
    minimumSystem: meta.minimumSystemVersion ?? MINIMUM_SYSTEM, artifacts,
    beta: channel === "beta", dmgName,
    siteDir: join(SITE, "releases", v),
    dmgURL: `${updatesURL()}/releases/${v}/${dmgName}`,
    notesURL: `${updatesURL()}/releases/${v}/notes.html`,
    title: `${NAME} ${v}${channel === "beta" ? " (Beta)" : ""}`,
  };
}
const allReleases = () => (existsSync(RELEASES) ? readdirSync(RELEASES) : [])
  .filter((v) => existsSync(join(RELEASES, v, "notes.md"))).map((v) => loadRelease(join(RELEASES, v)))
  .sort((a, b) => b.build - a.build);
function release(v) {
  if (!v) fail(`usage: release.mjs ${command} <version>`);
  if (!existsSync(join(RELEASES, v, "notes.md"))) fail(`No releases/${v}/notes.md: run \`release.mjs new ${v}\` first.`);
  return loadRelease(join(RELEASES, v));
}

const versionFile = process.env.MAPLE_VERSION_FILE ?? join(here, "version.json");
const current = () => JSON.parse(readFileSync(versionFile, "utf8"));
const bump = (v, build) => { writeFileSync(versionFile, JSON.stringify({ version: v, build }) + "\n"); console.log(`  version.json → ${v} (${build})`); };

// MARK: html

const escape = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
/** The notes' markdown: ### headings, - bullets, `code`, **bold**, *italic* and http(s) links. Anything
 *  else is an escaped paragraph, so the HTML in Sparkle's window is only these tags. */
function markdown(text) {
  const inline = (s) => {
    const codes = [];
    return escape(s)
      .replace(/`([^`]+)`/g, (_, c) => `\u0000${codes.push(c) - 1}\u0000`)
      .replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (_, label, href) => `<a href="${/^(https?:\/\/|\/|#)/.test(href) ? href : "#"}">${label}</a>`)
      .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
      .replace(/(?<!\*)\*([^*]+)\*(?!\*)/g, "<em>$1</em>")
      .replace(/\u0000(\d+)\u0000/g, (_, i) => `<code>${codes[i]}</code>`);
  };
  const out = [];
  let list = null;
  const close = () => { if (list?.length) out.push(`<ul>\n${list.join("\n")}\n</ul>`); list = null; };
  for (const line of text.split("\n").map((l) => l.trimEnd())) {
    let m;
    if (!line.trim()) close();
    else if ((m = line.match(/^(#{1,6})\s+(.*)$/))) { close(); out.push(`<h${m[1].length}>${inline(m[2])}</h${m[1].length}>`); }
    else if ((m = line.match(/^\s*[-*]\s+(.*)$/))) (list ??= []).push(`  <li>${inline(m[1])}</li>`);
    else { close(); out.push(`<p>${inline(line.trim())}</p>`); }
  }
  close();
  return out.join("\n");
}

/** The notes' look, shared by notes.html and changelog.html. notes.html is signed, so changing a byte
 *  here means signing every release again: add to the changelog's own style instead. */
const NOTES_STYLE = `  :root { --bg: #fbf9f8; --fg: #3a3540; --strong: #24202a; --muted: #77707f; --rule: rgba(36, 32, 42, .1); --accent: #d24e26; }
  @media (prefers-color-scheme: dark) { :root { --bg: #18161c; --fg: #d6d2da; --strong: #fff; --muted: #9a94a2; --rule: rgba(255, 255, 255, .1); --accent: #ff7a48; } }
  body { margin: 0; padding: 20px 24px; background: var(--bg); color: var(--fg); font: 13px/1.6 system-ui, sans-serif; }
  header { border-bottom: 1px solid var(--rule); padding-bottom: 12px; margin-bottom: 16px; }
  h1 { font-size: 17px; margin: 0; color: var(--strong); }
  .date { color: var(--muted); font-size: 12px; margin-top: 4px; }
  .badge { display: inline-block; margin-left: 8px; padding: 1px 7px; border-radius: 999px; font-size: 11px; font-weight: 600; color: var(--accent); border: 1px solid var(--accent); }
  h2, h3 { font-size: 13px; color: var(--strong); margin: 16px 0 6px; }
  ul { margin: 0; padding-left: 20px; }
  li { margin: 4px 0; }
  a { color: var(--accent); }
  code { background: var(--rule); border-radius: 4px; padding: 1px 4px; font-size: 12px; }
`;
/** A release's version, Beta badge and date, then its notes. */
const releaseNotes = (r, tag = "h1") => `<header>
  <${tag}>${escape(NAME)} ${escape(r.version)}${r.beta ? '<span class="badge">Beta</span>' : ""}</${tag}>
  <div class="date">${escape(r.date)}</div>
</header>
${markdown(r.markdown)}`;

/** What Sparkle's update window shows: self-contained, since an external stylesheet that's slow
 *  or blocked there means a wall of plain text, and in both appearances, since the window follows the system's. */
const notesPage = (r) => `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>${escape(r.title)}</title>
<style>
${NOTES_STYLE}</style>
</head>
<body>
${releaseNotes(r)}
</body>
</html>
`;

/** Narrows changelog.html to ?from=<installed>&to=<offered>: the releases after the one installed, up to
 *  the one on offer, and betas only when either end is one. No params, or a version it doesn't know,
 *  leaves every release showing, which is also what a reader with JS off sees. */
const CHANGELOG_SCRIPT = `(() => {
  const q = new URLSearchParams(location.search);
  const sections = [...document.querySelectorAll("section[data-build]")];
  const find = (v) => sections.find((s) => s.id === "v" + v);
  const from = find(q.get("from")), to = find(q.get("to"));
  if (!from || !to) return;
  const lo = Number(from.dataset.build), hi = Number(to.dataset.build);
  const betas = from.dataset.channel === "beta" || to.dataset.channel === "beta";
  const shown = sections.filter((s) => {
    const b = Number(s.dataset.build);
    const keep = b > lo && b <= hi && (betas || s.dataset.channel !== "beta");
    s.hidden = !keep;
    return keep;
  });
  if (!shown.length) { sections.forEach((s) => (s.hidden = false)); return; }
  const title = document.querySelector("#range h1");
  const count = document.querySelector("#range .count");
  if (shown.length === 1) {
    title.innerHTML = shown[0].querySelector("h2").innerHTML;
    count.textContent = shown[0].querySelector(".date").textContent;
    shown[0].querySelector("header").hidden = true;
  } else {
    title.textContent = "Changes since " + q.get("from") + " \u00b7 " + shown.length + " releases";
    count.textContent = shown.at(-1).id.slice(1) + " to " + shown[0].id.slice(1) + ", newest first";
  }
  document.querySelector("#range .all").hidden = false;
  document.title = title.textContent.replace(/Beta$/, " (Beta)") + " \u00b7 ${NAME}";
})();`;

/** Every signed release's notes on one page, newest first, for someone skipping several releases:
 *  the app links here with ?from=<installed>&to=<offered>. Not signed (Sparkle's window shows the
 *  offered release's own notes.html), so it can change with every release. */
const changelogPage = (releases) => `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>${escape(NAME)} release notes</title>
<style>
${NOTES_STYLE}  body { max-width: 640px; margin: 0 auto; }
  #range { border-bottom: 0; margin-bottom: 8px; }
  #range .all { font-size: 12px; margin-top: 4px; }
  section { padding: 16px 0 8px; }
  section + section { border-top: 1px solid var(--rule); }
  section header { border-bottom: 0; padding-bottom: 0; margin-bottom: 0; }
  section header h2 { font-size: 15px; margin: 0; }
  [hidden] { display: none !important; }
</style>
</head>
<body>
<header id="range">
  <h1>${escape(NAME)} release notes</h1>
  <div class="date count">${releases.length} release${releases.length === 1 ? "" : "s"}, newest first</div>
  <div class="all" hidden><a href="?">Show all releases</a></div>
</header>
${releases.map((r) => `<section id="v${escape(r.version)}" data-build="${r.build}" data-channel="${r.channel}">
${releaseNotes(r, "h2")}
</section>`).join("\n")}
<script>
${CHANGELOG_SCRIPT}
</script>
</body>
</html>
`;

function appcast(releases) {
  const items = releases.filter((r) => r.artifacts).map((r) => {
    const { dmg, notes } = r.artifacts;
    return [
      "    <item>",
      `      <title>${escape(r.title)}</title>`,
      ...(r.beta ? ["      <sparkle:channel>beta</sparkle:channel>"] : []),
      `      <sparkle:version>${r.build}</sparkle:version>`,
      `      <sparkle:shortVersionString>${escape(r.version)}</sparkle:shortVersionString>`,
      `      <sparkle:minimumSystemVersion>${escape(r.minimumSystem)}</sparkle:minimumSystemVersion>`,
      `      <pubDate>${new Date(`${r.date}T12:00:00Z`).toUTCString().replace("GMT", "+0000")}</pubDate>`,
      // Signed, since the notes render in a web view: a tampered bucket can't put a page there.
      `      <sparkle:releaseNotesLink sparkle:edSignature="${escape(notes.edSignature)}" length="${notes.length}">${escape(r.notesURL)}</sparkle:releaseNotesLink>`,
      `      <enclosure url="${escape(r.dmgURL)}" length="${dmg.length}" type="application/octet-stream" sparkle:edSignature="${escape(dmg.edSignature)}"/>`,
      "    </item>",
    ].join("\n");
  });
  return `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>${NAME}</title>
    <link>${updatesURL()}/appcast.xml</link>
    <description>Updates for ${NAME}.</description>
    <language>en</language>
${items.join("\n")}
  </channel>
</rss>
`;
}

// MARK: stages

function cmdNew(v) {
  if (!v) fail("usage: release.mjs new <version> [--channel beta]");
  const dir = join(RELEASES, v);
  if (existsSync(join(dir, "notes.md"))) fail(`releases/${v}/notes.md already exists.`);
  const channel = option("--channel") ?? "stable";
  const build = Math.max(current().build, ...allReleases().map((r) => r.build)) + 1;
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "notes.md"), `---
version: ${v}
build: ${build}
channel: ${channel}
date: ${new Date().toISOString().slice(0, 10)}
minimumSystemVersion: ${MINIMUM_SYSTEM}
---

### Added

-

### Changed

-

### Fixed

-
`);
  bump(v, build);
  ok(`releases/${v}/notes.md (build ${build}, ${channel})`);
  console.log(`\nNext: write the notes, then \`node apps/mac/scripts/release.mjs ship ${v}\`.`);
}

function cmdBuild(v) {
  const r = release(v);
  heading(`Building ${r.version} (${r.build})`);
  loadEnv();
  const { version: cv, build: cb } = current();
  if (cv !== r.version || cb !== r.build) bump(r.version, r.build);
  timed("bundle", () => run(join(here, "scripts/bundle.sh"), ["release"], { env: { ...process.env, SIGN_IDENTITY: signIdentity(), UPDATES_URL: updatesURL() } }));
  timed("signature checks", () => verifySignatures());
  timed("dSYMs", () => uploadSymbols());
  tagBuilt(r.version);
}

function verifySignatures() {
  // An unsigned or ad hoc helper deep in the bundle otherwise shows up as a user's "app is damaged".
  run("codesign", ["--verify", "--deep", "--strict", APP]);
  // codesign -d reports on stderr.
  const signed = execFileSync("codesign", ["-dvv", APP], { encoding: "utf8", stdio: ["ignore", "ignore", "pipe"] }) ||
    execFileSync("sh", ["-c", 'codesign -dvv "$0" 2>&1', APP], { encoding: "utf8" });
  if (!signed.includes("Developer ID Application")) fail(`${APP} isn't signed with a Developer ID.`);
  for (const nested of ["Contents/Frameworks/Sparkle.framework", "Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app",
    "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc", "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc",
    "Contents/Helpers/maple-runner", "Contents/Helpers/tmux"]) {
    if (!existsSync(join(APP, nested))) fail(`The app has no ${nested}.`);
    run("codesign", ["--verify", "--strict", join(APP, nested)]);
  }
  ok(`signed ${APP}`);
}

/** Tags HEAD mac-v<v> on origin: what this release was built from, and the next one's base. */
function tagBuilt(v) {
  if (process.env.MAPLE_RELEASES_DIR || flag("--no-tag")) return console.log(`  (${process.env.MAPLE_RELEASES_DIR ? "A rehearsal" : "--no-tag"}: not tagging mac-v${v}.)`);
  const git = (...argv) => capture("git", argv);
  const tag = `mac-v${v}`;
  const head = git("rev-parse", "HEAD");
  const remote = git("ls-remote", "--tags", "origin", `refs/tags/${tag}^{}`).split(/\s/)[0];
  if (remote === head) return ok(`${tag} is already HEAD on origin`);
  if (remote) fail(`${tag} is on origin at ${remote.slice(0, 9)}, not HEAD: bump the version, or --no-tag to build without tagging.`);
  git("tag", "-a", "-f", tag, "-m", `Maple Factory ${v}`);
  git("push", "-q", "origin", tag);
  ok(`tagged ${tag} and pushed it`);
}

/** The app's debug symbols to Sentry, so its crash and hang reports read as source lines. A bundle that
 *  reports to Sentry (MapleSentryDSN in its Info.plist) doesn't go out without them: no SENTRY_AUTH_TOKEN
 *  stops the build, unless MAPLE_SKIP_SYMBOLS=1 says to go without. The dSYM is checked against the
 *  bundled binary (dwarfdump --uuid), so an upload that couldn't symbolicate this release fails too. */
function uploadSymbols() {
  const binary = join(APP, "Contents/MacOS/MapleFactory");
  let dsn = "";
  try { dsn = capture("plutil", ["-extract", "MapleSentryDSN", "raw", join(APP, "Contents/Info.plist")]); } catch { /* no key */ }
  if (!dsn) return console.log("  (The bundle has no Sentry DSN: no dSYMs to upload.)");
  if (process.env.MAPLE_SKIP_SYMBOLS === "1") return console.log("  (MAPLE_SKIP_SYMBOLS=1: not uploading dSYMs; this release's reports will show addresses.)");
  if (!process.env.SENTRY_AUTH_TOKEN) {
    fail("No SENTRY_AUTH_TOKEN: this release's dSYMs would not upload, and its crash and hang reports would show <unknown> frames.\n" +
      "  Add SENTRY_AUTH_TOKEN=<token> to apps/mac/.env.release (a Sentry auth token with project:releases and project:write),\n" +
      "  or set MAPLE_SKIP_SYMBOLS=1 to ship without symbols.");
  }
  // SwiftBuild writes a release build's dSYM next to the binary; it's this bundle's when the UUIDs match
  // (install_name_tool and codesign don't change them). Only a stale or missing one is made again.
  const bin = existsSync(join(here, "build/bin-path")) ? readFileSync(join(here, "build/bin-path"), "utf8").trim() : join(here, ".build/release");
  const built = join(bin, "MapleFactory.dSYM");
  if (existsSync(built) && uuids(built) === uuids(binary)) {
    ok(`SwiftBuild's dSYM is this binary's: ${built}`);
    return sendSymbols(built, binary);
  }
  const dsym = join(here, "build/MapleFactory.dSYM");
  rmSync(dsym, { recursive: true, force: true });
  run("dsymutil", [join(bin, "MapleFactory"), "-o", dsym]);
  sendSymbols(dsym, binary);
}

/** A Mach-O's or dSYM's UUIDs, one per architecture: "17F47C63-… (arm64)". */
const uuids = (path) => [...capture("dwarfdump", ["--uuid", path]).matchAll(/UUID: ([0-9A-F-]+) \((\w+)\)/g)].map(([, u, arch]) => `${u} (${arch})`).sort().join(", ");

/** dsym to Sentry once its UUID is the binary's and sentry-cli finds its debug info. */
function sendSymbols(dsym, binary) {
  const [want, have] = [uuids(binary), uuids(dsym)];
  console.log(`  binary ${want}\n  dSYM   ${have}`);
  if (!want || want !== have) fail(`The dSYM's UUID (${have || "none"}) isn't the binary's (${want || "none"}): it wouldn't symbolicate this release.`);
  ok(`dSYM UUID matches the binary: ${want}`);
  const sentry = JSON.parse(readFileSync(join(here, "../../server/web/sentry.json"), "utf8"));
  const cli = ["-y", "@sentry/cli@3.8.2"];
  const check = capture("npx", [...cli, "debug-files", "check", join(dsym, "Contents/Resources/DWARF/MapleFactory")]);
  console.log(check.replace(/^/gm, "  "));
  if (!/Usable: yes/.test(check) || !/\bdebug\b/.test(check)) fail("sentry-cli debug-files check says the dSYM isn't usable.");
  run("npx", [...cli, "debug-files", "upload", "--org", sentry.org, "--project", sentry.projects.mac.slug, "--wait", dsym]);
  ok("dSYMs uploaded to Sentry");
}

/** One release's dSYM, after the fact: from apps/mac/.build/release (or --built <path to its MapleFactory>,
 *  e.g. another checkout's .build/release) if that's still the shipped binary,
 *  else from its mac-v<v> tag (mac-built-<v> for releases before those) built in a scratch worktree. Its UUID must be the shipped app's, read
 *  from /Applications or --app <path to Maple Factory.app>. */
function cmdSymbols(v) {
  if (!v) fail("usage: release.mjs symbols <version> [--app <path to Maple Factory.app>] [--built <path to its release MapleFactory>]");
  heading(`Symbols for ${v}`);
  loadEnv();
  need("SENTRY_AUTH_TOKEN");
  const app = option("--app") ?? "/Applications/Maple Factory.app";
  const shipped = capture("plutil", ["-extract", "CFBundleShortVersionString", "raw", join(app, "Contents/Info.plist")]);
  if (shipped !== v) fail(`${app} is ${shipped}, not ${v}: pass --app with a ${v} bundle (from its DMG).`);
  const binary = join(app, "Contents/MacOS/MapleFactory");
  const dsym = join(here, `build/MapleFactory-${v}.dSYM`);
  rmSync(dsym, { recursive: true, force: true });
  let built = option("--built") ?? join(here, ".build/release/MapleFactory");
  if (!existsSync(built) || uuids(built) !== uuids(binary)) {
    // The same path the release was built from isn't ours to rebuild in place; a worktree of the tag
    // builds the same sources, and its UUID check below says whether it came out the same binary.
    // The worktree is always at the same path and builds into build/symbols-cache, which stays: the next
    // run reuses its dependencies (Sentry, Sparkle, SwiftTerm) and its build, rather than starting cold.
    const tree = join(tmpdir(), "maple-symbols");
    const scratch = join(here, "build/symbols-cache");
    if (existsSync(tree)) run("git", ["worktree", "remove", "--force", tree]);
    rmSync(tree, { recursive: true, force: true });
    let tag = `mac-v${v}`;
    try { capture("git", ["fetch", "-q", "origin", "tag", tag]); } catch { tag = `mac-built-${v}`; } // the older, local-only tags
    run("git", ["worktree", "add", "--detach", tree, tag]);
    try {
      timed("swift build (symbols)", () => run("swift", ["build", "-c", "release", "--scratch-path", scratch], { cwd: join(tree, "apps/mac") }));
      const bin = realpathSync(join(scratch, "release"));
      built = join(bin, "MapleFactory");
      if (existsSync(join(bin, "MapleFactory.dSYM")) && uuids(join(bin, "MapleFactory.dSYM")) === uuids(built)) cpSync(join(bin, "MapleFactory.dSYM"), dsym, { recursive: true });
      else run("dsymutil", [built, "-o", dsym]);
    } finally {
      run("git", ["worktree", "remove", "--force", tree]);
    }
  } else {
    run("dsymutil", [built, "-o", dsym]);
  }
  sendSymbols(dsym, binary);
}

/** Notarizes and staples a .app or .dmg. Both get their own round: the app's ticket is what opens it
 *  offline once it's in Applications; the DMG's is what Gatekeeper checks of the download. */
function notarize(path) {
  const credentials = notaryArgs();
  let submission = path;
  if (path.endsWith(".app")) {
    submission = `${path}.zip`;
    rmSync(submission, { force: true });
    run("ditto", ["-c", "-k", "--keepParent", path, submission]); // ditto keeps the bundle's symlinks
  }
  run("xcrun", ["notarytool", "submit", submission, ...credentials, "--wait"]);
  run("xcrun", ["stapler", "staple", path]);
  run("xcrun", ["stapler", "validate", path]);
  if (submission !== path) rmSync(submission, { force: true });
}

function cmdNotarize(v) {
  const r = release(v);
  heading(`Notarizing ${r.version}`);
  loadEnv();
  if (!existsSync(APP)) fail(`No ${APP}: run \`build ${v}\` first.`);
  notarize(APP);
  ok("app notarized and stapled");
}

function cmdDmg(v) {
  const r = release(v);
  heading(`Packaging ${r.dmgName}`);
  loadEnv();
  mkdirSync(r.siteDir, { recursive: true });
  const dmg = join(r.siteDir, r.dmgName);
  rmSync(dmg, { force: true });
  const stage = join(here, "build/dmg-staging");
  rmSync(stage, { recursive: true, force: true });
  mkdirSync(stage, { recursive: true });
  run("ditto", [APP, join(stage, `${NAME}.app`)]);
  run("create-dmg", ["--volname", `${NAME} ${r.version}`, "--window-pos", "200", "120", "--window-size", "660", "400",
    "--icon-size", "128", "--icon", `${NAME}.app`, "165", "185", "--hide-extension", `${NAME}.app`,
    "--app-drop-link", "495", "185", "--no-internet-enable", dmg, stage]);
  rmSync(stage, { recursive: true, force: true });
  // The image too, not only the app in it: otherwise Gatekeeper says the download has no usable signature.
  run("codesign", ["--sign", signIdentity(), "--timestamp", dmg]);
  notarize(dmg);
  ok(`${r.dmgName} notarized and stapled`);
}

function edSignature(file) {
  const keyFile = process.env.SPARKLE_KEY_FILE;
  // sign_update takes an .html or .xml for a feed and writes the signature into it, changing the bytes
  // it signed; a copy by another name is signed as it is.
  const copy = join(tmpdir(), `maple-sign-${process.pid}.bin`);
  copyFileSync(file, copy);
  try {
    const out = capture(sparkleBin("sign_update"), [...(keyFile ? ["--ed-key-file", keyFile] : []), "-p", copy]);
    return out || fail(`sign_update gave no signature for ${file}.`);
  } finally {
    rmSync(copy, { force: true });
  }
}

function cmdSign(v) {
  const r = release(v);
  heading(`Signing ${r.version} for Sparkle`);
  if (existsSync(join(here, ".env.release"))) loadEnv();
  const dmg = join(r.siteDir, r.dmgName);
  if (!existsSync(dmg)) fail(`No ${dmg}: run \`dmg ${v}\` first.`);
  // The notes first: the signature covers the exact bytes Sparkle will fetch.
  mkdirSync(r.siteDir, { recursive: true });
  const notes = join(r.siteDir, "notes.html");
  writeFileSync(notes, notesPage(r));
  const artifacts = {
    dmg: { name: r.dmgName, length: statSync(dmg).size, edSignature: edSignature(dmg) },
    notes: { length: statSync(notes).size, edSignature: edSignature(notes) },
    signedAt: new Date().toISOString(),
  };
  writeFileSync(join(r.dir, "release.json"), JSON.stringify(artifacts, null, 2) + "\n");
  ok(`releases/${v}/release.json (${artifacts.dmg.length} bytes)`);
}

function cmdAppcast() {
  heading("Making the appcast");
  if (existsSync(join(here, ".env.release"))) loadEnv();
  const releases = allReleases();
  const unsigned = releases.filter((r) => !r.artifacts);
  // Not fatal: a release that's written but not built isn't in the feed yet. Saying so tells that apart from one dropped.
  if (unsigned.length) console.log(`  not signed yet, so not in it: ${unsigned.map((r) => r.version).join(", ")}`);
  mkdirSync(SITE, { recursive: true });
  writeFileSync(join(SITE, "appcast.xml"), appcast(releases));
  writeFileSync(join(SITE, "changelog.html"), changelogPage(releases.filter((r) => r.artifacts)));
  // Every signed release's notes, the same bytes they were signed as (the template changing would break their signatures).
  for (const r of releases.filter((r) => r.artifacts)) {
    const notes = join(r.siteDir, "notes.html");
    if (!existsSync(notes)) continue; // published before; R2 has it
    if (statSync(notes).size !== r.artifacts.notes.length) fail(`${notes} isn't the one release.json signed; run \`sign ${r.version}\` again.`);
  }
  const signed = releases.filter((r) => r.artifacts);
  ok(`appcast.xml: ${signed.length} item${signed.length === 1 ? "" : "s"} (${signed.filter((r) => r.beta).length} beta)`);
  ok(`changelog.html: ${signed.length} release${signed.length === 1 ? "" : "s"}`);
}

function cmdPublish() {
  heading(`Publishing to ${updatesURL()}`);
  loadEnv();
  const [account, bucket] = need("R2_ACCOUNT_ID", "R2_BUCKET", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY");
  const endpoint = ["--endpoint-url", `https://${account}.r2.cloudflarestorage.com`];
  if (!existsSync(join(SITE, "appcast.xml"))) fail("No appcast yet: run `appcast` first.");
  // The releases' files, which are named by version and never change; then the appcast, last and on
  // its own, so it never names a DMG that isn't there yet.
  for (const [pattern, type] of [["*.dmg", "application/x-apple-diskimage"], ["*.html", "text/html; charset=utf-8"]]) {
    if (!existsSync(join(SITE, "releases"))) break;
    run("aws", ["s3", "sync", join(SITE, "releases"), `s3://${bucket}/releases/`, ...endpoint, "--exclude", "*", "--include", pattern,
      "--content-type", type, "--cache-control", "public, max-age=31536000, immutable"]);
  }
  // Briefly cached, so pulling a bad release or shipping a fix reaches everyone in minutes. The
  // changelog before the appcast, so an app offered the new release finds its notes there.
  if (existsSync(join(SITE, "changelog.html"))) {
    run("aws", ["s3", "cp", join(SITE, "changelog.html"), `s3://${bucket}/changelog.html`, ...endpoint,
      "--content-type", "text/html; charset=utf-8", "--cache-control", "public, max-age=300"]);
  }
  run("aws", ["s3", "cp", join(SITE, "appcast.xml"), `s3://${bucket}/appcast.xml`, ...endpoint,
    "--content-type", "application/xml; charset=utf-8", "--cache-control", "public, max-age=300"]);

  const latest = allReleases().find((r) => r.artifacts);
  if (!latest) return;
  const feed = capture("curl", ["-fsS", `${updatesURL()}/appcast.xml`]);
  if (!feed.includes(`<sparkle:shortVersionString>${latest.version}<`)) fail(`${updatesURL()}/appcast.xml doesn't have ${latest.version} in it.`);
  capture("curl", ["-fsSI", latest.dmgURL]);
  const changelog = capture("curl", ["-fsS", `${updatesURL()}/changelog.html`]);
  if (!changelog.includes(`id="v${latest.version}"`)) fail(`${updatesURL()}/changelog.html doesn't have ${latest.version} in it.`);
  ok(`${latest.version} is live at ${updatesURL()}/appcast.xml`);
}

async function cmdShip(v) {
  const r = release(v);
  const yes = flag("--yes");
  if (!yes && !process.stdin.isTTY) fail("ship asks twice before it goes on, and stdin isn't a terminal: pass --yes to ship unattended.");
  const ask = async (question) => {
    if (yes) return console.log(`${question} yes (--yes)`), true;
    const rl = createInterface({ input: process.stdin, output: process.stdout });
    const answer = await rl.question(`${question} [y/N] `);
    rl.close();
    return /^y/i.test(answer.trim());
  };
  console.log(`\nShipping ${NAME} ${r.version} (${r.build}) on the ${r.channel} channel\n`);
  console.log(r.markdown.trim().split("\n").slice(0, 12).join("\n"));
  if (!(await ask("\nGo ahead?"))) return console.log("Cancelled.");
  // A missing credential fails now, not after ten minutes of notarizing.
  loadEnv();
  notaryArgs();
  need("R2_ACCOUNT_ID", "R2_BUCKET", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY");
  if (process.env.MAPLE_SKIP_SYMBOLS !== "1") need("SENTRY_AUTH_TOKEN");
  sparkleBin("sign_update");
  cmdBuild(v);
  timed("notarize app", () => cmdNotarize(v));
  timed("dmg (notarized)", () => cmdDmg(v));
  timed("sparkle signatures", () => cmdSign(v));
  timed("appcast", () => cmdAppcast());
  timings();
  if (!(await ask(`Publish to ${updatesURL()}?`))) return console.log("Stopped before publishing; `publish` when ready.");
  if (process.env.MAPLE_STOP_BEFORE_PUBLISH === "1") return console.log("MAPLE_STOP_BEFORE_PUBLISH=1: stopped before publishing.");
  timed("publish", () => cmdPublish());
  timings();
  console.log(`\n  ✓ ${r.version} shipped. Commit apps/mac/releases/${r.version}/ and apps/mac/version.json.`);
}

const COMMANDS = { new: cmdNew, build: cmdBuild, notarize: cmdNotarize, dmg: cmdDmg, sign: cmdSign, appcast: cmdAppcast, publish: cmdPublish, ship: cmdShip, symbols: cmdSymbols };
if (!COMMANDS[command]) {
  console.log(`usage: release.mjs <command> [version]

  new <version>       releases/<version>/notes.md (--channel beta for a prerelease), and bumps version.json
  build <version>     bundle.sh with the Developer ID, checks every nested signature, uploads its dSYM to Sentry,
                      and tags mac-v<version> on origin (not in a rehearsal, or with --no-tag)
  notarize <version>  notarizes and staples the app
  dmg <version>       the DMG from the stapled app, signed, notarized and stapled
  sign <version>      notes.html, and the EdDSA signatures in release.json
  appcast             build/updates-site/appcast.xml and changelog.html from every releases/*/release.json
  publish             uploads build/updates-site/ to R2 (the appcast last), and checks it's live
  ship <version>      all of these, asking before it starts and before it publishes (--yes doesn't ask)
  symbols <version>   uploads an already-shipped release's dSYM (--app <path> if /Applications isn't that version,
                      --built <path> for a checkout's .build/release/MapleFactory that built it)

Credentials come from the environment, then apps/mac/.env.release; env-only ones (for CI, RELEASING.md):
  NOTARY_KEY_ID, NOTARY_ISSUER_ID, NOTARY_KEY   an App Store Connect API key, when there's no NOTARY_PROFILE
  SPARKLE_PRIVATE_KEY                          the Sparkle EdDSA key's text, in place of SPARKLE_KEY_FILE
  MAPLE_STOP_BEFORE_PUBLISH=1                  ship stops before publishing (a rehearsal)`);
  process.exit(command ? 1 : 0);
}
try {
  await COMMANDS[command](version);
} catch (e) {
  console.error(`✗ ${e.message}`);
  process.exit(1);
}

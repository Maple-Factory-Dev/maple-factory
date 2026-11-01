#!/usr/bin/env node
// Fills apps/mac/releases/<v>/notes.md (as `release.mjs new <v>` left it) for a release from CI:
//
//   node scripts/ci/mac-release-notes.mjs <version> [--notes-file <file>] [--since <ref>]
//
// With --notes-file, its text is the notes' body. Without it, the body is Added / Changed / Fixed bullets
// from the commit subjects since the last mac-v tag (--since overrides that): release commits ("Mac app …
// released", "Runner …", "maple-server …") and merges are left out, a leading "MF-123: " and a trailing
// "(#12)" are taken off, and each subject goes under Added (Add…, New…), Fixed (Fix…) or else Changed.
// The frontmatter stays as it is. It fails when nothing is left to say. MAPLE_RELEASES_DIR moves the
// releases folder, as it does for release.mjs. Kept out of release.mjs so the hand release is unchanged.

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repo = join(dirname(fileURLToPath(import.meta.url)), "../..");
const RELEASES = process.env.MAPLE_RELEASES_DIR ?? join(repo, "apps/mac/releases");
const option = (name) => { const i = process.argv.indexOf(name); return i > 0 ? process.argv[i + 1] : undefined; };
const git = (...argv) => execFileSync("git", argv, { cwd: repo, encoding: "utf8" }).trim();
const die = (text) => { console.error(`✗ ${text}`); process.exit(1); };

const version = process.argv[2];
if (!version || version.startsWith("-")) die("usage: mac-release-notes.mjs <version> [--notes-file <file>] [--since <ref>]");
const file = join(RELEASES, version, "notes.md");
if (!existsSync(file)) die(`No ${file}: run \`release.mjs new ${version}\` first.`);
const raw = readFileSync(file, "utf8");
const [, front] = raw.match(/^(---[ \t]*\n[\s\S]*?\n---[ \t]*\n)/) ?? die(`${file} has no frontmatter.`);

/** The newest mac-v tag that's an ancestor of HEAD, other than this version's own. */
function lastTag() {
  const tags = git("tag", "--list", "mac-v*", "--merged", "HEAD", "--sort=-v:refname").split("\n").filter(Boolean);
  return tags.find((t) => t !== `mac-v${version}`) ?? die("No mac-v tag behind HEAD: pass --since <ref>.");
}

const SKIP = [/^Mac app \S+ released\b/, /^Runner \d/, /^maple-server \d/, /^Merge (pull request|branch|remote-tracking)\b/];
const ADDED = /^(add|adds|added|new|introduce|introduces|support|supports|show|shows|let|lets|allow|allows|create|creates)\b/i;
const FIXED = /^(fix|fixes|fixed|correct|corrects|repair|repairs|stop|stops)\b|\b(wrongly|broken|crash(es|ed)?|no longer|properly|doesn't|don't|isn't|aren't|bug)\b/i;

/** Subjects, cleaned and sorted into the three sections. A short "Area: " in front ("Mac: fix …") is kept
 *  in the bullet but left out when deciding the section. */
function sections(subjects) {
  const out = { Added: [], Changed: [], Fixed: [] };
  for (const raw of subjects) {
    const s = raw.trim();
    if (!s || SKIP.some((re) => re.test(s))) continue;
    let text = s.replace(/^[A-Z]+-\d+:\s*/, "").replace(/\s*\(#\d+\)\s*$/, "").trim();
    if (!text) continue;
    // Only a plain lowercase first word: "iPhone", "maple-server" and "release-mac.yml" stay as written.
    if (/^[a-z]+\b(?![-.])/.test(text)) text = text[0].toUpperCase() + text.slice(1);
    if (!/[.!?]$/.test(text)) text += ".";
    const what = text.replace(/^[^:]{1,40}:\s+/, "");
    const section = ADDED.test(what) ? "Added" : FIXED.test(what) ? "Fixed" : "Changed";
    if (!out[section].includes(text)) out[section].push(text);
  }
  return out;
}

let body;
const notesFile = option("--notes-file");
if (notesFile) {
  body = readFileSync(notesFile, "utf8").trim();
  if (!body) die(`${notesFile} is empty.`);
  console.log(`Notes from ${notesFile}.`);
} else {
  const since = option("--since") ?? lastTag();
  const subjects = git("log", `${since}..HEAD`, "--no-merges", "--format=%s").split("\n");
  const found = sections(subjects);
  const parts = Object.entries(found).filter(([, items]) => items.length)
    .map(([name, items]) => `### ${name}\n\n${items.map((i) => `- ${i}`).join("\n")}`);
  if (!parts.length) die(`No commits since ${since} to write notes from (only release commits): pass notes.`);
  body = parts.join("\n\n");
  console.log(`Notes from ${subjects.filter(Boolean).length} commit subjects since ${since}.`);
}
writeFileSync(file, `${front}\n${body}\n`);
console.log(`Wrote ${file}.`);

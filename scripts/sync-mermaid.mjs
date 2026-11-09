#!/usr/bin/env node
// Copies the shared Mermaid viewer (assets/mermaid/diagram.html and the pinned mermaid.min.js) into
// each app that renders plan diagrams (MF-358). `--check` changes nothing and fails if a copy drifted.
import { copyFileSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const SOURCE = join(root, "assets/mermaid");
const FILES = ["diagram.html", "mermaid.min.js"];
const TARGETS = [
  "server/web/app/mermaid", // web: /app/mermaid/diagram.html
  "apps/mac/Sources/MapleFactory/Resources/mermaid",
  "apps/ios/Resources/mermaid",
  "apps/android/app/src/main/assets/mermaid",
];

const sha = (p) => createHash("sha256").update(readFileSync(p)).digest("hex");
const check = process.argv.includes("--check");
let drift = 0;
for (const file of FILES) {
  const want = sha(join(SOURCE, file));
  console.log(`${file}  ${want.slice(0, 16)}  assets/mermaid (source)`);
  for (const dir of TARGETS) {
    const to = join(root, dir, file);
    const ok = existsSync(to) && sha(to) === want;
    if (check) {
      console.log(`${file}  ${existsSync(to) ? sha(to).slice(0, 16) : "missing         "}  ${relative(root, to)}  ${ok ? "ok" : "DRIFTED"}`);
      if (!ok) drift++;
    } else if (!ok) {
      mkdirSync(dirname(to), { recursive: true });
      copyFileSync(join(SOURCE, file), to);
      console.log(`  copied → ${relative(root, to)}`);
    }
  }
}
if (check) {
  if (drift) { console.error(`\n${drift} copy(ies) differ from assets/mermaid; run: node scripts/sync-mermaid.mjs`); process.exit(1); }
  console.log(`\nall ${TARGETS.length} copies of ${FILES.join(" and ")} match assets/mermaid`);
}

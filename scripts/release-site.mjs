#!/usr/bin/env node
// Deploys maplefactory.dev (apps/site) and records what's live as tags on origin, the next release's base:
//
//   node scripts/release-site.mjs              # wrangler deploy, check / and /download/mac, tag site-v<sha> + site-deployed
//   node scripts/release-site.mjs --dry-run    # wrangler's dry run; no deploy, no tags
//
// wrangler runs headless with CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID set (RELEASING.md), else
// with your `wrangler login`. site-v<sha> marks every deploy; site-deployed moves to the newest (the only
// tag pushed with --force).

import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { flag, root, wrangler } from "./feed.mjs";

const SITE_URL = "https://maplefactory.dev";
const site = join(root, "apps/site");
const git = (...argv) => execFileSync("git", argv, { cwd: root, encoding: "utf8" }).trim();

try {
  if (flag("--dry-run")) {
    const out = mkdtempSync(join(tmpdir(), "maple-site-"));
    try {
      wrangler(["deploy", "--dry-run", "--outdir", out], { cwd: site, stdio: "inherit" });
    } finally {
      rmSync(out, { recursive: true, force: true });
    }
    console.log("\n✓ Dry run: the site builds; nothing deployed or tagged.");
    process.exit(0);
  }

  if (git("status", "--porcelain", "--", "apps/site")) throw new Error("apps/site has uncommitted changes; the deploy is tagged from what's committed.");
  wrangler(["deploy"], { cwd: site, stdio: "inherit" });

  const home = await fetch(`${SITE_URL}/?x=${Date.now()}`);
  if (home.status !== 200) throw new Error(`${SITE_URL}/ answered ${home.status} after the deploy.`);
  const mac = await fetch(`${SITE_URL}/download/mac`, { redirect: "manual" });
  if (mac.status !== 302) throw new Error(`${SITE_URL}/download/mac answered ${mac.status}, not a redirect to the newest DMG.`);
  console.log(`✓ ${SITE_URL}/ is 200, /download/mac redirects to ${mac.headers.get("location")}`);

  const tag = `site-v${git("rev-parse", "--short", "HEAD")}`;
  git("tag", "-f", tag, "HEAD");
  git("tag", "-f", "site-deployed", "HEAD");
  git("push", "-q", "origin", `refs/tags/${tag}`);
  git("push", "-q", "--force", "origin", "refs/tags/site-deployed");
  console.log(`✓ Tagged ${tag} and moved site-deployed; both pushed.`);
} catch (e) {
  console.error(`✗ ${e.message}`);
  process.exit(1);
}

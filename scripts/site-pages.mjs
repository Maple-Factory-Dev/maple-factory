import { execFileSync } from "node:child_process";

// Which maplefactory.dev pages a deploy changed, so release-site.mjs checks them after it deploys.
// The site's files are served as static assets with Cloudflare's default html_handling, so
// index.html is /, download.html is /download, docs/x.html is /docs/x and docs/index.html is /docs/.

/** The URL path for a file under apps/site, or null when it isn't a page (.html). */
export function pagePath(file) {
  const rel = file.replace(/^apps\/site\//, "");
  if (!rel.endsWith(".html")) return null;
  const stem = rel.slice(0, -".html".length);
  if (stem === "index") return "/";
  if (stem.endsWith("/index")) return `/${stem.slice(0, -"index".length)}`;
  return `/${stem}`;
}

/**
 * The URL paths of the pages among `files` (git diff --name-only output, repo-relative), sorted and
 * without repeats. `files` is null when there's no site-deployed tag to diff against: no extra pages.
 */
export function changedPages(files) {
  if (!files) return [];
  const paths = files.map((f) => f.trim()).filter((f) => f.startsWith("apps/site/")).map(pagePath).filter(Boolean);
  return [...new Set(paths)].sort();
}

/**
 * The apps/site files changed between `base` and HEAD in the repo at `cwd`, for changedPages.
 * Deleted files are left out (--diff-filter=d), and a rename counts as its new path only: a page that's
 * gone answers 404 after the deploy, and checking it would fail every deploy until site-deployed moved.
 */
export function changedSiteFiles(base, cwd) {
  return execFileSync("git", ["diff", "--name-only", "--diff-filter=d", `${base}..HEAD`, "--", "apps/site"], { cwd, encoding: "utf8" })
    .trim()
    .split("\n");
}

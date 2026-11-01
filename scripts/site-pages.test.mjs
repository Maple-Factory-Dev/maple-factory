import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { changedPages, changedSiteFiles, pagePath } from "./site-pages.mjs";

test("pages map to their URLs", () => {
  assert.equal(pagePath("apps/site/index.html"), "/");
  assert.equal(pagePath("apps/site/download.html"), "/download");
  assert.equal(pagePath("apps/site/docs/x.html"), "/docs/x");
  assert.equal(pagePath("apps/site/docs/index.html"), "/docs/");
});

test("non-html files are ignored", () => {
  assert.equal(pagePath("apps/site/styles.css"), null);
  assert.equal(pagePath("apps/site/worker.js"), null);
  assert.deepEqual(changedPages(["apps/site/main.js", "apps/site/img/logo.png", "apps/site/_headers"]), []);
});

test("a diff becomes sorted, distinct URLs, only from apps/site", () => {
  const files = ["apps/site/download.html", "apps/site/styles.css", "apps/site/index.html", "apps/site/docs/slack.html", "scripts/slack.html", ""];
  assert.deepEqual(changedPages(files), ["/", "/docs/slack", "/download"]);
});

test("no site-deployed tag means no extra pages", () => {
  assert.deepEqual(changedPages(null), []);
});

test("deleted and renamed-away pages aren't checked; added, edited and renamed-to pages are", () => {
  const dir = mkdtempSync(join(tmpdir(), "site-pages-"));
  const git = (...argv) => execFileSync("git", ["-c", "user.name=t", "-c", "user.email=t@t", ...argv], { cwd: dir });
  const put = (f, body) => { mkdirSync(join(dir, f, ".."), { recursive: true }); writeFileSync(join(dir, f), body); };
  try {
    git("init", "-q");
    for (const f of ["index.html", "gone.html", "old.html", "kept.html"]) put(`apps/site/${f}`, `<p>${f} ${"x".repeat(200)}</p>`);
    git("add", "-A");
    git("commit", "-qm", "base");
    git("tag", "site-deployed");
    git("rm", "-q", "apps/site/gone.html");
    git("mv", "apps/site/old.html", "apps/site/new.html");
    put("apps/site/index.html", "<p>changed</p>");
    put("apps/site/docs/added.html", "<p>added</p>");
    git("add", "-A");
    git("commit", "-qm", "change");
    assert.deepEqual(changedPages(changedSiteFiles("site-deployed", dir)), ["/", "/docs/added", "/new"]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

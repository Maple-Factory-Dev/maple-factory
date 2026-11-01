import { test } from "node:test";
import assert from "node:assert/strict";
import { changedPages, pagePath } from "./site-pages.mjs";

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

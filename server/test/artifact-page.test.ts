// The web companion's artifactPage (server/web/app/app.js): the CSP meta is the first thing in an HTML
// artifact's srcdoc (after a leading doctype), so the parser puts it in the implicit <head> ahead of every tag.
// A <header>-only page, a script or image before <head>, or a <head> in a comment must not push it into <body>,
// where browsers ignore it.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const source = readFileSync(new URL("../web/app/app.js", import.meta.url), "utf8");
const csp = /const ARTIFACT_CSP = (".*?");/.exec(source)![1]!;
const fn = /function artifactPage\(text, kind\) \{[\s\S]*?\n\}/.exec(source)![0];
const artifactPage = new Function(`const ARTIFACT_CSP = ${csp}; ${fn}; return artifactPage;`)() as (text: string, kind: string) => string;
const meta = `<meta http-equiv="Content-Security-Policy" content="${JSON.parse(csp)}">`;

test("a page with only a <header> gets the meta first", () => {
  const html = "<html><body><header>Hi</header><script>fetch('https://x')</script></body></html>";
  assert.equal(artifactPage(html, "html"), meta + html);
});

test("a script and an image before <head> come after the meta", () => {
  const html = "<script>fetch('https://x')</script><img src=https://x/a.png><html><head><title>t</title></head></html>";
  assert.equal(artifactPage(html, "html"), meta + html);
});

test("a <head> inside a comment or a script string doesn't move it", () => {
  for (const html of ["<!-- <head> --><p>x</p>", "<script>const s = '<head>'; fetch('https://x')</script><head></head>"]) {
    assert.equal(artifactPage(html, "html"), meta + html);
  }
});

test("a leading doctype stays first", () => {
  const html = "﻿ <!DOCTYPE html>\n<html><head></head><body></body></html>";
  assert.equal(artifactPage(html, "html"), "﻿ <!DOCTYPE html>" + meta + "\n<html><head></head><body></body></html>");
});

test("an SVG is wrapped with the meta in a real <head>", () => {
  assert.ok(artifactPage("<svg></svg>", "svg").startsWith(`<!doctype html><html><head>${meta}`));
});

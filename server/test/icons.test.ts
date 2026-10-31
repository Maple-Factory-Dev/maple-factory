// The web app's Lucide icons (web/app/icons.js): every icon the pages ask for is vendored, and icon()
// builds an SVG drawn in currentColor that's decorative unless it's given a label.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

/** Just enough of the DOM for icon(): elements that keep their tag, attributes and children. */
class El {
  attrs = new Map<string, string>();
  children: El[] = [];
  constructor(public ns: string, public tag: string) {}
  setAttribute(k: string, v: string) { this.attrs.set(k, String(v)); }
  getAttribute(k: string) { return this.attrs.get(k) ?? null; }
  hasAttribute(k: string) { return this.attrs.has(k); }
  append(...c: El[]) { this.children.push(...c); }
}
(globalThis as any).document = { createElementNS: (ns: string, tag: string) => new El(ns, tag) };
const { LUCIDE, icon } = await import("../web/app/icons.js");

const WEB = new URL("../web/app/", import.meta.url);
const source = (file: string) => readFileSync(new URL(file, WEB), "utf8");

// Every icon name the app uses, from icon("…") calls and data-icon="…" slots. A literal grep keeps the
// list honest: a new call site with a name that isn't vendored fails here before it throws in a browser.
const used = new Set<string>();
for (const file of ["app.js", "machines.js", "settings.js", "index.html"]) {
  const text = source(file);
  for (const [, n] of text.matchAll(/\bicon\("([a-z0-9-]+)"/g)) used.add(n);
  for (const [, n] of text.matchAll(/data-icon="([a-z0-9-]+)"/g)) used.add(n);
  // icon(cond ? "a" : b ? "c" : "d"): the names in a conditional.
  for (const [, expr] of text.matchAll(/\bicon\(([^()]*\?[^()]*)\)/g)) for (const [, n] of expr.matchAll(/"([a-z0-9-]+)"/g)) used.add(n);
}

test("every icon the app uses is in LUCIDE", () => {
  assert.ok(used.size >= 15, `found only ${used.size} icon names: ${[...used].join(", ")}`);
  for (const name of ["inbox", "list-checks", "server", "notebook-pen", "settings", "plus", "check", "git-merge", "chevron-down", "circle-alert", "external-link", "refresh-cw", "terminal", "clock"]) assert.ok(used.has(name), `${name} isn't used any more; drop it from this list`);
  const missing = [...used].filter((n) => !(n in LUCIDE));
  assert.deepEqual(missing, []);
});

test("every vendored icon is one or more SVG shapes with attributes", () => {
  for (const [name, shapes] of Object.entries(LUCIDE) as [string, [string, Record<string, string>][]][]) {
    assert.ok(shapes.length > 0, name);
    for (const [tag, attrs] of shapes) {
      assert.match(tag, /^(path|circle|rect|line|polyline|polygon|ellipse)$/, `${name}: ${tag}`);
      assert.ok(Object.keys(attrs).length > 0, `${name}: ${tag} has no attributes`);
    }
  }
});

test("icon() draws a 24-unit SVG in currentColor, hidden from screen readers", () => {
  const svg = icon("inbox");
  assert.equal(svg.tag, "svg");
  assert.equal(svg.ns, "http://www.w3.org/2000/svg");
  assert.equal(svg.getAttribute("viewBox"), "0 0 24 24");
  assert.equal(svg.getAttribute("stroke"), "currentColor");
  assert.equal(svg.getAttribute("stroke-width"), "2");
  assert.equal(svg.getAttribute("fill"), "none");
  assert.equal(svg.getAttribute("width"), "16");
  assert.equal(svg.getAttribute("aria-hidden"), "true");
  assert.equal(svg.hasAttribute("role"), false);
  assert.equal(svg.getAttribute("class"), "icon icon-inbox");
  assert.deepEqual(svg.children.map((c: El) => c.tag), ["polyline", "path"]);
  assert.equal(svg.children[1].ns, "http://www.w3.org/2000/svg");
});

test("a size and class are applied; a label makes it a named image", () => {
  const svg = icon("server", { size: 20, label: "Machines", class: "big" });
  assert.equal(svg.getAttribute("width"), "20");
  assert.equal(svg.getAttribute("height"), "20");
  assert.equal(svg.getAttribute("class"), "icon icon-server big");
  assert.equal(svg.getAttribute("role"), "img");
  assert.equal(svg.getAttribute("aria-label"), "Machines");
  assert.equal(svg.hasAttribute("aria-hidden"), false);
});

test("an unknown name throws", () => {
  assert.throws(() => icon("no-such-icon"), /No Lucide icon "no-such-icon"/);
});

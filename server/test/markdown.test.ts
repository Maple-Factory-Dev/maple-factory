// The web dashboard's Markdown: parse() and highlight() are pure, so they're tested without a DOM.
// render() is checked against a tiny h() that records what it was asked to build.
import { test } from "node:test";
import assert from "node:assert/strict";
import { parse, inline, highlight, render } from "../web/app/markdown.js";

test("a fenced ts block keeps its language and highlights its tokens", () => {
  const [block] = parse("```ts\nconst n = 42 // the answer\nreturn \"hi\"\n```");
  assert.equal(block.type, "code");
  assert.equal(block.lang, "ts");
  assert.equal(block.text, "const n = 42 // the answer\nreturn \"hi\"");

  const tokens = highlight(block.text, block.lang);
  const of = (token) => tokens.filter((t) => t.token === token).map((t) => t.text.trim());
  assert.deepEqual(of("keyword"), ["const", "return"]);
  assert.deepEqual(of("number"), ["42"]);
  assert.deepEqual(of("comment"), ["// the answer"]);
  assert.deepEqual(of("string"), ['"hi"']);
  assert.equal(tokens.map((t) => t.text).join(""), block.text);
});

test("an unknown language stays one plain token; an indented fence drops its indent", () => {
  assert.deepEqual(highlight("x = 1", "cobol"), [{ text: "x = 1", token: "plain" }]);
  const [block] = parse("  ```swift\n  let a = 1\n  ```");
  assert.equal(block.lang, "swift");
  assert.equal(block.text, "let a = 1");
});

test("headings, lists and task lists", () => {
  const blocks = parse("## Plan\n- one\n- two\n\n1. first\n2. second\n- [x] done\n- [ ] not yet");
  assert.deepEqual(blocks.map((b) => b.type), ["heading", "list", "list", "list"]);
  assert.equal(blocks[0].level, 2);
  assert.equal(blocks[1].items.length, 2);
  assert.equal(blocks[2].ordered, true);
  assert.deepEqual(blocks[3].items.map((i) => i.checked), [true, false]);
});

test("nested inline formatting", () => {
  assert.deepEqual(inline("**bold _and italic_** with `code`"), [
    { type: "strong", children: [{ type: "text", text: "bold " }, { type: "em", children: [{ type: "text", text: "and italic" }] }] },
    { type: "text", text: " with " },
    { type: "code", text: "code" },
  ]);
  // snake_case words aren't italics.
  assert.deepEqual(inline("a snake_case_name"), [{ type: "text", text: "a snake_case_name" }]);
});

test("links open only for http(s) and mailto", () => {
  assert.deepEqual(inline("[docs](https://example.com)"), [
    { type: "link", href: "https://example.com", children: [{ type: "text", text: "docs" }] },
  ]);
  const nodes = inline("[click](javascript:alert(1))");
  assert.ok(!JSON.stringify(nodes).includes('"link"'));
  assert.ok(!JSON.stringify(nodes).includes("javascript:alert"));
  assert.ok(!JSON.stringify(inline("[x](JavaScript:void(0)) [y](data:text/html,hi)")).includes('"link"'));
});

// A stand-in for the app's h(): elements as plain objects, strings kept as text.
const h = (tag, attrs = {}, ...children) => ({ tag, attrs, children: children.flat(Infinity).filter((c) => c != null && c !== false) });
const tags = (node, out = []) => {
  if (typeof node === "object") { out.push(node.tag); node.children.forEach((c) => tags(c, out)); }
  return out;
};
const texts = (node, out = []) => {
  if (typeof node === "string") out.push(node);
  else node.children.forEach((c) => texts(c, out));
  return out;
};

test("<script> stays literal text", () => {
  const source = "<script>alert('x')</script>\n\n```html\n<script>alert(1)</script>\n```\n\n`<img onerror=x>`";
  const tree = render(parse(source), h);
  assert.ok(!tags(tree).includes("script"));
  assert.ok(!tags(tree).includes("img"));
  const all = texts(tree).join("");
  assert.ok(all.includes("<script>alert('x')</script>"));
  assert.ok(all.includes("<script>alert(1)</script>"));
  assert.ok(all.includes("<img onerror=x>"));
});

test("a javascript: link renders without an anchor", () => {
  const tree = render(parse("see [here](javascript:alert(1)) and [there](https://maplefactory.dev)"), h);
  const anchors = [];
  const walk = (n) => { if (typeof n === "object") { if (n.tag === "a") anchors.push(n.attrs.href); n.children.forEach(walk); } };
  walk(tree);
  assert.deepEqual(anchors, ["https://maplefactory.dev"]);
});

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
  const nodes = inline("[click](javascript:alert(1)) after");
  assert.deepEqual(nodes, [{ type: "text", text: "click after" }]);
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

const ID = "0b7c2a7e-1f2d-4c3b-9a8e-5d6f7a8b9c0d";

test("a line that's just an image is an image block; just an attachment link is a file block", () => {
  assert.deepEqual(parse(`Before\n![screenshot-1.png](/attachments/${ID}/screenshot-1.png)\nafter`), [
    { type: "paragraph", inline: [{ type: "text", text: "Before" }] },
    { type: "image", alt: "screenshot-1.png", src: `/attachments/${ID}/screenshot-1.png` },
    { type: "paragraph", inline: [{ type: "text", text: "after" }] },
  ]);
  assert.deepEqual(parse("![logo](https://maplefactory.dev/logo.png)"), [{ type: "image", alt: "logo", src: "https://maplefactory.dev/logo.png" }]);
  assert.deepEqual(parse(`[log.txt](/attachments/${ID}/log.txt)`), [{ type: "file", name: "log.txt", path: `/attachments/${ID}/log.txt` }]);
  // A link line to anywhere else stays an ordinary link.
  assert.equal(parse("[docs](https://example.com)")[0].type, "paragraph");
});

test("javascript:, data: and http: images are refused and show their alt text", () => {
  for (const src of ["javascript:alert(1)", "data:image/png;base64,AAAA", "http://example.com/a.png", "/attachments/nope/a.png", "//evil.com/a.png"]) {
    const blocks = parse(`![alt text](${src})`);
    assert.equal(blocks[0].type, "paragraph", src);
    assert.deepEqual(blocks[0].inline, [{ type: "text", text: "alt text" }], src);
    const tree = render(blocks, h);
    assert.ok(!tags(tree).includes("img"), src);
    assert.ok(!tags(tree).includes("a"), src);
  }
  assert.ok(!JSON.stringify(parse("[x](javascript:alert(1))")).includes('"file"'));
});

test("an image inside a sentence is an inline image; attachment links open on ordinary links", () => {
  assert.deepEqual(inline(`see ![shot](/attachments/${ID}/a.png) here`), [
    { type: "text", text: "see " },
    { type: "image", alt: "shot", src: `/attachments/${ID}/a.png` },
    { type: "text", text: " here" },
  ]);
  assert.deepEqual(inline(`the [log](/attachments/${ID}/log.txt) file`), [
    { type: "text", text: "the " },
    { type: "link", href: `/attachments/${ID}/log.txt`, children: [{ type: "text", text: "log" }] },
    { type: "text", text: " file" },
  ]);
  assert.deepEqual(inline("wow! [ok]"), [{ type: "text", text: "wow! [ok]" }]);
});

test("render() builds an <img> inside a link, and a file chip", () => {
  const tree = render(parse(`![shot.png](/attachments/${ID}/shot.png)\n\n[log.txt](/attachments/${ID}/log.txt)`), h);
  const [img, file] = tree.children;
  assert.equal(img.tag, "a");
  assert.equal(img.attrs.class, "md-img");
  assert.equal(img.attrs.href, `/attachments/${ID}/shot.png`);
  assert.equal(img.attrs.target, "_blank");
  assert.equal(img.children[0].tag, "img");
  assert.equal(img.children[0].attrs.src, `/attachments/${ID}/shot.png`);
  assert.equal(img.children[0].attrs.alt, "shot.png");
  assert.equal(typeof img.children[0].attrs.onerror, "function");
  assert.equal(file.tag, "a");
  assert.equal(file.attrs.class, "md-file");
  assert.equal(file.attrs.href, `/attachments/${ID}/log.txt`);
  assert.ok(texts(file).includes("log.txt"));
});

test("the editor's empty-src upload placeholder is a muted line", () => {
  const blocks = parse("![Uploading shot.png…]()");
  assert.deepEqual(blocks, [{ type: "image", alt: "Uploading shot.png…", src: "" }]);
  const [p] = render(blocks, h).children;
  assert.equal(p.tag, "p");
  assert.equal(p.attrs.class, "md-uploading");
  assert.deepEqual(texts(p), ["Uploading shot.png…"]);
});

// Task references: only IDs the factory knows link, so `UTF-8` and `ISO-8601` stay text.
import { taskResolver } from "../web/app/markdown.js";

test("a known task ID, bare or after #, becomes a taskref; unknown IDs and a#b stay text", () => {
  const tasks = taskResolver([{ id: "MF-12", title: "Reference tickets", state: "building" }, { id: "MF-3", title: "Old", state: "merged" }]);
  const ref = { type: "taskref", id: "MF-12", title: "Reference tickets", state: "building" };
  assert.deepEqual(inline("see MF-12.", tasks), [{ type: "text", text: "see " }, ref, { type: "text", text: "." }]);
  assert.deepEqual(inline("(#MF-12)", tasks), [{ type: "text", text: "(" }, ref, { type: "text", text: ")" }]);
  assert.deepEqual(inline("**MF-3**", tasks), [{ type: "strong", children: [{ type: "taskref", id: "MF-3", title: "Old", state: "merged" }] }]);
  for (const plain of ["UTF-8 and ISO-8601", "foo#bar a#b", "MF-99 is unknown", "XMF-12", "MF-12a", "MF-12-x", "`MF-12`", "a#MF-12"]) {
    assert.ok(!JSON.stringify(inline(plain, tasks)).includes("taskref"), plain);
  }
  // Without a resolver, nothing links.
  assert.deepEqual(inline("MF-12"), [{ type: "text", text: "MF-12" }]);
  // Link text doesn't nest another link.
  assert.ok(!JSON.stringify(inline("[MF-12](https://x.dev)", tasks)).includes("taskref"));
  assert.deepEqual(parse("- MF-12", tasks)[0].items[0].inline, [ref]);
});

test("a taskref renders as a link to the task with its state dot and title", () => {
  const h = (tag: string, attrs: Record<string, unknown>, ...children: unknown[]) => ({ tag, attrs, children: children.flat(Infinity) });
  const tasks = taskResolver([{ id: "MF-12", title: "Reference tickets", state: "building" }]);
  const tree = JSON.stringify(render(parse("see MF-12", tasks), h));
  assert.ok(tree.includes('"href":"#/t/MF-12"'));
  assert.ok(tree.includes('"title":"Reference tickets"'));
  assert.ok(tree.includes('"class":"dot bg-building"'));
});

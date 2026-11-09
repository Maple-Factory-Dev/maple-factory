// MF-361: Markdown import/export for the docs editor, through the editor's own TipTap schema.
import { test } from "node:test";
import assert from "node:assert/strict";
import { schema } from "../docs-editor/src/schema.js";
import { fromMarkdown, toMarkdown, taskResolver, markdownPasteSlice, looksLikeMarkdown } from "../docs-editor/src/markdown.js";

const ctx = {
  members: [{ login: "afomera", name: "Andrea" }, { login: "octo-cat", name: "Octo" }],
  tasks: taskResolver([{ id: "MF-12", title: "Twelve" }, { id: "MF-360", title: "Docs foundation" }]),
};

const FIXTURES: Record<string, string> = {
  headings: "# One\n\n## Two\n\n### Three\n\nBody text.\n",
  "inline marks": "Some **bold**, *italic*, `code`, ~~strike~~ and ***both***.\n",
  links: "See [the docs](https://maplefactory.dev/docs) and [a titled link](https://x.dev \"X\").\n",
  "nested lists": "- one\n- two\n  - two a\n  - two b\n    - deeper\n- three\n",
  "ordered lists": "1. first\n2. second\n   - mixed\n3. third\n",
  "task lists": "- [ ] todo\n- [x] done\n  - [ ] nested todo\n",
  quotes: "> A quote with **bold**.\n>\n> Second paragraph.\n",
  "fenced code with language": "```ts\nconst a: number = 1;\n\nfunction f() {}\n```\n",
  "fenced code without language": "```\nplain\n```\n",
  "mentions and task refs": "Hey @afomera and @octo-cat, see MF-12 and MF-360 (not UTF-8 or MF-999).\n",
  "rule and mixed doc": "# Plan\n\nIntro for @afomera.\n\n---\n\n- [x] ship MF-12\n- [ ] write [notes](https://x.dev)\n\n> Ask *first*.\n",
};

for (const [name, md] of Object.entries(FIXTURES)) {
  test(`round-trips ${name}`, () => {
    const doc = fromMarkdown(schema, md, ctx);
    doc.check(); // valid in the editor schema
    assert.equal(toMarkdown(doc), md);
  });
}

const types = (node: any): string[] => {
  const out: string[] = [];
  node.descendants((n: any) => { out.push(n.type.name); });
  return out;
};

test("imports to the editor's node types", () => {
  const doc = fromMarkdown(schema, FIXTURES["rule and mixed doc"], ctx);
  const t = types(doc);
  for (const want of ["heading", "paragraph", "mention", "horizontalRule", "taskList", "taskItem", "taskRef", "blockquote"]) assert.ok(t.includes(want), want);
  const items: any[] = [];
  doc.descendants((n: any) => { if (n.type.name === "taskItem") items.push(n.attrs.checked); });
  assert.deepEqual(items, [true, false]);
  let ref: any;
  doc.descendants((n: any) => { if (n.type.name === "taskRef") ref = n.attrs; });
  assert.deepEqual({ ...ref }, { id: "MF-12", title: "Twelve" });
  const code = fromMarkdown(schema, FIXTURES["fenced code with language"], ctx).firstChild!;
  assert.equal(code.type.name, "codeBlock");
  assert.equal(code.attrs.language, "ts");
});

test("unknown task ids and members stay text", () => {
  const doc = fromMarkdown(schema, "MF-999 and @nobody and me@afomera.dev\n", ctx);
  assert.deepEqual(types(doc), ["paragraph", "text"]);
});

test("pasting Markdown produces nodes, not plain text", () => {
  const slice = markdownPasteSlice(schema, "## Heading\n\n- [ ] a task for @afomera\n- [x] MF-12\n\n```js\nx()\n```", ctx)!;
  assert.ok(slice);
  const names = slice.content.content.map((n: any) => n.type.name);
  assert.deepEqual(names, ["heading", "taskList", "codeBlock"]);
  const inline: string[] = [];
  slice.content.forEach((n: any) => n.descendants((c: any) => { inline.push(c.type.name); }));
  assert.ok(inline.includes("mention") && inline.includes("taskRef"));
  assert.equal(slice.openStart, 0);
});

test("pasting one line of Markdown pastes inline marks", () => {
  const slice = markdownPasteSlice(schema, "some **bold** and [link](https://x.dev)", ctx)!;
  assert.equal(slice.openStart, 1);
  const marks: string[] = [];
  slice.content.firstChild!.forEach((n: any) => n.marks.forEach((m: any) => marks.push(m.type.name)));
  assert.deepEqual(marks.sort(), ["bold", "link"]);
});

test("plain prose pastes as plain text", () => {
  assert.equal(looksLikeMarkdown("Just a sentence, nothing more."), false);
  assert.equal(markdownPasteSlice(schema, "Just a sentence.", ctx), null);
});

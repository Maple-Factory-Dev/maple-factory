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

// MF-362: the Mac app's offline demo doc seeds a Y.Doc from Markdown, with no socket.
test("demo mode seeds a Y.Doc from Markdown", async () => {
  const Y = await import("yjs");
  const { yXmlFragmentToProseMirrorRootNode } = await import("@tiptap/y-tiptap");
  const { seedFromMarkdown, SHARED_TYPE } = await import("../docs-editor/src/editor.js");
  const md = "# Docs in Maple Factory\n\nPlan with @afomera, link MF-12.\n\n- [ ] try it\n";
  const ydoc = seedFromMarkdown(new Y.Doc(), md, ctx);
  const doc = yXmlFragmentToProseMirrorRootNode(ydoc.getXmlFragment(SHARED_TYPE), schema);
  assert.equal(toMarkdown(doc), md);
});

// MF-363: planning visuals. One export test per node, each valid in the schema and round-tripping.
const vtasks = [
  { id: "MF-12", title: "Twelve", state: "reviewing", pr: { number: 204, url: "https://github.com/o/r/pull/204" }, assignee: "afomera" },
];
const vctx = { ...ctx, tasks: taskResolver(vtasks) };
const VISUALS: Record<string, [string, string]> = {
  mermaid: ["mermaid", "```mermaid\nflowchart LR\n  A[\"/app/docs\"] --> B\n```\n"],
  table: ["table", "| Week | Built | Merged |\n| --- | --- | --- |\n| W1 | 4 | 3 |\n| W2 | 7 | 5 \\| ok |\n"],
  chart: ["chart", "```chart\ntype: line\ntitle: Throughput\n```\n"],
  image: ["image", "![A screenshot](/attachments/2f1c/shot.png \"width=320\")\n"],
  "file attachment": ["fileAttachment", "[spec.pdf](/attachments/9a0b/spec.pdf \"application/pdf · 48213 bytes\")\n"],
  "callout note": ["callout", "> [!NOTE]\n> Plans render offline.\n"],
  "callout tip": ["callout", "> [!TIP]\n> Use `/chart`.\n"],
  "callout warning": ["callout", "> [!WARNING]\n> No SVG uploads.\n"],
  "callout important": ["callout", "> [!IMPORTANT]\n> Ship it.\n>\n> - one\n> - two\n"],
  toggle: ["toggle", "> [!TOGGLE] Details\n> Hidden **text**.\n"],
  "task embed": ["taskEmbed", "> [!TASK] MF-12 · Twelve · reviewing · PR #204 · @afomera\n"],
};
for (const [name, [type, md]] of Object.entries(VISUALS)) {
  test(`exports ${name}`, () => {
    const doc = fromMarkdown(schema, md, vctx);
    doc.check();
    assert.ok(types(doc).includes(type), `${type} in ${types(doc)}`);
    assert.equal(toMarkdown(doc, vctx), md);
  });
}

test("visual node attributes come back from Markdown", () => {
  const first = (md: string) => fromMarkdown(schema, md, vctx).firstChild!;
  assert.equal(first(VISUALS.mermaid[1]).attrs.source, "flowchart LR\n  A[\"/app/docs\"] --> B");
  assert.deepEqual({ ...first(VISUALS.chart[1]).attrs }, { kind: "line", title: "Throughput" });
  assert.deepEqual({ ...first(VISUALS.image[1]).attrs }, { src: "/attachments/2f1c/shot.png", alt: "A screenshot", width: 320 });
  assert.deepEqual({ ...first(VISUALS["file attachment"][1]).attrs }, { href: "/attachments/9a0b/spec.pdf", name: "spec.pdf", size: 48213, mime: "application/pdf" });
  assert.equal(first(VISUALS["callout warning"][1]).attrs.tone, "warning");
  assert.equal(first(VISUALS.toggle[1]).attrs.summary, "Details");
  const table = first(VISUALS.table[1]);
  assert.equal(table.firstChild!.firstChild!.type.name, "tableHeader");
  assert.equal(table.child(2).child(2).textContent, "5 | ok");
});

test("task embeds export a snapshot but import only the id", () => {
  const doc = fromMarkdown(schema, "> [!TASK] MF-12 · Stale title · building\n", vctx);
  assert.deepEqual({ ...doc.firstChild!.attrs }, { id: "MF-12" });
  // Export snapshots the task's current state, PR and owner from the lookup, not the stale text.
  assert.equal(toMarkdown(doc, vctx), VISUALS["task embed"][1]);
  // With no lookup (or a task the feed doesn't have) only the id is written.
  assert.equal(toMarkdown(doc), "> [!TASK] MF-12\n");
});

test("a chart turns the table above it into series, skipping non-numeric cells", async () => {
  const { chartSeries, tableAbove } = await import("../docs-editor/src/nodes.js");
  const md = "| Week | Built | Notes | Merged |\n| --- | --- | --- | --- |\n| W1 | 4 | slow | 3 |\n| W2 | 1,200 | fast | n/a |\n\n```chart\ntype: bar\n```\n";
  const doc = fromMarkdown(schema, md, vctx);
  let chartPos = -1;
  doc.forEach((n: any, off: number) => { if (n.type.name === "chart") chartPos = off; });
  const data = chartSeries(tableAbove(doc, chartPos));
  assert.deepEqual(data, { labels: ["W1", "W2"], series: [{ name: "Built", values: [4, 1200] }, { name: "Merged", values: [3, null] }] });
  assert.deepEqual(chartSeries(tableAbove(doc, 0)), { labels: [], series: [] });
});

test("uploads: png/jpeg/gif/webp become images; SVG and everything else a file", async () => {
  const { nodeForUpload } = await import("../docs-editor/src/nodes.js");
  const up = (name: string, mime: string) => nodeForUpload({ path: `/attachments/x/${name}`, name, mime, size: 10 }).type;
  for (const [n, m] of [["a.png", "image/png"], ["a.jpg", "image/jpeg"], ["a.gif", "image/gif"], ["a.webp", "image/webp"]]) assert.equal(up(n, m), "image", n);
  for (const [n, m] of [["a.svg", "image/svg+xml"], ["b.svg", "image/png"], ["a.pdf", "application/pdf"], ["a.bmp", "image/bmp"], ["a.txt", "text/plain"], ["a", ""]]) assert.equal(up(n, m), "fileAttachment", n);
});

test("a doc with every block exports readable Markdown and reads back", () => {
  const md = [VISUALS.mermaid[1], VISUALS.table[1], VISUALS.chart[1], VISUALS.image[1], VISUALS["file attachment"][1], VISUALS["callout note"][1], VISUALS.toggle[1], "---\n", VISUALS["task embed"][1]].join("\n");
  const doc = fromMarkdown(schema, md, vctx);
  doc.check();
  assert.equal(toMarkdown(doc, vctx), md);
});

test("images load only from /attachments/; any other image stays a link", () => {
  const md = (text: string) => toMarkdown(fromMarkdown(schema, text, vctx));
  const doc = fromMarkdown(schema, "![pixel](https://evil.example/p.gif)\n", vctx);
  doc.check();
  assert.ok(!types(doc).includes("image"), types(doc).join());
  assert.equal(md("![pixel](https://evil.example/p.gif)\n"), "[pixel](https://evil.example/p.gif)\n");
  assert.equal(md("see ![x](//evil.example/x.png) here\n"), "see [x](//evil.example/x.png) here\n");
  // An attachment image inside other text is a link too; alone in its paragraph it's an image node.
  assert.equal(md("see ![a](/attachments/1/a.png) here\n"), "see [a](/attachments/1/a.png) here\n");
  assert.equal(md(VISUALS.image[1]), VISUALS.image[1]);
});

test("a [!RESEARCH] quote (not a block here; MF-366) stays a plain quote", () => {
  const doc = fromMarkdown(schema, "> [!RESEARCH] MF-40 · Which chart lib?\n", vctx);
  doc.check();
  assert.equal(doc.firstChild!.type.name, "blockquote");
});

// MF-384: highlighted code blocks with a language picker.
import { Editor } from "@tiptap/core";
import { EditorState } from "@tiptap/pm/state";
import { schemaExtensions } from "../docs-editor/src/schema.js";
import { CODE_LANGUAGES, canonicalLanguage } from "../docs-editor/src/codeblock.js";

test("code fences keep their language as written", () => {
  for (const md of ["```ts\nconst a = 1;\n```\n", "```\nplain\n```\n", "```text\nplain\n```\n", "```swift\nlet a = 1\n```\n"]) {
    const doc = fromMarkdown(schema, md, ctx);
    assert.equal(toMarkdown(doc), md);
  }
  assert.equal(fromMarkdown(schema, "```ts\nx\n```\n", ctx).firstChild!.attrs.language, "ts");
  assert.equal(fromMarkdown(schema, "```\nx\n```\n", ctx).firstChild!.attrs.language, null);
  assert.equal(schema.nodes.codeBlock.create().attrs.language, null, "a new block is Plain text and exports a bare fence");
});

test("the picker maps fences to its languages", () => {
  for (const plain of [null, "", "text", "txt", "plaintext", "TEXT"]) assert.equal(canonicalLanguage(plain), null, String(plain));
  assert.equal(canonicalLanguage("ts"), "typescript");
  assert.equal(canonicalLanguage("swift"), "swift");
  assert.equal(canonicalLanguage("sh"), "bash");
  assert.equal(canonicalLanguage("not-a-language"), undefined);
  assert.ok(CODE_LANGUAGES.length > 150, `${CODE_LANGUAGES.length} languages`);
  assert.deepEqual(CODE_LANGUAGES[0], { id: null, label: "Plain text" });
  assert.deepEqual(CODE_LANGUAGES.slice(1, 4).map((l) => l.id), ["typescript", "javascript", "swift"]);
  assert.equal(new Set(CODE_LANGUAGES.map((l) => l.id)).size, CODE_LANGUAGES.length, "no duplicates");
});

test("lowlight decorates ts blocks and leaves plain and unknown blocks alone", () => {
  const editor = new Editor({ element: null, extensions: schemaExtensions(), content: { type: "doc", content: [{ type: "paragraph" }] } });
  const plugin = editor.extensionManager.plugins.find((p: any) => p.key.startsWith("lowlight"))!;
  const decorations = (md: string) => {
    const state = EditorState.create({ doc: fromMarkdown(schema, md, ctx), plugins: [plugin] });
    return (plugin.getState(state) as any).find().map((d: any) => d.type.attrs.class);
  };
  const ts = decorations("```ts\nconst a: number = 1;\n```\n");
  assert.ok(ts.includes("hljs-keyword") && ts.includes("hljs-number"), ts.join(" "));
  assert.deepEqual(decorations("```\nconst a: number = 1;\n```\n"), []);
  assert.deepEqual(decorations("```text\nconst a: number = 1;\n```\n"), []);
  assert.deepEqual(decorations("```not-a-language\nconst a: number = 1;\n```\n"), [], "no auto-detect guessing");
  editor.destroy();
});

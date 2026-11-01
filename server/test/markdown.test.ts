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

// A pull request body's attachment links (server/src/attachments.ts pullAttachments, engine.ts pullBody).
import { pullAttachments } from "../src/attachments.ts";
import { pullBody } from "../src/factory/engine.ts";

const PULL_ID = "130e54d7-e745-4075-ac37-93200aba18cb";
const shot = `/attachments/${PULL_ID}/shot.png`;
const brief = `See ![shot.png](${shot}) and [the log](/attachments/${PULL_ID}/run.log), or ${shot}.`;
const base = "https://factory.example";

test("a private repo's PR body links each attachment at the factory", () => {
  assert.equal(
    pullAttachments(brief, { base, isPrivate: true, taskId: "MF-163" }),
    `See [shot.png](${base}${shot}) and [the log](${base}/attachments/${PULL_ID}/run.log), or [shot.png](${base}${shot}).`,
  );
});

test("a public repo's PR body names each attachment and links to the task's page", () => {
  const out = pullAttachments(brief, { base, isPrivate: false, taskId: "MF-163" });
  const at = `(attached in Maple Factory: [MF-163](${base}/t/MF-163))`;
  assert.equal(out, `See shot.png ${at} and the log ${at}, or shot.png ${at}.`);
  assert.ok(!out.includes("/attachments/"));
});

test("with no PUBLIC_URL only the file's name is kept", () => {
  for (const isPrivate of [true, false]) {
    const out = pullAttachments(brief, { base: undefined, isPrivate, taskId: "MF-163" });
    assert.equal(out, "See shot.png (attached in Maple Factory) and the log (attached in Maple Factory), or shot.png (attached in Maple Factory).");
  }
});

test("absolute and malformed attachment links are left as they are", () => {
  const kept = [
    `![shot](https://elsewhere.example${shot})`,
    `see https://elsewhere.example${shot} there`,
    "![shot](/attachments/not-a-uuid/shot.png)",
    "/attachments/not-a-uuid/shot.png",
    `[x](/attachments/${PULL_ID}/../secret)`,
  ];
  for (const md of kept) assert.equal(pullAttachments(md, { base, isPrivate: true, taskId: "MF-163" }), md);
});

test("pullBody rewrites the brief, the plan and the evidence", () => {
  const task = {
    id: "MF-163", owner: "ana", brief: `![shot.png](${shot})`,
    plan: [{ text: `Match ${shot}` }],
    doneWhen: [{ text: "Looks right", status: "proven", evidence: { summary: `as in ${shot}` } }],
  } as any;
  const priv = pullBody(task, { base, isPrivate: true });
  assert.equal(priv.split(`[shot.png](${base}${shot})`).length, 4);
  assert.ok(!priv.includes("(/attachments/"));
  // On a public repo only the plan step still carries the attachment; the brief and evidence stay home.
  const pub = pullBody(task, { base, isPrivate: false });
  assert.ok(!pub.includes("/attachments/"));
  assert.equal(pub.split(`[MF-163](${base}/t/MF-163)`).length, 3);
  assert.ok(pub.includes(`The brief is kept in Maple Factory: [MF-163](${base}/t/MF-163)`));
});

// A brief can name a customer or quote a private thread: a public repo's PR body must not show it.
const sentinelTask = () =>
  ({
    id: "MF-169", owner: "ana", brief: "Globex Corporation asked us, in their private Slack, to hide the brief.",
    plan: [{ text: "Branch on isPrivate", file: "server/src/factory/engine.ts" }, { text: "Add tests" }],
    doneWhen: [
      { text: "Unit tests pass", status: "proven", evidence: { summary: "Globex Corporation's case is covered" } },
      { text: "Looks right", status: "proven", evidence: { attested: true, by: "bo", reason: "checked with Globex Corporation" } },
      { text: "E2E passes", status: "pending" },
    ],
  }) as any;

test("a public repo's PR body leaves out the brief and the evidence summaries", () => {
  const out = pullBody(sentinelTask(), { base, isPrivate: false });
  assert.ok(!out.includes("Globex"), out);
  assert.ok(out.startsWith("Built by Maple Factory for **MF-169**, owned by @ana."));
  assert.ok(out.includes(`The brief is kept in Maple Factory: [MF-169](${base}/t/MF-169)`));
  assert.ok(out.includes("## Plan\n\n1. Branch on isPrivate (`server/src/factory/engine.ts`)\n2. Add tests"));
  assert.ok(out.includes("## Done when\n\n- [x] Unit tests pass\n- [x] Looks right (attested by @bo)\n- [ ] E2E passes"));
});

test("a private repo's PR body still has the brief and the evidence", () => {
  assert.equal(
    pullBody(sentinelTask(), { base, isPrivate: true }),
    [
      "Built by Maple Factory for **MF-169**, owned by @ana.",
      "Globex Corporation asked us, in their private Slack, to hide the brief.",
      "## Plan\n\n1. Branch on isPrivate (`server/src/factory/engine.ts`)\n2. Add tests",
      "## Done when\n\n- [x] Unit tests pass — Globex Corporation's case is covered\n- [x] Looks right (attested by @bo: checked with Globex Corporation)\n- [ ] E2E passes",
    ].join("\n\n"),
  );
});

test("with no PUBLIC_URL a public repo's PR body still leaves out the brief", () => {
  const out = pullBody(sentinelTask(), { base: undefined, isPrivate: false });
  assert.ok(!out.includes("Globex"), out);
  assert.ok(out.includes("\n\nThe brief is kept in Maple Factory.\n\n"));
  assert.ok(!out.includes("/t/MF-169"));
});

// The pull request's Artifacts section (engine.ts pullArtifacts, swapArtifacts) — MF-209.
import { ARTIFACTS_END, ARTIFACTS_START, pullArtifacts, swapArtifacts } from "../src/factory/engine.ts";

const artifactTask = () =>
  ({
    ...sentinelTask(),
    artifacts: [
      { id: "a-review", title: "Review notes", kind: "markdown", summary: "Globex Corporation's flow, checked", by: "reviewer", at: 2, version: 1 },
      { id: "a-walk", title: "Change walkthrough", kind: "html", summary: "Before/after for Globex Corporation", by: "builder", at: 1, version: 2 },
    ],
  }) as any;

test("a private repo's PR body lists each artifact with its summary, linked to it on the task page", () => {
  const out = pullBody(artifactTask(), { base, isPrivate: true });
  assert.ok(out.endsWith(
    `${ARTIFACTS_START}\n## Artifacts\n\nShared by the agents on MF-169.\n\n` +
      `- [Change walkthrough](${base}/t/MF-169?artifact=a-walk) (html, v2, shared by the builder) — Before/after for Globex Corporation\n` +
      `- [Review notes](${base}/t/MF-169?artifact=a-review) (markdown, shared by the reviewer) — Globex Corporation's flow, checked\n` +
      ARTIFACTS_END,
  ), out);
});

test("a public repo's PR body lists artifacts by title and members-only link, without summaries", () => {
  const out = pullArtifacts(artifactTask(), { base, isPrivate: false });
  assert.ok(!out.includes("Globex"), out);
  assert.ok(out.includes(`- [Change walkthrough](${base}/t/MF-169?artifact=a-walk) (html, v2, shared by the builder)\n`));
  assert.ok(out.includes("Links open in Maple Factory, for its members."));
  assert.ok(!pullBody(artifactTask(), { base, isPrivate: false }).includes("Globex"));
});

test("with no PUBLIC_URL artifacts are named, not linked", () => {
  const out = pullArtifacts(artifactTask(), { base: undefined, isPrivate: false });
  assert.ok(out.includes("- Change walkthrough (html, v2, shared by the builder)\n"), out);
  assert.ok(!out.includes("/t/"));
});

test("no artifacts, no Artifacts section", () => {
  assert.equal(pullArtifacts(sentinelTask(), { base, isPrivate: true }), "");
  assert.ok(!pullBody(sentinelTask(), { base, isPrivate: true }).includes("Artifacts"));
});

test("artifact titles can't break out of their link", () => {
  const t = { ...sentinelTask(), artifacts: [{ id: "x", title: "a](https://evil.example) [b", kind: "html", by: "builder", at: 1, version: 1 }] } as any;
  assert.ok(pullArtifacts(t, { base, isPrivate: true }).includes("[a\\](https://evil.example) \\[b]("));
});

test("swapping the Artifacts block keeps what people wrote above and below it", () => {
  const v1 = pullArtifacts(artifactTask(), { base, isPrivate: true });
  const body = `Built by Maple Factory.\n\nA note a person added above.\n\n${v1}\n\nAnd one below, by @bo.`;
  const t2 = artifactTask();
  t2.artifacts[1] = { ...t2.artifacts[1], id: "a-walk-3", version: 3 };
  const v2 = pullArtifacts(t2, { base, isPrivate: true });
  const out = swapArtifacts(body, v2);
  assert.equal(out, `Built by Maple Factory.\n\nA note a person added above.\n\n${v2}\n\nAnd one below, by @bo.`);
  assert.ok(out.includes("?artifact=a-walk-3) (html, v3,"));
  assert.equal(out.split(ARTIFACTS_START).length, 2);
});

test("a removed Artifacts block is appended again; an empty one drops it", () => {
  const block = pullArtifacts(artifactTask(), { base, isPrivate: true });
  assert.equal(swapArtifacts("Edited by a person.\n", block), `Edited by a person.\n\n${block}`);
  assert.equal(swapArtifacts("", block), block);
  assert.equal(swapArtifacts(`Above\n\n${block}\n\nBelow`, ""), "Above\n\n\n\nBelow");
  assert.equal(swapArtifacts("No block here", ""), "No block here");
});

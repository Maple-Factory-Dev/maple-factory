// Docs without a DOM (MF-365): what agents' doc tools see and do, run inside DocHub (Workers) and the tests.
// The Yjs doc becomes Markdown with stable block ids, a block id or a quoted span becomes the same base64
// Y.RelativePosition anchor the editor's comments use (comments.js), and an accepted suggestion is applied
// with updateYFragment, so it reaches every open editor as an ordinary Yjs update.
import * as Y from "yjs";
import { initProseMirrorDoc, updateYFragment } from "@tiptap/y-tiptap";
import { Slice } from "@tiptap/pm/model";
import { Transform } from "@tiptap/pm/transform";
import { schema } from "./schema.js";
import { toMarkdown, fromMarkdown } from "./markdown.js";
import { anchorFromRange, resolveAnchor } from "./comments.js";

export const SHARED_TYPE = "prosemirror";
/** The most text an anchor holds (comments.js anchorFromRange cuts its quote here). */
export const MAX_QUOTE = 2000;
/** `b-<clientID base36>-<clock>`: the id of the Y.XmlElement item that holds a top-level block. */
export const BLOCK_ID = /^b-[0-9a-z]+-\d+$/;

/** An error for the agent; the server passes its message on as is. */
export class DocToolError extends Error {}
const fail = (message) => { throw new DocToolError(message); };

function view(ydoc) {
  const fragment = ydoc.getXmlFragment(SHARED_TYPE);
  const { doc, mapping, meta } = initProseMirrorDoc(fragment, schema);
  // Top-level PM node → its block id, through the binding's Y element ↔ PM node mapping.
  const ids = new Map();
  for (const el of fragment.toArray()) {
    const node = mapping.get(el);
    if (node && el._item) ids.set(node, `b-${el._item.id.client.toString(36)}-${el._item.id.clock}`);
  }
  const blocks = [];
  doc.forEach((node, offset) => blocks.push({ id: ids.get(node) ?? null, node, from: offset, to: offset + node.nodeSize }));
  return { fragment, doc, mapping, meta, blocks };
}

const blockMarkdown = (node) => toMarkdown(schema.topNodeType.create(null, [node])).replace(/\n+$/, "");

/**
 * The doc as Markdown, each top-level block preceded by `<!-- block b-… -->`, plus where each thread sits now:
 * {markdown, blocks: [{id, markdown}], threads: [{id, block, quote, orphan}]}.
 */
export function readDoc(ydoc, threads = []) {
  const v = view(ydoc);
  const blocks = v.blocks.map((b) => ({ id: b.id, markdown: blockMarkdown(b.node) }));
  const markdown = blocks.map((b) => `<!-- block ${b.id} -->\n${b.markdown}`).join("\n\n") + "\n";
  const placed = threads.map((t) => {
    if (!t.anchor) return { id: t.id, block: null, quote: null, orphan: false };
    const r = resolveAnchor(ydoc, v.mapping, t.anchor);
    if (r.orphan) return { id: t.id, block: null, quote: t.anchor.quote, orphan: true };
    const block = v.blocks.find((b) => r.from >= b.from && r.from < b.to);
    return { id: t.id, block: block?.id ?? null, quote: v.doc.textBetween(r.from, r.to, " ", " "), orphan: false };
  });
  return { markdown, blocks, threads: placed };
}

/** Every PM range of `quote` inside `node` (at `base`), within single textblocks. */
function findQuote(node, base, quote) {
  const hits = [];
  const scan = (tb, pos) => {
    // The textblock's text with one placeholder char per inline atom, and each char's PM position.
    let text = "";
    const at = [];
    tb.forEach((child, off) => {
      if (child.isText) for (let i = 0; i < child.text.length; i++) { text += child.text[i]; at.push(pos + 1 + off + i); }
      else { text += "￼"; at.push(pos + 1 + off); }
    });
    for (let i = text.indexOf(quote); i >= 0; i = text.indexOf(quote, i + 1)) hits.push([at[i], at[i + quote.length - 1] + 1]);
  };
  if (node.isTextblock) scan(node, base);
  else node.descendants((n, pos) => { if (n.isTextblock) { scan(n, base + 1 + pos); return false; } return true; });
  return hits;
}

/**
 * An anchor ({from, to, quote}, as comments.js makes) for a quoted span (found exactly once, inside `block`
 * when given) or a whole block's text.
 */
export function anchorFor(ydoc, { block = null, quote = null } = {}) {
  const v = view(ydoc);
  let scope = null;
  if (block) {
    scope = v.blocks.find((b) => b.id === block) ?? fail(`There's no block ${block} in this doc any more; read_doc again.`);
  }
  let from, to;
  if (quote != null) {
    if (!quote) fail("quote can't be empty.");
    const hits = scope ? findQuote(scope.node, scope.from, quote) : findQuote(v.doc, -1, quote);
    if (!hits.length) fail(`"${quote.slice(0, 80)}" isn't in ${scope ? `block ${block}` : "the doc"} (quote exact text from inside one paragraph, heading or list item).`);
    if (hits.length > 1) fail(`"${quote.slice(0, 80)}" appears ${hits.length} times${scope ? ` in block ${block}` : ""}; quote more of it, or give its block.`);
    [from, to] = hits[0];
  } else if (scope) {
    // The block's text: inside its first and last textblock.
    let first = null, last = null;
    if (scope.node.isTextblock) { first = scope.from + 1; last = scope.to - 1; }
    else scope.node.descendants((n, pos) => {
      if (!n.isTextblock) return true;
      const start = scope.from + 1 + pos;
      if (first == null) first = start + 1;
      last = start + n.nodeSize - 1;
      return false;
    });
    if (first == null || first >= last) fail(`Block ${block} has no text to anchor to; quote text near it instead.`);
    [from, to] = [first, last];
  } else fail("Give a block id or a quote.");
  // Anchors keep at most MAX_QUOTE characters of their text (anchorFromRange), and Accept checks the text
  // still reads as the quote, so a longer span could never be applied.
  if (v.doc.textBetween(from, to, " ", " ").length > MAX_QUOTE) fail(`That span is over ${MAX_QUOTE} characters; quote a shorter part of it (one sentence or paragraph).`);
  return anchorFromRange(ydoc, v.mapping, v.doc, from, to);
}

/**
 * Replaces an anchor's text with `markdown` (empty: deletes it), as one Yjs transaction on `ydoc` (`origin`
 * passed on). Refuses when the anchored text was deleted or no longer reads as the quote.
 */
export function applySuggestion(ydoc, anchor, markdown, origin = null) {
  const v = view(ydoc);
  const r = resolveAnchor(ydoc, v.mapping, anchor);
  if (r.orphan) fail("The suggested text was deleted, so this suggestion can't be applied.");
  const now = v.doc.textBetween(r.from, r.to, " ", " ");
  if (now !== anchor.quote) fail("The text changed since this was suggested, so it can't be applied; reject it or ask for a new one.");
  const parsed = fromMarkdown(schema, markdown ?? "");
  const slice = markdown?.trim() ? new Slice(parsed.content, 1, 1) : Slice.empty;
  let next;
  try {
    next = new Transform(v.doc).replace(r.from, r.to, slice).doc;
  } catch (e) {
    fail(`That replacement doesn't fit there: ${e.message}`);
  }
  ydoc.transact(() => updateYFragment(ydoc, v.fragment, next, v.meta), origin);
  return { before: now, after: next };
}

/**
 * Inserts a decision embed (MF-367) for decision `id`: after the top-level block holding `block` or `quote`,
 * or at the end of the doc. One Yjs transaction on `ydoc`. Returns {block: the block it follows, or null}.
 */
export function insertDecision(ydoc, id, { block = null, quote = null } = {}, origin = null) {
  const v = view(ydoc);
  if (findDecision(v.doc, id)) fail(`Decision ${id} is already in this doc.`);
  let after = null;
  if (block || quote) {
    let scope = block ? v.blocks.find((b) => b.id === block) ?? fail(`There's no block ${block} in this doc any more; read_doc again.`) : null;
    if (quote) {
      const hits = scope ? findQuote(scope.node, scope.from, quote) : findQuote(v.doc, -1, quote);
      if (!hits.length) fail(`"${quote.slice(0, 80)}" isn't in ${scope ? `block ${block}` : "the doc"}.`);
      if (hits.length > 1) fail(`"${quote.slice(0, 80)}" appears ${hits.length} times; quote more of it, or give its block.`);
      scope = v.blocks.find((b) => hits[0][0] >= b.from && hits[0][0] < b.to) ?? scope;
    }
    after = scope;
  }
  const at = after ? after.to : v.doc.content.size;
  const next = new Transform(v.doc).insert(at, schema.nodes.decision.create({ id })).doc;
  ydoc.transact(() => updateYFragment(ydoc, v.fragment, next, v.meta), origin);
  return { block: after?.id ?? null };
}

/** Whether the doc holds a decision embed for `id`. */
export function findDecision(doc, id) {
  let found = false;
  doc.descendants((n) => { if (found) return false; if (n.type.name === "decision" && n.attrs.id === id) found = true; return !found; });
  return found;
}

/** The most of a section `sectionAt` returns (and a task's `fromDoc.excerpt` keeps). */
export const MAX_EXCERPT = 8000;

const headingText = (node) => node.textContent.trim();

/**
 * The part of the doc a task is made from (MF-368): {markdown, heading, quote, block}. `decision`: that
 * decision's card. `anchor` inside a heading: the heading's section, up to the next heading of the same or
 * a higher level. `anchor` elsewhere: the selected blocks (or the selected text, inside one block), under the
 * nearest heading above. Neither: the whole doc. `block` is the id of the source's last top-level block, the
 * one task embeds go after.
 */
export function sectionAt(ydoc, { anchor = null, decision = null } = {}) {
  const v = view(ydoc);
  const cap = (md) => (md.length > MAX_EXCERPT ? md.slice(0, MAX_EXCERPT - 1) + "…" : md);
  const headingAbove = (i) => {
    for (let k = i; k >= 0; k--) if (v.blocks[k].node.type.name === "heading") return headingText(v.blocks[k].node);
    return null;
  };
  const md = (list) => list.map((b) => blockMarkdown(b.node)).join("\n\n");
  if (decision) {
    const i = v.blocks.findIndex((b) => { let hit = false; b.node.descendants?.((n) => { if (n.type.name === "decision" && n.attrs.id === decision) hit = true; return !hit; }); return (b.node.type.name === "decision" && b.node.attrs.id === decision) || hit; });
    if (i < 0) fail("That decision's card isn't in this doc any more.");
    return { markdown: cap(md([v.blocks[i]])), heading: headingAbove(i), quote: null, block: v.blocks[i].id };
  }
  if (!anchor) {
    if (!v.blocks.length) fail("This doc is empty.");
    return { markdown: cap(md(v.blocks)), heading: null, quote: null, block: v.blocks.at(-1).id };
  }
  const r = resolveAnchor(ydoc, v.mapping, anchor);
  if (r.orphan) fail("The selected text was deleted; select it again.");
  const first = v.blocks.findIndex((b) => r.from >= b.from && r.from < b.to);
  if (first < 0) fail("The selection isn't in the doc any more; select it again.");
  const start = v.blocks[first];
  if (start.node.type.name === "heading") {
    const level = start.node.attrs.level ?? 1;
    let end = first + 1;
    while (end < v.blocks.length && !(v.blocks[end].node.type.name === "heading" && (v.blocks[end].node.attrs.level ?? 1) <= level)) end++;
    const list = v.blocks.slice(first, end);
    return { markdown: cap(md(list)), heading: headingText(start.node), quote: null, block: list.at(-1).id };
  }
  let last = first;
  while (last + 1 < v.blocks.length && r.to > v.blocks[last].to) last++;
  const quote = v.doc.textBetween(r.from, r.to, "\n", " ").trim();
  const markdown = first === last ? quote : md(v.blocks.slice(first, last + 1));
  return { markdown: cap(markdown), heading: headingAbove(first), quote: quote.slice(0, MAX_QUOTE) || null, block: v.blocks[last].id };
}

/** The task ids embedded in the doc. */
export function taskEmbeds(doc) {
  const ids = [];
  doc.descendants((n) => { if (n.type.name === "taskEmbed" && n.attrs.id) ids.push(n.attrs.id); return true; });
  return ids;
}

/**
 * Inserts live task embeds for `ids` after top-level block `block` (or at the end of the doc), in order, skipping
 * ids already embedded anywhere in the doc. One Yjs transaction. Returns {inserted: the ids it added}.
 */
export function insertTaskEmbeds(ydoc, ids, { block = null } = {}, origin = null) {
  const v = view(ydoc);
  const have = new Set(taskEmbeds(v.doc));
  const add = [...new Set(ids)].filter((id) => !have.has(id));
  if (!add.length) return { inserted: [] };
  const after = block ? v.blocks.find((b) => b.id === block) ?? null : null;
  const at = after ? after.to : v.doc.content.size;
  const next = new Transform(v.doc).insert(at, add.map((id) => schema.nodes.taskEmbed.create({ id }))).doc;
  ydoc.transact(() => updateYFragment(ydoc, v.fragment, next, v.meta), origin);
  return { inserted: add };
}

/** Seeds an empty Y.Doc from Markdown (tests, and DocHub's /seed for local dev). */
export function seedDoc(ydoc, markdown) {
  const fragment = ydoc.getXmlFragment(SHARED_TYPE);
  const doc = fromMarkdown(schema, markdown);
  const { meta } = initProseMirrorDoc(fragment, schema);
  ydoc.transact(() => updateYFragment(ydoc, fragment, doc, meta));
  return ydoc;
}

export { Y };

// MF-368: tasks from doc sections and decisions. The headless section reader and task-embed inserter, the pure
// split / compose / check module, and doc.makeTasks through the engine with a DocHub stand-in.
import { test } from "node:test";
import assert from "node:assert/strict";
import * as Y from "yjs";
import { initProseMirrorDoc } from "@tiptap/y-tiptap";
import { schema } from "../docs-editor/src/schema.js";
import { sectionAt, insertTaskEmbeds, anchorFor, readDoc, insertDecision, seedDoc, DocToolError } from "../docs-editor/src/headless.js";

const PLAN = "# Plan\n\nIntro text.\n\n## Search\n\nMake search fast.\n\n### Indexing\n\nBuild the index.\n\n### Ranking\n\nRank by recency.\n\n## Billing\n\nCharge monthly.\n";

const topTypes = (ydoc: Y.Doc) => {
  const { doc } = initProseMirrorDoc(ydoc.getXmlFragment("prosemirror"), schema);
  const out: string[] = [];
  doc.forEach((n) => out.push(n.type.name === "taskEmbed" ? `task:${n.attrs.id}` : n.type.name === "heading" ? `h:${n.textContent}` : n.textContent));
  return out;
};

test("sectionAt: a heading's section runs to the next heading of the same or higher level", () => {
  const ydoc = seedDoc(new Y.Doc(), PLAN);
  const search = readDoc(ydoc).blocks.find((b) => b.markdown === "## Search")!;
  const s = sectionAt(ydoc, { anchor: anchorFor(ydoc, { block: search.id }) });
  assert.equal(s.heading, "Search");
  assert.equal(s.markdown, "## Search\n\nMake search fast.\n\n### Indexing\n\nBuild the index.\n\n### Ranking\n\nRank by recency.");
  assert.equal(s.block, readDoc(ydoc).blocks.find((b) => b.markdown === "Rank by recency.")!.id);
  // A lower heading stops at its sibling.
  const idx = readDoc(ydoc).blocks.find((b) => b.markdown === "### Indexing")!;
  assert.equal(sectionAt(ydoc, { anchor: anchorFor(ydoc, { block: idx.id }) }).markdown, "### Indexing\n\nBuild the index.");
});

test("sectionAt: a selection is its text, under the nearest heading; a decision is its card", () => {
  const ydoc = seedDoc(new Y.Doc(), PLAN);
  const s = sectionAt(ydoc, { anchor: anchorFor(ydoc, { quote: "Charge monthly" }) });
  assert.deepEqual([s.markdown, s.heading, s.quote], ["Charge monthly", "Billing", "Charge monthly"]);
  const id = "11111111-2222-4333-8444-555555555555";
  insertDecision(ydoc, id, { quote: "Make search fast." });
  const d = sectionAt(ydoc, { decision: id });
  assert.equal(d.heading, "Search");
  assert.ok(d.block);
  assert.throws(() => sectionAt(ydoc, { decision: "99999999-2222-4333-8444-555555555555" }), DocToolError);
});

test("insertTaskEmbeds: embeds land right after the section, in order, and skip ids already there", () => {
  const ydoc = seedDoc(new Y.Doc(), PLAN);
  const search = readDoc(ydoc).blocks.find((b) => b.markdown === "## Search")!;
  const s = sectionAt(ydoc, { anchor: anchorFor(ydoc, { block: search.id }) });
  assert.deepEqual(insertTaskEmbeds(ydoc, ["MF-1", "MF-2"], { block: s.block }).inserted, ["MF-1", "MF-2"]);
  const types = topTypes(ydoc);
  assert.deepEqual(types.slice(types.indexOf("Rank by recency."), types.indexOf("h:Billing") + 1), ["Rank by recency.", "task:MF-1", "task:MF-2", "h:Billing"]);
  assert.deepEqual(insertTaskEmbeds(ydoc, ["MF-2", "MF-3"], { block: s.block }).inserted, ["MF-3"]);
  assert.equal(topTypes(ydoc).filter((t) => t === "task:MF-2").length, 1);
  assert.deepEqual(insertTaskEmbeds(ydoc, ["MF-1"]).inserted, []);
});

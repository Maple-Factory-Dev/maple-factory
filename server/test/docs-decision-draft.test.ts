// MF-414: what you type into a decision card lives in a per-editor draft store (host.drafts), so a card that
// redraws from the feed, or a node view that's recreated, can't replace it with the saved values.
import { test } from "node:test";
import assert from "node:assert/strict";
import "../docs-editor/src/schema.js"; // first, as the editor loads it: decisions.js sits in an import cycle with nodes.js
import { cardKey, draftFor, setDraft, clearDraft, draftDiffers } from "../docs-editor/src/decisions.js";

const D = "11111111-1111-4111-8111-111111111111";
const decision = (over: Record<string, unknown> = {}) => ({
  id: D, doc: "doc", status: "proposed", question: "Which database?", chosen: null, rationale: "",
  options: [{ id: "a", label: "Postgres", note: null }, { id: "b", label: "SQLite", note: null }],
  proposedBy: "owner", proposedAt: 1, ...over,
});
const hostWith = (decisions: any[], tasks: any[] = []) => ({ decisions: () => decisions, tasks: () => tasks, editing: new Set<string>(), drafts: new Map<string, any>() });

test("a draft is seeded once from the decision, with what the form opened on as its base", () => {
  const host = hostWith([decision()]);
  const draft = draftFor(host, decision());
  assert.deepEqual(draft, { question: "Which database?", options: "Postgres\nSQLite", rationale: "", base: { question: "Which database?", options: "Postgres\nSQLite", rationale: "" } });
  assert.equal(host.drafts.get(D), draft);
  // Asking again, even with a decision the server has since changed, gives the same draft back.
  assert.equal(draftFor(host, decision({ question: "Changed elsewhere" })), draft);
});

test("typed text survives a changed decision object", () => {
  const host = hostWith([decision()]);
  draftFor(host, decision());
  setDraft(host, D, { question: "Which data", options: "Postgres\nSQLite\nDuck" });
  setDraft(host, D, { rationale: "Half a thou" });
  const after = draftFor(host, decision({ question: "Someone else's question", rationale: "Theirs", options: [{ id: "a", label: "MySQL", note: null }, { id: "b", label: "SQLite", note: null }] }));
  assert.equal(after.question, "Which data");
  assert.equal(after.options, "Postgres\nSQLite\nDuck");
  assert.equal(after.rationale, "Half a thou");
  assert.equal(after.base.question, "Which database?");
});

test("draftDiffers flags a server-side change to what the form opened on, not your own typing", () => {
  const host = hostWith([decision()]);
  const draft = draftFor(host, decision());
  assert.equal(draftDiffers(draft, decision()), false);
  assert.equal(draftDiffers(setDraft(host, D, { question: "Mine" }), decision()), false);
  assert.equal(draftDiffers(host.drafts.get(D), decision({ question: "Theirs" })), true);
  assert.equal(draftDiffers(host.drafts.get(D), decision({ rationale: "Because" })), true);
  assert.equal(draftDiffers(host.drafts.get(D), decision({ options: [{ id: "a", label: "Postgres", note: null }, { id: "b", label: "DuckDB", note: null }] })), true);
  // Nothing about the text changed (a status pill, who proposed it): no note.
  assert.equal(draftDiffers(host.drafts.get(D), decision({ proposedAt: 2 })), false);
  assert.equal(draftDiffers(undefined, decision()), false);
  assert.equal(draftDiffers({ why: "typed", pick: "a" }, decision()), false);
});

test("Save and Cancel clear the edit draft, so the next Edit starts from the saved decision", () => {
  const host = hostWith([decision()]);
  draftFor(host, decision());
  setDraft(host, D, { question: "Mine" });
  clearDraft(host, D, "edit");
  assert.equal(host.drafts.has(D), false);
  assert.equal(draftFor(host, decision({ question: "Saved" })).question, "Saved");
});

test("the action row's why and pick are kept across Edit and Cancel, and cleared on Accept / Reject", () => {
  const host = hostWith([decision()]);
  setDraft(host, D, { why: "Cheaper" });
  setDraft(host, D, { pick: "b" });
  const draft = draftFor(host, decision()); // Edit: the form's fields join the same draft
  assert.equal(draft.why, "Cheaper");
  assert.equal(draft.pick, "b");
  assert.equal(draft.question, "Which database?");
  clearDraft(host, D, "edit"); // Cancel
  assert.deepEqual(host.drafts.get(D), { why: "Cheaper", pick: "b" });
  clearDraft(host, D); // Accept / Reject
  assert.equal(host.drafts.has(D), false);
  clearDraft(host, D); // nothing there: no throw
});

test("drafts are per decision and per editor, and a host without a store gets one", () => {
  const host: any = { decisions: () => [], tasks: () => [] };
  setDraft(host, D, { why: "x" });
  assert.equal(host.drafts.get(D).why, "x");
  assert.equal(host.drafts.has("other"), false);
  const other = hostWith([decision()]);
  assert.equal(other.drafts.has(D), false);
  assert.equal(setDraft(null, D, { why: "x" }), null);
});

test("cardKey is unchanged for cards not being edited: a draft doesn't redraw them, the feed still does", () => {
  const d = decision();
  const host = hostWith([d]);
  const before = cardKey(host, D);
  assert.equal(before, JSON.stringify([D, d, false, []]));
  setDraft(host, D, { why: "typing" });
  assert.equal(cardKey(host, D), before);
  assert.notEqual(cardKey(hostWith([decision({ question: "Changed" })]), D), before);
  const accepted = decision({ status: "accepted", chosen: "a" });
  const made = [{ id: "MF-1", state: "building", title: "Do it", fromDoc: { decision: D } }, { id: "MF-2", state: "building", title: "Other", fromDoc: { decision: "x" } }];
  assert.equal(cardKey(hostWith([accepted], made), D), JSON.stringify([D, accepted, false, [["MF-1", "building", "Do it"]]]));
  host.editing.add(D);
  assert.equal(cardKey(host, D), JSON.stringify([D, d, true, []]));
});

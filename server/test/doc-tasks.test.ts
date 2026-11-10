// MF-368: tasks from doc sections and decisions. The headless section reader and task-embed inserter, the pure
// split / compose / check module, and doc.makeTasks through the engine with a DocHub stand-in.
import { test } from "node:test";
import assert from "node:assert/strict";
import * as Y from "yjs";
import { DatabaseSync } from "node:sqlite";
import { Engine } from "../src/factory/engine.ts";
import { Store } from "../src/factory/store.ts";
import { plannerPrompt, builderPrompt } from "../src/factory/prompts.ts";
import { initProseMirrorDoc } from "@tiptap/y-tiptap";
import { schema } from "../docs-editor/src/schema.js";
import { splitSection, composeBrief, checkSource } from "../src/factory/doc-tasks.ts";
import type { Decision, Doc, Goal } from "../src/wire.ts";
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

const SECTION = "## Search\n\nMake search fast.\n\n### Indexing\n\nBuild the index.\n\n- shard it\n- [ ] keep it **warm**\n  for an hour\n\n### Ranking\n\nRank by recency.";

test("splitSection: one task, per sub-heading, per list item", () => {
  assert.deepEqual(splitSection(SECTION, "one"), [{ title: "Search", brief: SECTION }]);
  assert.deepEqual(splitSection(SECTION, "headings"), [
    { title: "Indexing", brief: "Build the index.\n\n- shard it\n- [ ] keep it **warm**\n  for an hour" },
    { title: "Ranking", brief: "Rank by recency." },
  ]);
  assert.deepEqual(splitSection(SECTION, "items"), [
    { title: "shard it", brief: "shard it" },
    { title: "keep it warm", brief: "keep it **warm**\nfor an hour" },
  ]);
  // Nothing to split: one task.
  assert.equal(splitSection("Just a paragraph.", "items").length, 1);
  assert.deepEqual(splitSection("", "one"), []);
});

test("composeBrief: the brief, then a line linking back to the doc (and the decision)", () => {
  const src = { doc: "d0c00000-0000-4000-8000-000000000000", docTitle: "Search plan", heading: "Indexing", decision: null };
  assert.equal(composeBrief({ brief: "Build it. " }, src), "Build it.\n\nFrom doc [Search plan › Indexing](#/docs/d0c00000-0000-4000-8000-000000000000).");
  assert.match(composeBrief({ brief: "x" }, { ...src, decision: "dec" }), /\(#\/docs\/d0c00000-0000-4000-8000-000000000000\?decision=dec\) \(a decision\)\.$/);
});

test("checkSource: refuses archived docs, no goal, unaccepted or foreign decisions, empty or oversized lists", () => {
  const doc = { id: "d1", title: "Plan", goal: "g1", archived: false } as Doc;
  const goal = { id: "g1", name: "Search", archived: false } as Goal;
  const accepted = { id: "x", doc: "d1", status: "accepted" } as Decision;
  const ok = { doc, goal, picked: false, decision: null, decisionAsked: false, tasks: [{ title: "A", brief: "b" }] };
  assert.equal(checkSource(ok), null);
  assert.equal(checkSource({ ...ok, decision: accepted, decisionAsked: true }), null);
  assert.match(checkSource({ ...ok, doc: { ...doc, archived: true } })!, /archived/);
  assert.match(checkSource({ ...ok, doc: { ...doc, goal: null }, goal: null })!, /no goal/);
  assert.equal(checkSource({ ...ok, doc: { ...doc, goal: null }, picked: true }), null);
  assert.match(checkSource({ ...ok, decision: { ...accepted, status: "proposed" }, decisionAsked: true })!, /accepted/);
  assert.match(checkSource({ ...ok, decision: { ...accepted, doc: "other" }, decisionAsked: true })!, /isn't in this doc/);
  assert.match(checkSource({ ...ok, tasks: [] })!, /at least one/);
  assert.match(checkSource({ ...ok, tasks: Array.from({ length: 21 }, () => ({ title: "A", brief: "b" })) })!, /At most 20/);
  assert.match(checkSource({ ...ok, tasks: [{ title: "x".repeat(121), brief: "b" }] })!, /title/);
  assert.match(checkSource({ ...ok, tasks: [{ title: "A", brief: "" }] })!, /brief/);
});

// ---------------------------------------------------------------------------------------------------------------
// doc.makeTasks through the engine, with a DocHub stand-in running the same headless code

function sqlStorage() {
  const db = new DatabaseSync(":memory:");
  return {
    exec(query: string, ...bindings: unknown[]) {
      const statements = query.split(";").map((s) => s.trim()).filter(Boolean);
      if (statements.length > 1) {
        db.exec(query);
        return { toArray: () => [], one: () => undefined };
      }
      const rows = db.prepare(query).all(...(bindings as never[]));
      return { toArray: () => rows, one: () => rows[0] };
    },
  } as unknown as SqlStorage;
}

const DOC = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const LOOSE = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const OLD = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
const DEC = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";

function factory() {
  const store = new Store(sqlStorage());
  const docs = new Map<string, Y.Doc>();
  const get = (id: string) => docs.get(id) ?? docs.set(id, new Y.Doc()).get(id)!;
  const DOC_NS = {
    idFromName: (id: string) => id,
    get: (id: string) => ({
      fetch: async (url: string, init: RequestInit) => {
        const path = new URL(url).pathname;
        const body = JSON.parse(String(init.body));
        try {
          if (path === "/read") return Response.json(readDoc(get(id), body.threads));
          if (path === "/anchor") return Response.json(anchorFor(get(id), body));
          if (path === "/section") return Response.json(sectionAt(get(id), body));
          if (path === "/insert-tasks") return Response.json(insertTaskEmbeds(get(id), body.ids, body));
          if (path === "/insert-decision") return Response.json(insertDecision(get(id), body.id, body));
          return new Response("Not found.", { status: 404 });
        } catch (e) {
          if (e instanceof DocToolError) return new Response(e.message, { status: 422 });
          throw e;
        }
      },
    }),
  };
  const broadcasts: any[] = [];
  const hooks = {
    broadcast: (m: any) => broadcasts.push(m), sendTo: () => {}, machines: async () => [], members: async () => [{ login: "ada" }],
    machineChanged: async () => {}, waitUntil: () => {}, wakeIn: () => {}, docMentions: () => {},
  };
  const engine = new Engine({ DOC: DOC_NS } as never, store, hooks as never, { forTask: () => {} } as never, {} as never);
  store.saveGoal({ id: "g", name: "Search", prefix: "SR", summary: "", lead: "ada", repos: [], repo: "acme/web", archived: false } as never);
  store.saveGoal({ id: "g2", name: "Other", prefix: "OT", summary: "", lead: "ada", repos: [], repo: "acme/web", archived: false } as never);
  for (const [id, title, goal, archived] of [[DOC, "Search plan", "g", false], [LOOSE, "Loose notes", null, false], [OLD, "Old plan", "g", true]] as const) {
    store.saveDoc({ id, title, goal, createdBy: "ada", createdAt: 1, updatedAt: 1, archived: archived || null } as never);
    seedDoc(get(id), PLAN);
  }
  const make = (msg: Record<string, unknown>) => engine.command({ type: "doc.makeTasks", chain: false, ...msg } as never, { member: { login: "ada", role: "member" } } as never);
  const heading = (id: string, text: string) => anchorFor(get(id), { block: readDoc(get(id)).blocks.find((b) => b.markdown === text)!.id });
  const drafts = () => store.tasks().filter((t) => t.goal === "g" || t.goal === "g2");
  return { store, engine, make, heading, drafts, ydoc: get(DOC), get, broadcasts };
}

test("doc.makeTasks: a heading's section, chained, makes drafts in the doc's goal with after, effort, fromDoc and a backlink, and embeds them", async () => {
  const f = factory();
  const items = splitSection(sectionAt(f.ydoc, { anchor: f.heading(DOC, "## Search") }).markdown, "headings");
  await f.make({ doc: DOC, anchor: f.heading(DOC, "## Search"), tasks: items, chain: true, effort: "Search" });
  const made = f.drafts().sort((a, b) => a.id.localeCompare(b.id));
  assert.deepEqual(made.map((t) => [t.id, t.title, t.state, t.goal, t.after, t.effort]), [
    ["SR-1", "Indexing", "drafting", "g", [], "Search"],
    ["SR-2", "Ranking", "drafting", "g", ["SR-1"], "Search"],
  ]);
  for (const t of made) {
    assert.equal(t.fromDoc?.doc, DOC);
    assert.equal(t.fromDoc?.docTitle, "Search plan");
    assert.equal(t.fromDoc?.heading, "Search");
    assert.match(t.fromDoc!.excerpt, /^## Search\n\nMake search fast\.[\s\S]*Rank by recency\.$/);
    assert.match(t.brief, new RegExp(`\\n\\nFrom doc \\[Search plan › Search\\]\\(#/docs/${DOC}\\)\\.$`));
    assert.match(t.events.at(-1)!.text, /made from doc Search plan › Search/);
  }
  const types = topTypes(f.ydoc);
  assert.deepEqual(types.slice(types.indexOf("Rank by recency."), types.indexOf("h:Billing") + 1), ["Rank by recency.", "task:SR-1", "task:SR-2", "h:Billing"]);
});

test("doc.makeTasks: an accepted decision is the source; its id is in fromDoc and the link", async () => {
  const f = factory();
  await f.engine.docs.propose("ada", { id: DEC, doc: DOC, question: "Which index?", options: [{ id: "a", label: "Postgres FTS" }, { id: "b", label: "Typesense" }], rationale: "" }, { agent: "SR-0 planner", quote: "Build the index." });
  await assert.rejects(f.make({ doc: DOC, decision: DEC, tasks: [{ title: "Set up Typesense", brief: "Do it." }] }), /accepted/);
  f.engine.docs.decideDecision("ada", { id: DEC, accept: true, chosen: "b", why: "Typo tolerance" });
  await f.make({ doc: DOC, decision: DEC, tasks: [{ title: "Set up Typesense", brief: "Do it." }] });
  const [t] = f.drafts();
  assert.equal(t.fromDoc?.decision, DEC);
  assert.equal(t.fromDoc?.heading, "Indexing");
  assert.match(t.brief, new RegExp(`\\(#/docs/${DOC}\\?decision=${DEC}\\) \\(a decision\\)\\.$`));
});

test("doc.makeTasks: bad sources make no tasks", async () => {
  const f = factory();
  const one = [{ title: "A", brief: "b" }];
  await assert.rejects(f.make({ doc: OLD, tasks: one }), /archived/);
  await assert.rejects(f.make({ doc: LOOSE, tasks: one }), /no goal/);
  await assert.rejects(f.make({ doc: DOC, decision: DEC, tasks: one }), /isn't in this doc/);
  await assert.rejects(f.make({ doc: DOC, tasks: Array.from({ length: 21 }, () => one[0]) }), /At most 20/);
  await assert.rejects(f.make({ doc: DOC, tasks: [] }), /at least one/);
  await assert.rejects(f.make({ doc: DOC, goal: "g2", tasks: one }), /already belongs/);
  assert.equal(f.drafts().length, 0);
  assert.ok(!topTypes(f.ydoc).some((t) => t.startsWith("task:")));
  // A doc with no goal takes the one picked.
  await f.make({ doc: LOOSE, goal: "g2", tasks: one });
  assert.deepEqual(f.drafts().map((t) => [t.id, t.goal, t.after, t.effort]), [["OT-1", "g2", [], null]]);
});

test("the planner's prompt carries the doc section and the decision's chosen option and rationale; the builder's just the link", async () => {
  const f = factory();
  await f.engine.docs.propose("ada", { id: DEC, doc: DOC, question: "Which index?", options: [{ id: "a", label: "Postgres FTS" }, { id: "b", label: "Typesense", note: "hosted" }], rationale: "Typo tolerance matters most." }, { agent: "SR-0 planner", quote: "Build the index." });
  f.engine.docs.decideDecision("ada", { id: DEC, accept: true, chosen: "b", why: null });
  await f.make({ doc: DOC, decision: DEC, tasks: [{ title: "Set up Typesense", brief: "Do it." }] });
  const [task] = f.drafts();
  const goal = f.store.goal("g")!;
  const p = plannerPrompt(task, goal, null, [], null, [], null, f.store.decision(DEC));
  assert.match(p, /## From doc\nThis task was made from "Search plan › Indexing"/);
  assert.match(p, /<doc-section>\n[\s\S]*<\/doc-section>/);
  assert.match(p, /Decision \(accepted\): Which index\?\nChosen: Typesense — hosted\nRationale: Typo tolerance matters most\./);
  assert.match(p, new RegExp(`read_doc \\{doc: "${DOC}"\\}`));
  // A heading's section is in the planner's prompt as it read when the task was made.
  await f.make({ doc: DOC, anchor: f.heading(DOC, "## Billing"), tasks: [{ title: "Bill", brief: "Charge." }] });
  const bill = f.drafts().find((t) => t.title === "Bill")!;
  assert.match(plannerPrompt(bill, goal), /<doc-section>\n## Billing\n\nCharge monthly\.\n<\/doc-section>/);
  const b = builderPrompt(task, goal, null);
  assert.match(b, /## From doc\nMade from "Search plan › Indexing" \(doc .*, decision .*\)\./);
  assert.doesNotMatch(b, /<doc-section>/);
});

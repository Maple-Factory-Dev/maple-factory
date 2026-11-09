// MF-365: agents' doc tools. The headless module (Markdown with stable block ids, anchors that resolve like the
// editor's, applying a suggestion), then the tools through the engine on a node:sqlite store with a DocHub stand-in
// that runs the same headless code: suggest → read_doc → accept → read_doc, a stale suggestion, and the guardrails.
import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import * as Y from "yjs";
import { initProseMirrorDoc } from "@tiptap/y-tiptap";
import { schema } from "../docs-editor/src/schema.js";
import { readDoc, anchorFor, applySuggestion, seedDoc, DocToolError } from "../docs-editor/src/headless.js";
import { resolveAnchor } from "../docs-editor/src/comments.js";
import { Engine } from "../src/factory/engine.ts";
import { Store } from "../src/factory/store.ts";
import { toolsFor, personalTools } from "../src/factory/tools.ts";
import type { DocThread } from "../src/wire.ts";

const MD = "# Launch plan\n\nWe ship on **Friday** and then celebrate.\n\n- write the notes\n- tag the release\n";

/** The text an anchor covers now, through the editor's own resolveAnchor. */
function covered(ydoc: Y.Doc, anchor: any) {
  const { doc, mapping } = initProseMirrorDoc(ydoc.getXmlFragment("prosemirror"), schema);
  const r = resolveAnchor(ydoc, mapping, anchor);
  return "orphan" in r ? null : { from: r.from, to: r.to, text: doc.textBetween(r.from, r.to) };
}

/** A collaborator types `text` just before `word` in the second block (its Y.XmlText, by plain-text index). */
function typeBefore(ydoc: Y.Doc, word: string, text: string) {
  const yt = (ydoc.getXmlFragment("prosemirror").get(1) as Y.XmlElement).get(0) as Y.XmlText;
  const plain = yt.toDelta().map((d: any) => (typeof d.insert === "string" ? d.insert : " ")).join("");
  yt.insert(plain.indexOf(word), text);
}

test("readDoc: Markdown with block markers, ids stable across an edit elsewhere", () => {
  const ydoc = seedDoc(new Y.Doc(), MD);
  const first = readDoc(ydoc);
  assert.equal(first.blocks.length, 3);
  assert.deepEqual(first.blocks.map((b) => b.markdown), ["# Launch plan", "We ship on **Friday** and then celebrate.", "- write the notes\n- tag the release"]);
  for (const b of first.blocks) assert.match(b.id!, /^b-[0-9a-z]+-\d+$/);
  assert.match(first.markdown, new RegExp(`<!-- block ${first.blocks[1].id} -->\\nWe ship on`));
  // Someone types in the heading: every block keeps its id.
  ((ydoc.getXmlFragment("prosemirror").get(0) as Y.XmlElement).get(0) as Y.XmlText).insert(0, "Big ");
  const after = readDoc(ydoc);
  assert.equal(after.blocks[0].markdown, "# Big Launch plan");
  assert.deepEqual(after.blocks.map((b) => b.id), first.blocks.map((b) => b.id));
});

test("anchorFor: a quote and a block resolve through comments.js; misses and repeats are refused", () => {
  const ydoc = seedDoc(new Y.Doc(), MD);
  const para = readDoc(ydoc).blocks[1].id!;
  const byQuote = anchorFor(ydoc, { quote: "We ship on Friday and then celebrate." });
  const byBlock = anchorFor(ydoc, { block: para });
  assert.deepEqual(covered(ydoc, byQuote), covered(ydoc, byBlock));
  assert.equal(covered(ydoc, anchorFor(ydoc, { quote: "Friday", block: para }))!.text, "Friday");
  assert.throws(() => anchorFor(ydoc, { quote: "Tuesday" }), DocToolError);
  assert.throws(() => anchorFor(ydoc, { quote: "e" }), /appears \d+ times/);
  assert.throws(() => anchorFor(ydoc, { block: "b-zz-999" }), /no block/);
});

test("applySuggestion changes only that span and refuses after a concurrent change", () => {
  const ydoc = seedDoc(new Y.Doc(), MD);
  const anchor = anchorFor(ydoc, { quote: "Friday" });
  applySuggestion(ydoc, anchor, "*Monday*");
  const md = readDoc(ydoc).blocks.map((b) => b.markdown);
  assert.equal(md[0], "# Launch plan");
  assert.equal(md[2], "- write the notes\n- tag the release");
  assert.match(md[1], /^We ship on .*Monday.* and then celebrate\.$/);
  assert.doesNotMatch(md[1], /Friday/);

  const stale = anchorFor(ydoc, { quote: "then celebrate" });
  // A collaborator edits the quoted words before anyone accepts.
  typeBefore(ydoc, "celebrate", "quietly ");
  assert.throws(() => applySuggestion(ydoc, stale, "go home"), /text changed/);
  assert.match(readDoc(ydoc).blocks[1].markdown, /then quietly celebrate/);
});

// ---------------------------------------------------------------------------------------------------------------
// Through the engine

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

const SESSION = "33333333-3333-4333-8333-333333333333";
const PERSONAL = "44444444-4444-4444-8444-444444444444";
const DOC = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const OTHER = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const ARCHIVED = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";

/** DocHub's /read, /anchor and /apply over in-memory Y.Docs, with the same headless code and 422s. */
function docHubs() {
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
          if (path === "/apply") return Response.json({ before: applySuggestion(get(id), body.anchor, body.markdown).before });
          return new Response("Not found.", { status: 404 });
        } catch (e) {
          if (e instanceof DocToolError) return new Response(e.message, { status: 422 });
          throw e;
        }
      },
    }),
  };
  return { DOC_NS, get };
}

function factory() {
  const store = new Store(sqlStorage());
  const broadcasts: { type: string; thread?: DocThread }[] = [];
  const mentions: DocThread[] = [];
  const hooks = {
    broadcast: (m: any) => broadcasts.push(m),
    sendTo: () => {},
    machines: async () => [{ id: "mac", name: "studio", owner: "owner", sessions: [] }],
    members: async () => [{ login: "owner" }, { login: "sam" }],
    machineChanged: async () => {},
    waitUntil: () => {},
    wakeIn: () => {},
    docMentions: (t: DocThread) => mentions.push(t),
  };
  const hubs = docHubs();
  const engine = new Engine({ DOC: hubs.DOC_NS } as never, store, hooks as never, { forTask: () => {} } as never, {} as never);
  store.saveGoal({ id: "g", name: "Apps", prefix: "MF", summary: "", lead: "owner", repos: [], repo: "acme/mac", archived: false } as never);
  store.saveTask({
    id: "MF-1", goal: "g", title: "Tidy the plan", state: "building", owner: "owner", brief: "", createdAt: 1, updatedAt: 1, plan: [], planVersion: 1, doneWhen: [],
    approvals: [], approvalsNeeded: 1, reviews: [], reviewsNeeded: 1, comments: [], changes: [], events: [], mockups: [], tickets: [],
    shareable: true, agent: "claude", model: "x", effort: "high", machine: "mac", repo: "acme/mac", branch: "agent/mf-1",
    worker: { role: "builder", agent: "claude", machine: "mac", session: SESSION, startedAt: 1 },
  } as never);
  store.addSession({ id: SESSION, task: "MF-1", role: "builder", machine: "mac", agent: "claude", started: 1, ended: null, cause: null, kind: "team" });
  for (const [id, title, archived] of [[DOC, "Launch plan", false], [OTHER, "Other", false], [ARCHIVED, "Old", true]] as const) {
    store.saveDoc({ id, title, goal: "g", createdBy: "owner", createdAt: 1, updatedAt: 1, archived: archived || null } as never);
    seedDoc(hubs.get(id), id === DOC ? MD : "Other text.\n");
  }
  const call = async (tool: string, args: Record<string, unknown>, session = SESSION, machine = "mac") =>
    (await engine.fromRunner(machine, { type: "mcp.request", reqId: "r", session, tool, args } as never)) as { result?: { summary: string; data: any }; error?: string };
  return { store, engine, call, broadcasts, mentions, ydoc: hubs.get(DOC) };
}

test("the six doc tools are listed for every role and for personal sessions", () => {
  const names = ["list_docs", "read_doc", "comment_on_doc", "reply_to_doc_thread", "resolve_doc_thread", "suggest_doc_edit"];
  for (const role of ["planner", "builder", "reviewer"] as const) for (const n of names) assert.ok(toolsFor(role).some((t) => t.name === n), `${role} ${n}`);
  for (const n of names) assert.ok(personalTools().some((t) => t.name === n), n);
  assert.match(toolsFor("builder").find((t) => t.name === "suggest_doc_edit")!.description, /can't edit a doc's text yourself/);
});

test("suggest → read_doc lists it → accept → read_doc shows the new text", async () => {
  const { store, engine, call, broadcasts, ydoc } = factory();
  const list = await call("list_docs", { limit: 50 });
  assert.deepEqual(list.result!.data.map((d: any) => d.title).sort(), ["Launch plan", "Other"]);

  const read = await call("read_doc", { doc: DOC });
  assert.equal(read.error, undefined);
  assert.match(read.result!.data, /<!-- block b-[0-9a-z]+-\d+ -->\nWe ship on \*\*Friday\*\*/);

  const s = await call("suggest_doc_edit", { doc: DOC, quote: "Friday", replacement: "Monday", note: "Friday is a freeze day @sam" });
  assert.equal(s.error, undefined, s.error);
  const id = s.result!.data.thread;
  const thread = store.thread(id)!;
  assert.deepEqual(thread.suggestion, { replacement: "Monday", status: "open", decidedBy: null, decidedAt: null });
  assert.equal(thread.createdBy, "MF-1");
  assert.equal(thread.comments[0].agent, "MF-1 builder");
  assert.deepEqual(thread.comments[0].mentions, ["sam"]);
  assert.ok(broadcasts.some((b) => b.type === "doc.thread.updated" && b.thread?.id === id));
  // The agent never touched the text.
  assert.match(readDoc(ydoc).markdown, /\*\*Friday\*\*/);

  const listed = await call("read_doc", { doc: DOC });
  assert.match(listed.result!.data, new RegExp(`suggestion ${id} on b-[0-9a-z]+-\\d+ "Friday": replace with "Monday"`));
  assert.equal((await call("resolve_doc_thread", { doc: DOC, thread: id })).error, "That's an open suggestion: a person accepts or rejects it in the editor.");

  const decided = await engine.docs.decide("owner", DOC, id, true);
  assert.equal(decided.suggestion!.status, "accepted");
  assert.equal(decided.resolved, true);
  assert.equal(decided.suggestion!.decidedBy, "owner");
  const after = await call("read_doc", { doc: DOC });
  assert.match(after.result!.data, /We ship on Monday and then celebrate\./);
  assert.doesNotMatch(after.result!.data, /suggestion /);
  await assert.rejects(engine.docs.decide("owner", DOC, id, true), /already accepted/);
});

test("comments and replies: on a quote, a block or the whole doc; reject leaves the text", async () => {
  const { store, engine, call, ydoc } = factory();
  const block = readDoc(ydoc).blocks[2].id;
  const onBlock = await call("comment_on_doc", { doc: DOC, block, text: "Add a changelog step?" });
  assert.equal(store.thread(onBlock.result!.data.thread)!.anchor!.quote, "write the notes tag the release");
  const whole = await call("comment_on_doc", { doc: DOC, text: "Looks good overall." });
  assert.equal(store.thread(whole.result!.data.thread)!.anchor ?? null, null);
  const reply = await call("reply_to_doc_thread", { doc: DOC, thread: whole.result!.data.thread, text: "One more pass." });
  assert.equal(store.thread(reply.result!.data.thread)!.comments.length, 2);
  assert.equal((await call("resolve_doc_thread", { doc: DOC, thread: whole.result!.data.thread })).error, undefined);
  assert.equal(store.thread(whole.result!.data.thread)!.resolved, true);

  const s = await call("suggest_doc_edit", { doc: DOC, quote: "then celebrate", replacement: "go home" });
  const rejected = await engine.docs.decide("owner", DOC, s.result!.data.thread, false);
  assert.equal(rejected.suggestion!.status, "rejected");
  assert.match(readDoc(ydoc).markdown, /then celebrate/);
});

test("a stale suggestion's accept is refused and the thread stays open", async () => {
  const { store, engine, call, ydoc } = factory();
  const s = await call("suggest_doc_edit", { doc: DOC, quote: "then celebrate", replacement: "go home" });
  typeBefore(ydoc, "celebrate", "quietly ");
  await assert.rejects(engine.docs.decide("owner", DOC, s.result!.data.thread, true), /text changed/);
  const t = store.thread(s.result!.data.thread)!;
  assert.equal(t.suggestion!.status, "open");
  assert.equal(t.resolved ?? null, null);
});

test("guardrails: unknown, archived and other-doc ids, bad anchors, and sessions that aren't the factory's", async () => {
  const { call } = factory();
  assert.match((await call("read_doc", { doc: "dddddddd-dddd-4ddd-8ddd-dddddddddddd" })).error!, /no doc .* in this factory/);
  assert.match((await call("read_doc", { doc: ARCHIVED })).error!, /archived/);
  assert.match((await call("comment_on_doc", { doc: ARCHIVED, text: "hi" })).error!, /archived/);
  const other = await call("comment_on_doc", { doc: OTHER, text: "On the other doc." });
  assert.match((await call("reply_to_doc_thread", { doc: DOC, thread: other.result!.data.thread, text: "x" })).error!, /no thread .* on "Launch plan"/);
  assert.match((await call("resolve_doc_thread", { doc: DOC, thread: other.result!.data.thread })).error!, /no thread/);
  assert.match((await call("suggest_doc_edit", { doc: DOC, quote: "Tuesday", replacement: "x" })).error!, /isn't in the doc/);
  assert.match((await call("suggest_doc_edit", { doc: DOC, replacement: "x" })).error!, /block or the exact quote/);
  assert.match((await call("suggest_doc_edit", { doc: DOC, quote: "Friday", replacement: "x".repeat(10_001) })).error!, /at most 10000/);
  assert.ok(!(await call("list_docs", {})).result!.data.some((d: any) => d.id === ARCHIVED));
  // A personal session on a member's machine gets them (as the machine's owner); a session on no known machine doesn't.
  const mine = await call("comment_on_doc", { doc: DOC, text: "From my own session." }, PERSONAL, "mac");
  assert.equal(mine.error, undefined, mine.error);
  assert.equal((await call("read_doc", { doc: DOC }, PERSONAL, "nowhere")).error, "This session isn't working on a factory task.");
});

test("anchors over 2,000 characters are refused up front; one just under applies", async () => {
  const { addComment } = await import("../src/factory/doc-threads.ts");
  const long = "a".repeat(2250);
  const ydoc = seedDoc(new Y.Doc(), `${long}\n\n${"b".repeat(1990)}\n`);
  const [big, ok] = readDoc(ydoc).blocks.map((b) => b.id!);
  assert.throws(() => anchorFor(ydoc, { block: big }), /over 2000 characters/);
  assert.throws(() => anchorFor(ydoc, { quote: long }), /over 2000 characters/);
  const anchor = anchorFor(ydoc, { block: ok });
  assert.equal(anchor.quote.length, 1990);
  applySuggestion(ydoc, anchor, "short");
  assert.equal(readDoc(ydoc).blocks[1].markdown, "short");

  // A reply on a decided suggestion keeps it resolved (the rail offers no Resolve for it); on others it reopens.
  const decided = { id: "t", doc: DOC, anchor: null, comments: [], resolved: true, resolvedBy: "sam", resolvedAt: 1, createdBy: "x", createdAt: 1, suggestion: { replacement: "y", status: "accepted", decidedBy: "sam", decidedAt: 1 } } as unknown as DocThread;
  assert.equal(addComment(decided, "owner", "thanks", []).resolved, true);
  assert.equal(addComment({ ...decided, suggestion: undefined } as DocThread, "owner", "hm", []).resolved, null);
});

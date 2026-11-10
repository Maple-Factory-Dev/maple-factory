// MF-367: doc decisions. The pure lifecycle (propose → accept / reject, illegal moves, supersede, fold), the
// append-only decision_log (its triggers refuse UPDATE and DELETE), the member paths OrgHub's decision.* messages
// call (engine.docs: one log event each, `by` = the member), and agents' propose_decision (stays proposed with
// `agent` set, the embed inserted through DocHub; no accept or reject tool).
import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import * as Y from "yjs";
import { readDoc, anchorFor, applySuggestion, insertDecision, seedDoc, DocToolError } from "../docs-editor/src/headless.js";
import { schema } from "../docs-editor/src/schema.js";
import { fromMarkdown, toMarkdown } from "../docs-editor/src/markdown.js";
import { Engine } from "../src/factory/engine.ts";
import { Store } from "../src/factory/store.ts";
import { toolsFor, personalTools } from "../src/factory/tools.ts";
import * as decisions from "../src/factory/decisions.ts";
import type { Decision, DocThread } from "../src/wire.ts";

const MD = "# Launch plan\n\nWe ship on **Friday** and then celebrate.\n\n- write the notes\n- tag the release\n";
const OPTS = [{ id: "a", label: "Postgres" }, { id: "b", label: "SQLite" }];
const D1 = "11111111-1111-4111-8111-111111111111";
const D2 = "22222222-2222-4222-8222-222222222222";
const ok = <T,>(r: T | { error: string }): T => { assert.ok(!(r && typeof r === "object" && "error" in r), (r as any)?.error); return r as T; };

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
          if (path === "/insert-decision") return Response.json(insertDecision(get(id), body.id, body));
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
  const broadcasts: any[] = [];
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


// ---------------------------------------------------------------------------------------------------------------
// The pure lifecycle

test("propose → accept records who, when and an optional why", () => {
  const p = ok(decisions.propose(D1, "doc", { question: " Which database? ", options: OPTS, rationale: "Ops cost" }, "ada", { goal: "g", at: 10 }));
  assert.equal(p.decision.status, "proposed");
  assert.equal(p.decision.question, "Which database?");
  assert.equal(p.event.action, "proposed");
  assert.equal(p.event.by, "ada");
  const [acc] = ok(decisions.accept(p.decision, "grace", { chosen: "b", why: "One file, no server", at: 20 }));
  assert.deepEqual([acc.decision.status, acc.decision.chosen, acc.decision.decidedBy, acc.decision.decidedAt, acc.decision.why], ["accepted", "b", "grace", 20, "One file, no server"]);
  assert.deepEqual([acc.event.action, acc.event.by, acc.event.why], ["accepted", "grace", "One file, no server"]);
  assert.deepEqual(acc.event.before, p.decision);
  // Why is optional.
  const [plain] = ok(decisions.accept(p.decision, "grace", { chosen: "a" }));
  assert.equal(plain.decision.why, null);
});

test("propose → reject", () => {
  const p = ok(decisions.propose(D1, "doc", { question: "Q", options: OPTS }, "ada"));
  const r = ok(decisions.reject(p.decision, "grace", { why: "Not now", at: 5 }));
  assert.deepEqual([r.decision.status, r.decision.decidedBy, r.decision.why, r.event.action], ["rejected", "grace", "Not now", "rejected"]);
});

test("illegal moves are refused", () => {
  const p = ok(decisions.propose(D1, "doc", { question: "Q", options: OPTS }, "ada")).decision;
  // Accepting without a chosen option.
  assert.match((decisions.accept(p, "grace", {}) as any).error, /chosen option/);
  assert.match((decisions.accept(p, "grace", { chosen: "zzz" }) as any).error, /isn't one of the options/);
  const [acc] = ok(decisions.accept(p, "grace", { chosen: "a" }));
  // Accepting twice, rejecting after, editing after a decision.
  assert.match((decisions.accept(acc.decision, "grace", { chosen: "a" }) as any).error, /already accepted/);
  assert.match((decisions.reject(acc.decision, "grace") as any).error, /already accepted/);
  assert.match((decisions.edit(acc.decision, { question: "Q2", options: OPTS }, "ada") as any).error, /can't be edited/);
  // Deciding a superseded one.
  const superseded: Decision = { ...acc.decision, status: "superseded", supersededBy: D2 };
  assert.match((decisions.accept(superseded, "grace", { chosen: "a" }) as any).error, /already superseded/);
  assert.match((decisions.reject(superseded, "grace") as any).error, /already superseded/);
  // Validation.
  assert.match((decisions.propose(D1, "doc", { question: "", options: OPTS }, "ada") as any).error, /question/);
  assert.match((decisions.propose(D1, "doc", { question: "x".repeat(501), options: OPTS }, "ada") as any).error, /500/);
  assert.match((decisions.propose(D1, "doc", { question: "Q", options: [OPTS[0]] }, "ada") as any).error, /2 to 10/);
  assert.match((decisions.propose(D1, "doc", { question: "Q", options: Array.from({ length: 11 }, (_, i) => ({ id: `o${i}`, label: `${i}` })) }, "ada") as any).error, /2 to 10/);
  assert.match((decisions.propose(D1, "doc", { question: "Q", options: OPTS, rationale: "x".repeat(10_001) }, "ada") as any).error, /10000/);
  assert.match((decisions.propose(D1, "doc", { question: "Q", options: OPTS, chosen: "c" }, "ada") as any).error, /isn't one of/);
  // Editing while proposed is fine.
  assert.equal(ok(decisions.edit(p, { question: "Q2", options: OPTS, chosen: "b" }, "ada")).decision.question, "Q2");
});

test("supersede: accepting B with supersedes A makes A superseded with supersededBy B; superseded is final", () => {
  const a = ok(decisions.accept(ok(decisions.propose(D1, "doc", { question: "Q", options: OPTS }, "ada")).decision, "grace", { chosen: "a" }) as any)[0].decision as Decision;
  const b = ok(decisions.propose(D2, "doc", { question: "Q again", options: OPTS, supersedes: D1 }, "ada")).decision;
  assert.match((decisions.accept(b, "grace", { chosen: "b" }, null) as any).error, /gone/);
  const changes = ok(decisions.accept(b, "grace", { chosen: "b" }, a));
  assert.equal(changes.length, 2);
  assert.deepEqual([changes[0].decision.id, changes[0].decision.status], [D2, "accepted"]);
  assert.deepEqual([changes[1].decision.id, changes[1].decision.status, changes[1].decision.supersededBy, changes[1].event.action], [D1, "superseded", D2, "superseded"]);
  // Superseding a decision that isn't accepted is refused.
  const rejected: Decision = { ...a, status: "rejected" };
  assert.match((decisions.accept(b, "grace", { chosen: "b" }, rejected) as any).error, /rejected, not accepted/);
});

// ---------------------------------------------------------------------------------------------------------------
// The store and its append-only log

test("decision_log refuses UPDATE and DELETE; fold(decisionLog(id)) equals the stored row", () => {
  const store = new Store(sqlStorage());
  const p = ok(decisions.propose(D1, "doc", { question: "Q", options: OPTS }, "ada"));
  store.recordDecision(p.decision, p.event);
  const e = ok(decisions.edit(p.decision, { question: "Q (edited)", options: OPTS, chosen: "a" }, "ada"));
  store.recordDecision(e.decision, e.event);
  const [acc] = ok(decisions.accept(e.decision, "grace", { why: "fine" }));
  const logged = store.recordDecision(acc.decision, acc.event);
  assert.equal(logged.seq, 3);
  const log = store.decisionLog(D1);
  assert.deepEqual(log.map((x) => [x.seq, x.action, x.by]), [[1, "proposed", "ada"], [2, "edited", "ada"], [3, "accepted", "grace"]]);
  assert.deepEqual(decisions.fold(log), store.decision(D1));
  assert.equal(store.decision(D1)!.status, "accepted");

  // Raw SQL can't rewrite or drop history.
  const sql = (store as any).sql as SqlStorage;
  assert.throws(() => sql.exec("UPDATE decision_log SET by = 'mallory' WHERE seq = 3"), /append-only/);
  assert.throws(() => sql.exec("DELETE FROM decision_log WHERE seq = 1"), /append-only/);
  assert.throws(() => sql.exec("DELETE FROM decision_log"), /append-only/);
  assert.equal(store.decisionLog(D1).length, 3);
  assert.equal(store.decisionLog(D1)[2].by, "grace");

  // A log whose entries don't follow each other doesn't fold.
  assert.throws(() => decisions.fold([log[0], log[2]]), /doesn't follow/);
});

// ---------------------------------------------------------------------------------------------------------------
// The member paths (what OrgHub's decision.* messages call) and the agents' tool

test("each decision.* path adds exactly one event with by = the member; the doc's open count follows", async () => {
  const { store, engine, broadcasts } = factory();
  const count = () => store.decisionLog(D1).length;
  await engine.docs.propose("ada", { id: D1, doc: DOC, question: "Which db?", options: OPTS, rationale: "" });
  assert.equal(count(), 1);
  assert.equal(store.doc(DOC)!.openDecisions, 1);
  assert.ok(broadcasts.some((b) => b.type === "decision.updated" && b.decision.id === D1));
  assert.ok(broadcasts.some((b) => b.type === "doc.updated" && b.doc.openDecisions === 1));
  await assert.rejects(engine.docs.propose("ada", { id: D1, doc: DOC, question: "dup", options: OPTS, rationale: "" }), /already a decision/);
  await assert.rejects(engine.docs.propose("ada", { id: D2, doc: ARCHIVED, question: "Q", options: OPTS, rationale: "" }), /archived/);
  engine.docs.editDecision("sam", { id: D1, question: "Which database?", options: OPTS, chosen: "b", rationale: "Small" });
  assert.equal(count(), 2);
  engine.docs.decideDecision("grace", { id: D1, accept: true, why: "One file" });
  assert.equal(count(), 3);
  assert.throws(() => engine.docs.decideDecision("grace", { id: D1, accept: false }), /already accepted/);
  assert.equal(count(), 3, "a refused move logs nothing");
  assert.deepEqual(store.decisionLog(D1).map((e) => [e.action, e.by]), [["proposed", "ada"], ["edited", "sam"], ["accepted", "grace"]]);
  assert.equal(store.doc(DOC)!.openDecisions, null);
  assert.deepEqual(decisions.fold(store.decisionLog(D1)), store.decision(D1));

  // Supersede through the same paths: one event on each decision.
  await engine.docs.propose("ada", { id: D2, doc: DOC, question: "Which database, now?", options: OPTS, rationale: "", supersedes: D1 });
  engine.docs.decideDecision("grace", { id: D2, accept: true, chosen: "a" });
  assert.deepEqual(store.decisionLog(D2).map((e) => [e.action, e.by]), [["proposed", "ada"], ["accepted", "grace"]]);
  assert.deepEqual(store.decisionLog(D1).map((e) => e.action), ["proposed", "edited", "accepted", "superseded"]);
  assert.deepEqual([store.decision(D1)!.status, store.decision(D1)!.supersededBy], ["superseded", D2]);
  assert.deepEqual(decisions.fold(store.decisionLog(D1)), store.decision(D1));
});

test("propose_decision from an agent stays proposed with agent set and inserts the embed through DocHub", async () => {
  const { store, call, ydoc } = factory();
  const para = readDoc(ydoc).blocks[1].id!;
  const r = await call("propose_decision", { doc: DOC, question: "Ship Friday?", options: [{ label: "Yes" }, { label: "No", note: "freeze" }], chosen: "No", rationale: "Freeze day", block: para });
  assert.equal(r.error, undefined, r.error);
  const id = r.result!.data.decision;
  const d = store.decision(id)!;
  assert.deepEqual([d.status, d.agent, d.proposedBy, d.chosen, d.goal], ["proposed", "MF-1 builder", "MF-1", "o2", "g"]);
  assert.deepEqual(store.decisionLog(id).map((e) => [e.action, e.agent]), [["proposed", "MF-1 builder"]]);
  // The embed sits right after the anchored paragraph.
  const md = toMarkdown(fromMarkdown(schema, readDoc(ydoc).markdown.replace(/<!-- block [^>]+ -->\n/g, "")), { decisions: (x: string) => store.decision(x) ?? undefined });
  assert.match(md, new RegExp(`celebrate\\.\\n\\n> \\[!DECISION\\] ${id} · Ship Friday\\? · proposed\\n`));
  // read_doc lists it.
  assert.match((await call("read_doc", { doc: DOC })).result!.data, new RegExp(`decision ${id} \\[proposed\\] "Ship Friday\\?"`));
  // No accept / reject tool for any agent.
  for (const tools of [toolsFor("planner"), toolsFor("builder"), toolsFor("reviewer"), personalTools()]) {
    assert.ok(tools.some((t) => t.name === "propose_decision"));
    assert.ok(!tools.some((t) => /accept|reject|decide/.test(t.name) && /decision/.test(t.name)), tools.map((t) => t.name).join());
  }
  // At the end when there's no anchor.
  const r2 = await call("propose_decision", { doc: DOC, question: "Tag it?", options: ["Yes", "No"], rationale: "" });
  const last = readDoc(ydoc).blocks.at(-1)!.markdown;
  assert.match(last, new RegExp(`\\[!DECISION\\] ${r2.result!.data.decision}`));
});

test("decision embeds round-trip through Markdown by id", () => {
  const md = `Text\n\n> [!DECISION] ${D1} · Which db? · accepted → SQLite\n`;
  const doc = fromMarkdown(schema, md);
  assert.equal(doc.child(1).type.name, "decision");
  assert.equal(doc.child(1).attrs.id, D1);
  assert.equal(toMarkdown(doc), `Text\n\n> [!DECISION] ${D1}\n`);
  const y = seedDoc(new Y.Doc(), "Only text.\n");
  insertDecision(y, D2);
  assert.throws(() => insertDecision(y, D2), /already in this doc/);
});

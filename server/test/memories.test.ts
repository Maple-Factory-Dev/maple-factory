// MF-391: shared agent memory. The store (memories + the FTS5 index + the append-only memory_log, over
// node:sqlite), the pure validation, the Memories module's deltas, and OrgHub's snapshot (active memories only).
import { test } from "node:test";
import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { DatabaseSync } from "node:sqlite";
import { Store, ftsQuery } from "../src/factory/store.ts";
import { Memories, normalize, MAX_TEXT } from "../src/factory/memories.ts";
import type { MemoryInput } from "../src/factory/memories.ts";
import type { Memory, ServerToClient } from "../src/wire.ts";

registerHooks({
  resolve(specifier, context, next) {
    if (specifier === "cloudflare:workers") return { url: "stub:cloudflare-workers", shortCircuit: true };
    return next(specifier, context);
  },
  load(url, context, next) {
    if (url === "stub:cloudflare-workers") {
      return { format: "module", shortCircuit: true, source: "export class DurableObject { constructor(ctx, env) { this.ctx = ctx; this.env = env } }" };
    }
    if (url.endsWith(".json")) return next(url, { ...context, importAttributes: { type: "json" } });
    return next(url, context);
  },
});

function sqlStorage(db = new DatabaseSync(":memory:")) {
  return {
    db,
    exec(query: string, ...bindings: unknown[]) {
      const statements = query.split(";").map((s) => s.trim()).filter(Boolean);
      if (statements.length > 1) {
        db.exec(query);
        return { toArray: () => [], one: () => undefined, [Symbol.iterator]: () => [][Symbol.iterator]() };
      }
      const rows = db.prepare(query).all(...(bindings as never[]));
      return { toArray: () => rows, one: () => rows[0], [Symbol.iterator]: () => rows[Symbol.iterator]() };
    },
  };
}

const id = (n: number) => `${String(n).repeat(8)}-${String(n).repeat(4)}-4${String(n).repeat(3)}-8${String(n).repeat(3)}-${String(n).repeat(12)}`;
const ORG = { kind: "org" as const, key: null };
const REPO = { kind: "repo" as const, key: "acme/web" };
const OTHER_REPO = { kind: "repo" as const, key: "acme/api" };
const GOAL = { kind: "goal" as const, key: "g1" };
const input = (over: Partial<MemoryInput> = {}): MemoryInput => ({
  scope: ORG, kind: "fact", text: "The server runs on Cloudflare Workers.", tags: [], source: { by: "ann" }, ...over,
});
const ok = <T,>(r: T | { error: string }): T => { assert.ok(!(r && typeof r === "object" && "error" in r), (r as { error?: string })?.error); return r as T; };
const refused = (r: unknown): string => { assert.ok(r && typeof r === "object" && "error" in r, "expected a refusal"); return (r as { error: string }).error; };

function setup() {
  const sql = sqlStorage();
  const store = new Store(sql as unknown as SqlStorage);
  const sent: ServerToClient[] = [];
  const memories = new Memories(store, { broadcast: (m) => sent.push(m) });
  const said = () => sent.splice(0);
  const ftsRows = (mem: string) => sql.db.prepare("SELECT COUNT(*) AS n FROM memories_fts WHERE id = ?").get(mem)!.n as number;
  return { db: sql.db, store, memories, said, ftsRows };
}

const ids = (list: Memory[]) => list.map((m) => m.id);

test("create, read, edit, archive and delete a memory; each sends the right delta", () => {
  const { store, memories, said, ftsRows } = setup();
  const made = ok(memories.create(id(1).toUpperCase(), input({
    scope: REPO, kind: "gotcha", text: "  Run npm run gen after editing protocol/schema.ts.  ", tags: ["Protocol", " wire ", "protocol"],
    source: { by: "ann", task: "MF-391", role: "builder", agent: "MF-391 builder", machine: "dev-mac" },
  }), { at: 100 }));
  assert.deepEqual(made, {
    id: id(1), scope: REPO, kind: "gotcha", text: "Run npm run gen after editing protocol/schema.ts.", tags: ["protocol", "wire"], status: "active",
    source: { by: "ann", task: "MF-391", role: "builder", agent: "MF-391 builder", machine: "dev-mac", decision: null },
    supersedes: null, createdAt: 100, updatedAt: 100, lastUsedAt: null, uses: 0,
  });
  assert.deepEqual(store.memory(id(1)), made, "round trip");
  assert.deepEqual(said(), [{ type: "memory.updated", memory: made }]);
  assert.equal(refused(memories.create(id(1), input())), "That memory is already there.");

  const edited = ok(memories.edit(id(1), { text: "Run `npm run gen` after any change to protocol/schema.ts.", tags: ["protocol"] }, "bob", { at: 200 }));
  assert.equal(edited.text, "Run `npm run gen` after any change to protocol/schema.ts.");
  assert.deepEqual(edited.tags, ["protocol"]);
  assert.equal(edited.kind, "gotcha", "what's left out stays");
  assert.equal(edited.createdAt, 100);
  assert.equal(edited.updatedAt, 200);
  assert.deepEqual(store.memory(id(1)), edited);
  assert.deepEqual(said(), [{ type: "memory.updated", memory: edited }]);
  // An edit that changes nothing saves nothing.
  assert.deepEqual(ok(memories.edit(id(1), { text: edited.text }, "bob", { at: 250 })), edited);
  assert.deepEqual(said(), []);
  assert.equal(store.memoryLog(id(1)).length, 2);

  const archived = ok(memories.setStatus(id(1), "archived", "bob", { at: 300 }));
  assert.equal(archived.status, "archived");
  assert.deepEqual(said(), [{ type: "memory.updated", memory: archived }], "archiving is a status change, not a removal");
  assert.deepEqual(store.activeMemories(), []);
  assert.deepEqual(ids(store.memories()), [id(1)]);
  assert.deepEqual(ids(store.memories({ status: "archived", scope: REPO })), [id(1)]);
  assert.deepEqual(store.memories({ scope: ORG }), []);

  assert.equal(ftsRows(id(1)), 1);
  assert.deepEqual(ok(memories.remove(id(1), "ann", { at: 400 })), { id: id(1) });
  assert.deepEqual(said(), [{ type: "memory.removed", id: id(1) }]);
  assert.equal(store.memory(id(1)), null);
  assert.equal(ftsRows(id(1)), 0, "delete clears the FTS row");
  assert.deepEqual(store.searchMemories({ query: "protocol", status: "archived" }), []);
  assert.equal(refused(memories.remove(id(1), "ann")), "That memory isn't there any more.");
  assert.equal(refused(memories.edit(id(1), { text: "x" }, "ann")), "That memory isn't there any more.");
  assert.equal(refused(memories.setStatus(id(1), "active", "ann")), "That memory isn't there any more.");
  assert.deepEqual(said(), [], "a refusal sends nothing");
});

test("validation: empty or over-long text, bad scopes, enums, tags and sources are refused", () => {
  const { store, memories, said } = setup();
  assert.equal(refused(normalize(input({ text: "   " }))), "A memory needs some text.");
  assert.equal(refused(normalize(input({ text: "x".repeat(MAX_TEXT + 1) }))), "A memory is at most 600 characters.");
  assert.equal(ok(normalize(input({ text: ` ${"x".repeat(MAX_TEXT)} ` }))).text.length, 600, "600 after trimming is fine");
  assert.match(refused(normalize(input({ scope: { kind: "repo", key: null } }))), /owner\/name/);
  assert.match(refused(normalize(input({ scope: { kind: "repo", key: "web" } }))), /owner\/name/);
  assert.match(refused(normalize(input({ scope: { kind: "goal", key: " " } }))), /goal's id/);
  assert.match(refused(normalize(input({ scope: { kind: "org", key: "acme/web" } }))), /no scope key/);
  assert.match(refused(normalize(input({ scope: { kind: "team" as never, key: "x" } }))), /scope is the org/);
  assert.match(refused(normalize(input({ kind: "rumour" as never }))), /fact, a convention/);
  assert.match(refused(normalize(input({ tags: Array.from({ length: 9 }, (_, i) => `t${i}`) }))), /at most 8 tags/);
  assert.match(refused(normalize(input({ tags: ["x".repeat(33)] }))), /at most 32 characters/);
  assert.match(refused(normalize(input({ tags: "wire" as never }))), /list of words/);
  assert.deepEqual(ok(normalize(input({ tags: ["Two Words", "two  words", "", "B"] }))).tags, ["two-words", "b"]);
  assert.deepEqual(ok(normalize(input({ scope: { kind: "org", key: "" } }))).scope, ORG);

  assert.equal(refused(memories.create("nope", input())), "A memory needs an id.");
  assert.equal(refused(memories.create(id(1), input({ text: "x".repeat(601) }))), "A memory is at most 600 characters.");
  assert.match(refused(memories.create(id(1), input({ source: { by: " " } }))), /who it came from/);
  assert.match(refused(memories.create(id(1), input({ source: { by: "ann", decision: "nope" } }))), /decision isn't an id/);
  assert.match(refused(memories.create(id(1), input({ status: "deleted" as never }))), /active, proposed or archived/);
  assert.match(refused(memories.create(id(1), input({ supersedes: id(1) }))), /can't supersede itself/);
  assert.match(refused(memories.create(id(1), input({ supersedes: id(2) }))), /supersedes isn't there/);
  assert.deepEqual(store.memories(), [], "nothing refused was saved");
  ok(memories.create(id(1), input()));
  said();
  assert.equal(refused(memories.edit(id(1), { text: "x".repeat(601) }, "bob")), "A memory is at most 600 characters.");
  assert.match(refused(memories.edit(id(1), { scope: { kind: "repo", key: "" } }, "bob")), /owner\/name/);
  assert.match(refused(memories.setStatus(id(1), "gone" as never, "bob")), /active, proposed or archived/);
  assert.equal(store.memoryLog(id(1)).length, 1);
  assert.deepEqual(said(), []);
});

test("search: by scope, by query, by both, on tags, with stemming, and by status", () => {
  const { store, memories } = setup();
  ok(memories.create(id(1), input({ scope: ORG, text: "Deploys go out with wrangler from main.", tags: ["release"] }), { at: 1 }));
  ok(memories.create(id(2), input({ scope: REPO, text: "The web app is deployed by the release script.", tags: ["release", "ci"] }), { at: 2 }));
  ok(memories.create(id(3), input({ scope: OTHER_REPO, text: "Migrations run before the API starts.", tags: ["database"] }), { at: 3 }));
  ok(memories.create(id(4), input({ scope: GOAL, text: "This goal's tickets live in Linear.", tags: [] }), { at: 4 }));
  ok(memories.create(id(5), input({ scope: REPO, text: "Maybe deploy on Fridays?", status: "proposed" }), { at: 5 }));

  // By scope alone: the newest first.
  assert.deepEqual(ids(store.searchMemories({ scopes: [REPO] })), [id(2)]);
  assert.deepEqual(ids(store.searchMemories({ scopes: [ORG, REPO, GOAL] })), [id(4), id(2), id(1)]);
  assert.deepEqual(ids(store.searchMemories({})), [id(4), id(3), id(2), id(1)], "every scope, active only");
  assert.deepEqual(ids(store.searchMemories({ scopes: [] })), []);
  assert.deepEqual(ids(store.searchMemories({ scopes: [{ kind: "repo", key: "acme/none" }] })), []);
  assert.deepEqual(ids(store.searchMemories({ limit: 2 })), [id(4), id(3)]);
  // By query alone, with stemming: "deploying" finds "Deploys" and "deployed".
  assert.deepEqual(ids(store.searchMemories({ query: "deploying" })).sort(), [id(1), id(2)]);
  assert.deepEqual(ids(store.searchMemories({ query: "migration" })), [id(3)]);
  assert.deepEqual(ids(store.searchMemories({ query: "migr" })), [id(3)], "a prefix matches");
  assert.deepEqual(ids(store.searchMemories({ query: "kubernetes" })), []);
  // Every word must match, unless `any`.
  assert.deepEqual(ids(store.searchMemories({ query: "deploy wrangler" })), [id(1)]);
  assert.deepEqual(ids(store.searchMemories({ query: "wrangler migrations" })), []);
  assert.deepEqual(ids(store.searchMemories({ query: "wrangler migrations", any: true })).sort(), [id(1), id(3)]);
  // By both.
  assert.deepEqual(ids(store.searchMemories({ scopes: [REPO], query: "deploy" })), [id(2)]);
  assert.deepEqual(ids(store.searchMemories({ scopes: [ORG], query: "deploy" })), [id(1)]);
  assert.deepEqual(ids(store.searchMemories({ scopes: [OTHER_REPO, GOAL], query: "deploy" })), []);
  // On tags.
  assert.deepEqual(ids(store.searchMemories({ query: "release" })).sort(), [id(1), id(2)]);
  assert.deepEqual(ids(store.searchMemories({ query: "ci" })), [id(2)]);
  assert.deepEqual(ids(store.searchMemories({ query: "database", scopes: [OTHER_REPO] })), [id(3)]);
  // Best match first: the one that says it most.
  ok(memories.create(id(6), input({ scope: ORG, text: "Linear, Linear, Linear: every ticket is in Linear.", tags: ["linear"] }), { at: 6 }));
  assert.deepEqual(ids(store.searchMemories({ query: "linear" })), [id(6), id(4)]);
  // Status: active unless asked.
  assert.deepEqual(ids(store.searchMemories({ query: "fridays" })), []);
  assert.deepEqual(ids(store.searchMemories({ query: "fridays", status: "proposed" })), [id(5)]);
  // An edit re-indexes: the old words stop matching, the new ones start.
  ok(memories.edit(id(3), { text: "Schema changes run before the API starts.", tags: ["sql"] }, "bob", { at: 7 }));
  assert.deepEqual(ids(store.searchMemories({ query: "migrations" })), []);
  assert.deepEqual(ids(store.searchMemories({ query: "database" })), []);
  assert.deepEqual(ids(store.searchMemories({ query: "schema sql" })), [id(3)]);
  // Archived memories drop out of the default search.
  ok(memories.setStatus(id(1), "archived", "bob", { at: 8 }));
  assert.deepEqual(ids(store.searchMemories({ query: "wrangler" })), []);
  assert.deepEqual(ids(store.searchMemories({ query: "wrangler", status: "archived" })), [id(1)]);
});

test("search: FTS5 operators, quotes and other hostile input never raise", () => {
  const { store, memories } = setup();
  ok(memories.create(id(1), input({ text: "foo bar: use AND sparingly, NEAR the top.", tags: ["c++"] })));
  ok(memories.create(id(2), input({ text: "Something else entirely." })));
  const hostile = [
    "\"foo AND (", "foo AND", "AND", "OR OR OR", "NOT foo", "foo NOT", "NEAR(foo bar, 2)", "NEAR(", "foo*", "*", "^foo", "text:foo", "nope:foo", "{text tags}: foo",
    "\"", "\"\"\"", "'", "foo\"bar", "(((", ")))", "foo + bar", "-foo", "foo -bar", "a\"b'c;d--e", "'; DROP TABLE memories; --", "%_%", "\\", "\u0000", "c++", "🙂",
    "   ", "", "x".repeat(5000), Array.from({ length: 200 }, (_, i) => `w${i}`).join(" "),
  ];
  for (const query of hostile) {
    for (const any of [false, true]) {
      let found: Memory[] = [];
      assert.doesNotThrow(() => { found = store.searchMemories({ query, any }); }, `query ${JSON.stringify(query.slice(0, 40))}`);
      assert.ok(Array.isArray(found));
    }
  }
  // The operators are only words: this finds the memory holding "foo" and "and", not a syntax error.
  assert.deepEqual(ids(store.searchMemories({ query: "\"foo AND (" })), [id(1)]);
  assert.deepEqual(ids(store.searchMemories({ query: "NEAR(foo bar, 2)" })), [], "near, foo, bar and 2 as words: no memory has them all");
  assert.deepEqual(ids(store.searchMemories({ query: "text:foo" })), [], "not a column filter: \"text\" is a word no memory has");
  assert.deepEqual(ids(store.searchMemories({ query: "'; DROP TABLE memories; --" })), []);
  assert.equal(store.memories().length, 2);
  assert.deepEqual(ids(store.searchMemories({ query: "\"\"\"" })), [id(2), id(1)], "no words: a plain list");
  assert.equal(ftsQuery("\"foo AND ("), "\"foo\"* \"AND\"*");
  assert.equal(ftsQuery("foo* -bar", true), "\"foo\"* OR \"bar\"*");
  assert.equal(ftsQuery(" \"(*) "), null);
  assert.equal(ftsQuery(undefined as never), null);
});

test("memory_log: an edit keeps the previous text and who changed it, and refuses UPDATE and DELETE", () => {
  const { db, store, memories } = setup();
  ok(memories.create(id(1), input({ text: "Tests run with node --test." }), { at: 10 }));
  ok(memories.edit(id(1), { text: "Tests run with node --test, never jest." }, "bob", { at: 20 }));
  ok(memories.edit(id(1), { tags: ["testing"] }, "cara", { at: 30 }));
  ok(memories.setStatus(id(1), "archived", "dev", { at: 40 }));
  ok(memories.edit(id(1), { text: "Tests run with node:test." }, "bob", { at: 50 }));

  const log = store.memoryLog(id(1));
  assert.deepEqual(log.map((e) => [e.action, e.by, e.at, e.textBefore]), [
    ["created", "ann", 10, null],
    ["edited", "bob", 20, "Tests run with node --test."],
    ["edited", "cara", 30, null],
    ["status", "dev", 40, null],
    ["edited", "bob", 50, "Tests run with node --test, never jest."],
  ]);
  assert.deepEqual(log.map((e) => e.seq), [1, 2, 3, 4, 5]);
  assert.equal(log[1].state.text, "Tests run with node --test, never jest.", "each entry holds the memory after the change");
  assert.deepEqual(log[4].state, store.memory(id(1)));
  // The same, straight from the table.
  const row = db.prepare("SELECT memory, by, action, text_before FROM memory_log WHERE seq = 2").get()!;
  assert.deepEqual({ ...row }, { memory: id(1), by: "bob", action: "edited", text_before: "Tests run with node --test." });

  assert.throws(() => db.prepare("UPDATE memory_log SET text_before = 'rewritten' WHERE seq = 2").run(), /memory_log is append-only/);
  assert.throws(() => db.prepare("DELETE FROM memory_log WHERE seq = 2").run(), /memory_log is append-only/);
  assert.throws(() => db.exec("DELETE FROM memory_log"), /memory_log is append-only/);
  assert.equal(store.memoryLog(id(1)).length, 5);
  assert.equal(store.memoryLog(id(1))[1].textBefore, "Tests run with node --test.");

  // A delete logs the last text, and the log outlives the memory.
  ok(memories.remove(id(1), "ann", { at: 60 }));
  const last = store.memoryLog(id(1)).at(-1)!;
  assert.deepEqual([last.action, last.by, last.at, last.textBefore], ["deleted", "ann", 60, "Tests run with node:test."]);
  assert.equal(store.memoryLog(id(1)).length, 6);
  assert.deepEqual(store.memoryLog(id(2)), []);
});

test("touchMemories bumps uses and lastUsedAt without a log entry, a delta or a new updatedAt", () => {
  const { store, memories, said } = setup();
  ok(memories.create(id(1), input(), { at: 10 }));
  ok(memories.create(id(2), input({ text: "Another." }), { at: 11 }));
  said();
  store.touchMemories([id(1), id(2), id(9)], 500);
  store.touchMemories([id(1)], 600);
  const one = store.memory(id(1))!;
  assert.deepEqual([one.uses, one.lastUsedAt, one.updatedAt], [2, 600, 10]);
  const two = store.memory(id(2))!;
  assert.deepEqual([two.uses, two.lastUsedAt, two.updatedAt], [1, 500, 11]);
  assert.equal(store.memoryLog(id(1)).length, 1, "no log entry");
  assert.deepEqual(said(), []);
  assert.deepEqual(ids(store.searchMemories({})), [id(2), id(1)], "order by updatedAt is unchanged");
  // A later edit keeps the counts.
  const edited = ok(memories.edit(id(1), { text: "The server runs on Workers." }, "bob", { at: 700 }));
  assert.deepEqual([edited.uses, edited.lastUsedAt], [2, 600]);
});

test("supersede: a memory that becomes active archives the one it replaces, and both are broadcast", () => {
  const { store, memories, said } = setup();
  const old = ok(memories.create(id(1), input({ text: "Deploy with wrangler publish." }), { at: 10 }));
  // Proposed: the old one stands.
  const proposed = ok(memories.create(id(2), input({ text: "Deploy with wrangler deploy.", status: "proposed", supersedes: id(1), source: { by: "bob", agent: "MF-1 builder" } }), { at: 20 }));
  assert.equal(store.memory(id(1))!.status, "active");
  assert.deepEqual(said().map((m) => m.type), ["memory.updated", "memory.updated"]);
  assert.deepEqual(ids(store.activeMemories()), [id(1)]);
  // Accepted: the old one is archived in the same step.
  const accepted = ok(memories.setStatus(id(2), "active", "ann", { at: 30 }));
  assert.deepEqual(said(), [
    { type: "memory.updated", memory: { ...proposed, status: "active", updatedAt: 30 } },
    { type: "memory.updated", memory: { ...old, status: "archived", updatedAt: 30 } },
  ]);
  assert.equal(accepted.supersedes, id(1));
  assert.deepEqual(ids(store.activeMemories()), [id(2)]);
  assert.deepEqual(store.memoryLog(id(1)).map((e) => [e.action, e.by]), [["created", "ann"], ["status", "ann"]]);
  assert.deepEqual(ids(store.searchMemories({ query: "wrangler" })), [id(2)]);
  // Created active with `supersedes`: the same, at once.
  ok(memories.create(id(3), input({ text: "Deploy with npm run deploy.", supersedes: id(2) }), { at: 40 }));
  assert.deepEqual(said().map((m) => m.type === "memory.updated" && [m.memory.id, m.memory.status]), [[id(3), "active"], [id(2), "archived"]]);
  // A later edit of the newer one doesn't touch what it replaced, even if that came back.
  ok(memories.setStatus(id(2), "active", "ann", { at: 50 }));
  said();
  ok(memories.edit(id(3), { tags: ["deploy"] }, "ann", { at: 60 }));
  assert.deepEqual(said().map((m) => m.type === "memory.updated" && m.memory.id), [id(3)]);
  assert.equal(store.memory(id(2))!.status, "active");
});

test("the schema is safe to run again over an existing database", () => {
  const sql = sqlStorage();
  const first = new Store(sql as unknown as SqlStorage);
  new Memories(first, { broadcast: () => {} }).create(id(1), input());
  const again = new Store(sql as unknown as SqlStorage);
  assert.deepEqual(ids(again.searchMemories({ query: "cloudflare" })), [id(1)]);
});

// ---- OrgHub: the snapshot and the deltas members get -------------------------

class FakeSocket {
  peer!: FakeSocket;
  inbox: string[] = [];
  attachment: unknown = null;
  send(data: string) { this.peer.inbox.push(data); }
  close() {}
  serializeAttachment(value: unknown) { this.attachment = structuredClone(value); }
  deserializeAttachment() { return structuredClone(this.attachment); }
}

test("OrgHub: a new connection's snapshot lists every memory, archived and proposed too; members get memory.updated and memory.removed", async () => {
  const { OrgHub } = await import("../src/org-hub.ts");
  const sockets: FakeSocket[] = [];
  const ctx = {
    storage: { sql: sqlStorage(), list: async () => new Map(), get: async () => undefined, put: async () => {}, getAlarm: async () => null, setAlarm: async () => {} },
    blockConcurrencyWhile: (fn: () => Promise<void>) => fn(),
    waitUntil: () => {},
    getWebSockets: () => sockets,
  };
  const env = {
    DB: { prepare: () => ({ all: async () => ({ results: [] }), bind: () => ({ all: async () => ({ results: [] }), first: async () => null }) }) },
    DOC: { idFromName: (n: string) => n, get: () => ({ fetch: async () => new Response(null, { status: 204 }) }) },
  };
  const org = new OrgHub(ctx as never, env as never);
  const client = (login: string) => {
    const ws = new FakeSocket();
    ws.peer = new FakeSocket();
    ws.serializeAttachment({ member: { login, name: login, role: "member", teams: [] }, subscribed: true });
    sockets.push(ws);
    const said = () => ws.peer.inbox.splice(0).map((m) => JSON.parse(m));
    const say = (msg: object) => org.webSocketMessage(ws as never, JSON.stringify(msg));
    return { said, say };
  };
  const memories = (org as unknown as { engine: { memories: Memories } }).engine.memories;
  const ann = client("ann");
  const bob = client("bob");

  // Create: every member hears it.
  const active = ok(memories.create(id(1), input({ text: "Active: the feed sends this one." })));
  for (const who of [ann, bob]) assert.deepEqual(who.said(), [{ type: "memory.updated", memory: active }]);
  const proposed = ok(memories.create(id(2), input({ text: "Proposed: waiting for a person.", status: "proposed" })));
  const toArchive = ok(memories.create(id(3), input({ text: "Soon archived.", scope: REPO })));
  ann.said();
  bob.said();
  // Edit and archive: memory.updated.
  const edited = ok(memories.edit(id(1), { text: "Active: the feed sends this one, edited." }, "ann"));
  assert.deepEqual(bob.said(), [{ type: "memory.updated", memory: edited }]);
  const archived = ok(memories.setStatus(id(3), "archived", "ann"));
  assert.deepEqual(bob.said(), [{ type: "memory.updated", memory: archived }]);
  assert.equal(archived.status, "archived");
  assert.equal(toArchive.status, "active");
  ann.said();

  // A member who connects now gets every memory, whatever its status (MF-394).
  const cara = client("cara");
  await cara.say({ type: "subscribe" });
  const snapshot = cara.said().find((m) => m.type === "snapshot");
  assert.ok(snapshot, "a snapshot");
  assert.deepEqual(snapshot.memories, [edited, proposed, archived], "proposed and archived ones too");
  assert.equal(proposed.status, "proposed");
  ann.said();
  bob.said();

  // Delete: memory.removed to everyone.
  ok(memories.remove(id(1), "ann"));
  for (const who of [ann, bob, cara]) assert.deepEqual(who.said(), [{ type: "memory.removed", id: id(1) }]);
  const dan = client("dan");
  await dan.say({ type: "subscribe" });
  assert.deepEqual(dan.said().find((m) => m.type === "snapshot").memories.map((m: Memory) => m.id), [id(2), id(3)]);
});

// ---- MF-394: people edit, archive, restore and accept memories through the hub ----

test("OrgHub: memory.edit and memory.status from a member edit, archive, restore and accept, broadcast, and log the member", async () => {
  const { OrgHub } = await import("../src/org-hub.ts");
  const sockets: FakeSocket[] = [];
  const audits: unknown[][] = [];
  const ctx = {
    storage: { sql: sqlStorage(), list: async () => new Map(), get: async () => undefined, put: async () => {}, getAlarm: async () => null, setAlarm: async () => {} },
    blockConcurrencyWhile: (fn: () => Promise<void>) => fn(),
    waitUntil: () => {},
    getWebSockets: () => sockets,
  };
  const env = {
    DB: { prepare: (q: string) => ({ all: async () => ({ results: [] }), bind: (...args: unknown[]) => ({ all: async () => ({ results: [] }), first: async () => null, run: async () => { if (q.includes("audit")) audits.push(args); } }) }) },
    DOC: { idFromName: (n: string) => n, get: () => ({ fetch: async () => new Response(null, { status: 204 }) }) },
  };
  const org = new OrgHub(ctx as never, env as never);
  const client = (login: string) => {
    const ws = new FakeSocket();
    ws.peer = new FakeSocket();
    ws.serializeAttachment({ member: { login, name: login, role: "member", teams: [] }, subscribed: true });
    sockets.push(ws);
    const said = () => ws.peer.inbox.splice(0).map((m) => JSON.parse(m));
    const say = (msg: object) => org.webSocketMessage(ws as never, JSON.stringify(msg));
    return { said, say };
  };
  const engine = (org as unknown as { engine: { memories: Memories } }).engine;
  const store = (org as unknown as { store: Store }).store;
  const ann = client("ann");
  const bob = client("bob");
  ok(engine.memories.create(id(1), input({ text: "Run npm test before pushing.", source: { by: "ann", task: "MF-391", agent: "MF-391 builder" } })));
  ok(engine.memories.create(id(2), input({ text: "Proposed by an agent.", status: "proposed" })));
  ann.said(); bob.said();

  // Edit: text, kind and tags; bob hears it; the log records ann and the text it replaced.
  await ann.say({ type: "memory.edit", id: id(1), text: "Run npm test and npm run gen:check before pushing.", kind: "convention", tags: ["CI"] });
  const [edited] = bob.said();
  ann.said();
  assert.equal(edited.type, "memory.updated");
  assert.equal(edited.memory.text, "Run npm test and npm run gen:check before pushing.");
  assert.equal(edited.memory.kind, "convention");
  assert.deepEqual(edited.memory.tags, ["ci"]);
  assert.equal(edited.memory.scope.kind, "org", "left-out fields stay");
  const editLog = store.memoryLog(id(1)).at(-1)!;
  assert.equal(editLog.by, "ann");
  assert.equal(editLog.textBefore, "Run npm test before pushing.");

  // Archive, then restore.
  await bob.say({ type: "memory.status", id: id(1), status: "archived" });
  assert.equal(ann.said()[0].memory.status, "archived");
  assert.equal(store.memoryLog(id(1)).at(-1)!.by, "bob");
  await new Promise((r) => setTimeout(r, 0));
  assert.ok(audits.some((a) => a[1] === "bob" && a[2] === "memory.archived" && a[3] === id(1)), "an audit entry for a person archiving");
  const cara = client("cara");
  await cara.say({ type: "subscribe" });
  assert.equal(cara.said().find((m) => m.type === "snapshot").memories.find((m: Memory) => m.id === id(1)).status, "archived", "archived memories are in the snapshot");
  ann.said(); bob.said();
  await bob.say({ type: "memory.status", id: id(1), status: "active" });
  assert.equal(ann.said()[0].memory.status, "active");
  bob.said(); cara.said();

  // Accept a proposed one.
  await ann.say({ type: "memory.status", id: id(2), status: "active" });
  assert.equal(bob.said()[0].memory.status, "active");
  assert.equal(store.memory(id(2))!.status, "active");
  ann.said();

  // A refusal comes back to the sender only, as an error.
  await ann.say({ type: "memory.edit", id: id(9), text: "nope" });
  assert.deepEqual(ann.said(), [{ type: "error", message: "That memory isn't there any more.", requestId: "memory.edit" }]);
  await ann.say({ type: "memory.edit", id: id(1), text: "" });
  assert.equal(ann.said()[0].type, "error");
  assert.deepEqual(bob.said(), []);
});

test("Agents can't send memory.edit or memory.status: only the member socket's ClientMessage carries them", async () => {
  const { unions } = await import("../../protocol/schema.ts");
  const carriers = Object.entries(unions).filter(([, u]) => "memory.edit" in u.variants || "memory.status" in u.variants).map(([name]) => name);
  assert.deepEqual(carriers, ["ClientMessage"], "no agent or machine message can edit or archive a memory");
});

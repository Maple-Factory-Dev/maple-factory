// MF-364: doc comment anchors survive concurrent edits on merged Y.Docs, deleted text gives an orphan,
// and threads' lifecycle and @mention pushes (author excluded, quiet hours, ref doc:<id>).
import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import * as Y from "yjs";
import { initProseMirrorDoc, prosemirrorToYXmlFragment } from "@tiptap/y-tiptap";
import { schema } from "../docs-editor/src/schema.js";
import { fromMarkdown } from "../docs-editor/src/markdown.js";
import { anchorFromRange, resolveAnchor } from "../docs-editor/src/comments.js";
import { newThread, addComment, resolve, reopen, mentionTargets, notifyMentions, invalid } from "../src/factory/doc-threads.ts";
import { Store } from "../src/factory/store.ts";
import { Push, seal } from "../src/push.ts";
import type { Env } from "../src/env.ts";

const view = (ydoc: Y.Doc) => initProseMirrorDoc(ydoc.getXmlFragment("prosemirror"), schema);

/** The PM range of the first `text` in the doc. */
function rangeOf(doc: any, text: string) {
  let found: [number, number] | null = null;
  doc.descendants((n: any, pos: number) => {
    if (found || !n.isText) return;
    const i = n.text.indexOf(text);
    if (i >= 0) found = [pos + i, pos + i + text.length];
  });
  assert.ok(found, `no "${text}"`);
  return found!;
}

function quoted(ydoc: Y.Doc, anchor: any) {
  const { doc, mapping } = view(ydoc);
  const r = resolveAnchor(ydoc, mapping, anchor);
  return "orphan" in r ? null : doc.textBetween(r.from, r.to);
}

/** Inserts `text` into the paragraph's Y.XmlText at index `at` (a remote collaborator's typing). */
function typeAt(ydoc: Y.Doc, at: number, text: string) {
  const para = ydoc.getXmlFragment("prosemirror").get(0) as Y.XmlElement;
  (para.get(0) as Y.XmlText).insert(at, text);
}

function seeded() {
  const a = new Y.Doc();
  prosemirrorToYXmlFragment(fromMarkdown(schema, "The quick brown fox jumps over the lazy dog.\n", {}), a.getXmlFragment("prosemirror"));
  const b = new Y.Doc();
  Y.applyUpdate(b, Y.encodeStateAsUpdate(a));
  return { a, b };
}

function anchorOn(ydoc: Y.Doc, text: string) {
  const { doc, mapping } = view(ydoc);
  const [from, to] = rangeOf(doc, text);
  return anchorFromRange(ydoc, mapping, doc, from, to);
}

for (const order of ["a→b", "b→a"]) {
  test(`an anchor follows concurrent inserts before, inside and after it (merged ${order})`, () => {
    const { a, b } = seeded();
    const anchor = anchorOn(a, "brown fox");
    assert.equal(anchor.quote, "brown fox");
    // A types before the range; B types inside it and after it, concurrently.
    typeAt(a, 0, "Oh! ");
    typeAt(b, "The quick brown".length, " red");
    typeAt(b, "The quick brown red fox jumps".length, " high");
    const [x, y] = order === "a→b" ? [a, b] : [b, a];
    Y.applyUpdate(y, Y.encodeStateAsUpdate(x));
    Y.applyUpdate(x, Y.encodeStateAsUpdate(y));
    assert.equal(a.getXmlFragment("prosemirror").toString(), b.getXmlFragment("prosemirror").toString());
    assert.equal(quoted(a, anchor), "brown red fox");
    assert.equal(quoted(b, anchor), "brown red fox");
  });
}

test("deleting the anchored text leaves an orphan ('on deleted text')", () => {
  const { a, b } = seeded();
  const anchor = anchorOn(a, "brown fox");
  const text = (b.getXmlFragment("prosemirror").get(0) as Y.XmlElement).get(0) as Y.XmlText;
  text.delete("The quick ".length, "brown fox".length);
  Y.applyUpdate(a, Y.encodeStateAsUpdate(b));
  assert.deepEqual(resolveAnchor(a, view(a).mapping, anchor), { orphan: true });
  assert.equal(quoted(b, anchor), null);
});

test("a resolved thread's anchor still resolves after later edits", () => {
  const { a } = seeded();
  const t = resolve(newThread("d1", "ada", "typo?", anchorOn(a, "lazy dog"), [{ login: "ada" }]), "ada");
  typeAt(a, 0, "Edited later. ");
  assert.equal(t.resolved, true);
  assert.equal(quoted(a, t.anchor), "lazy dog");
});

test("an anchor survives a round trip through its base64 encoding only (unreadable → orphan)", () => {
  const { a } = seeded();
  assert.deepEqual(resolveAnchor(a, view(a).mapping, { from: "!!", to: "??", quote: "" }), { orphan: true });
  assert.equal(invalid("hi", { from: "!!", to: "AA==", quote: "" }), "That comment's anchor isn't valid.");
  assert.equal(invalid("hi", anchorOn(a, "fox")), null);
  assert.equal(invalid("   "), "Write something first.");
  assert.match(invalid("x".repeat(10_001))!, /at most/);
});

// Threads and mentions.

const members = [{ login: "ada" }, { login: "Grace" }, { login: "linus" }];
const anchor = { from: "AA==", to: "AQ==", quote: "fox" };

test("comment, reply, resolve, reopen; a reply reopens a resolved thread", () => {
  let t = newThread("d1", "ada", "What about @grace?", anchor, members, 1);
  assert.equal(t.comments.length, 1);
  assert.equal(t.createdBy, "ada");
  t = resolve(t, "Grace", 2);
  assert.deepEqual([t.resolved, t.resolvedBy, t.resolvedAt], [true, "Grace", 2]);
  t = reopen(t);
  assert.equal(t.resolved, null);
  t = addComment(resolve(t, "ada", 3), "linus", "Still broken", members, 4);
  assert.equal(t.comments.length, 2);
  assert.equal(t.resolved, null);
});

test("mentions skip the author and non-members, as each member's own login", () => {
  const t = newThread("d1", "ada", "@ada @GRACE @nobody @linus @grace", anchor, members);
  assert.deepEqual(t.comments[0].mentions, ["Grace", "linus"]);
  assert.deepEqual(mentionTargets(addComment(t, "linus", "thanks @linus", members)), []);
});

function sqlStorage() {
  const db = new DatabaseSync(":memory:");
  return {
    exec(query: string, ...bindings: unknown[]) {
      const statements = query.split(";").map((s) => s.trim()).filter(Boolean);
      if (statements.length > 1) { db.exec(query); return { toArray: () => [], one: () => undefined }; }
      const rows = db.prepare(query).all(...(bindings as never[]));
      return { toArray: () => rows, one: () => rows[0] };
    },
  } as unknown as SqlStorage;
}

const KEY = "mfk_test-secrets-key";
const CRED = { id: "pf_factory123", secret: "pfs_secret" };
async function env(): Promise<Env> {
  const value = await seal(KEY, CRED);
  const DB = { prepare: () => ({ bind: () => ({ first: async () => ({ value }) }) }) };
  return { DB, SECRETS_KEY: KEY, PUSH_RELAY_URL: "http://relay.test" } as unknown as Env;
}

let sent: Array<{ url: string; body: any }>;
beforeEach(() => {
  sent = [];
  globalThis.fetch = (async (url: string, init: RequestInit) => {
    sent.push({ url: String(url), body: JSON.parse(String(init.body)) });
    return new Response("{}", { status: 200 });
  }) as typeof fetch;
});

function store() {
  const s = new Store(sqlStorage());
  s.registerPushDevice("Grace", { platform: "apns", token: "grace-token", environment: "sandbox" });
  s.registerPushDevice("linus", { platform: "fcm", token: "linus-token", environment: "production" });
  s.registerPushDevice("ada", { platform: "apns", token: "ada-token", environment: "sandbox" });
  return s;
}

test("@mention pushes go to mentioned logins with ref doc:<id>, never the author", async () => {
  const s = store();
  const t = newThread("doc-1", "ada", "@ada can @grace and @linus look?", anchor, members);
  assert.equal(await notifyMentions(new Push(await env(), s), t), 2);
  assert.deepEqual(sent.map((x) => [x.body.token, x.body.ref, x.body.reason]).sort(), [["grace-token", "doc:doc-1", "mention"], ["linus-token", "doc:doc-1", "mention"]]);
  assert.ok(sent.every((x) => x.url === "http://relay.test/push/send"));
});

test("@mention pushes are held in the mentioned member's quiet hours", async () => {
  const s = store();
  s.setQuietHours("Grace", { timeZone: "UTC", windows: [{ days: [0, 1, 2, 3, 4, 5, 6], start: 0, end: 1439 }] });
  if (new Date().getUTCHours() === 23 && new Date().getUTCMinutes() === 59) return;
  const t = newThread("doc-1", "ada", "@grace and @linus", anchor, members);
  assert.equal(await notifyMentions(new Push(await env(), s), t), 1);
  assert.deepEqual(sent.map((x) => x.body.token), ["linus-token"]);
});

test("the store keeps threads per doc and counts the open ones on the doc", () => {
  const s = store();
  s.saveDoc({ id: "doc-1", title: "Plan", createdBy: "ada", createdAt: 1, updatedAt: 1 } as any);
  const t1 = newThread("doc-1", "ada", "one", anchor, members, 1);
  const t2 = newThread("doc-1", "ada", "two", anchor, members, 2);
  s.saveThread(t1);
  s.saveThread(t2);
  assert.equal(s.doc("doc-1")!.openThreads, 2);
  s.saveThread(resolve(t1, "ada", 3));
  assert.equal(s.doc("doc-1")!.openThreads, 1);
  assert.equal(s.docs()[0].openThreads, 1);
  assert.deepEqual(s.threads("doc-1").map((t) => t.id).sort(), [t1.id, t2.id].sort());
  assert.equal(s.thread(t1.id)!.resolved, true);
});

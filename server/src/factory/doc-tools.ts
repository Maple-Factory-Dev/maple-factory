// Agents' doc tools (MF-365, docs/planning-docs.md): list_docs, read_doc, comment_on_doc, reply_to_doc_thread,
// resolve_doc_thread and suggest_doc_edit, for task sessions and personal sessions alike, plus a person's
// doc.suggestion accept / reject. Docs are looked up only in this OrgHub's store, so only the org's own docs
// are reachable. Agents never write a doc's text: a suggestion is a DocThread with `suggestion` set, and only
// a person's Accept asks DocHub to apply it.
import type { Env } from "../env.ts";
import type { Doc, DocAnchor, DocThread, Member, ServerToClient } from "../wire.ts";
import type { Store } from "./store.ts";
import { docHub } from "../doc-routes.ts";
import * as threads from "./doc-threads.ts";

export const MAX_REPLACEMENT = 10_000;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export class DocToolFailure extends Error {}
const fail = (message: string): never => { throw new DocToolFailure(message); };

export interface DocToolHooks {
  broadcast(message: ServerToClient): void;
  members(): Promise<Member[]>;
  /** Push a thread's newest comment's @mentions (doc-threads notifyMentions). */
  notify(thread: DocThread): void;
}

/** Who's calling: `author` (a task id, or the machine's owner) and the agent badge its comments get. */
export interface DocCaller { author: string; agent: string }

type Read = { markdown: string; blocks: { id: string | null; markdown: string }[]; threads: { id: string; block: string | null; quote: string | null; orphan: boolean }[] };

export class DocTools {
  constructor(private env: Env, private store: Store, private hooks: DocToolHooks) {}

  private async hub<T>(doc: string, path: string, body: unknown): Promise<T> {
    const res = await docHub(this.env, doc).fetch(`https://doc${path}`, { method: "POST", headers: { "content-type": "application/json", "x-doc-id": doc }, body: JSON.stringify(body) });
    if (res.status === 422) fail(await res.text());
    if (!res.ok) fail(`The doc couldn't be reached (${res.status}); try again.`);
    return (await res.json()) as T;
  }

  /** The org's doc `id`, not archived. */
  private doc(id: unknown): Doc {
    const doc = typeof id === "string" && UUID.test(id) ? this.store.doc(id.toLowerCase()) : fail("doc must be a doc id (a uuid) from list_docs.");
    if (!doc) fail(`There's no doc ${String(id)} in this factory; list_docs shows the ones there are.`);
    if (doc!.archived) fail(`"${doc!.title}" is archived (read-only); it can't be read or commented on here.`);
    return doc!;
  }

  private thread(doc: Doc, id: unknown): DocThread {
    const t = typeof id === "string" && UUID.test(id) ? this.store.thread(id.toLowerCase()) : null;
    if (!t || t.doc !== doc.id) fail(`There's no thread ${String(id)} on "${doc.title}"; read_doc lists its threads.`);
    return t!;
  }

  private async anchor(doc: Doc, a: Record<string, unknown>): Promise<DocAnchor | null> {
    const block = typeof a.block === "string" && a.block ? a.block : null;
    const quote = typeof a.quote === "string" && a.quote ? a.quote : null;
    if (!block && !quote) return null;
    return this.hub<DocAnchor>(doc.id, "/anchor", { block, quote });
  }

  private save(thread: DocThread) {
    this.store.saveThread(thread);
    this.hooks.broadcast({ type: "doc.thread.updated", thread });
    this.hooks.broadcast({ type: "doc.updated", doc: this.store.doc(thread.doc)! });
  }

  /** The newest comment carries the agent badge. */
  private badge(t: DocThread, agent: string): DocThread {
    const last = t.comments.at(-1)!;
    return { ...t, comments: [...t.comments.slice(0, -1), { ...last, agent }] };
  }

  async run(caller: DocCaller, name: string, a: Record<string, unknown>): Promise<{ summary: string; data?: unknown }> {
    if (name === "list_docs") {
      const q = typeof a.q === "string" ? a.q.trim().toLowerCase() : "";
      const goal = typeof a.goal === "string" && a.goal.trim() ? a.goal.trim() : null;
      const limit = typeof a.limit === "number" && a.limit > 0 ? Math.min(a.limit, 200) : 50;
      const docs = this.store.docs().filter((d) => !d.archived && (!q || d.title.toLowerCase().includes(q)) && (!goal || d.goal === goal)).slice(0, limit);
      return {
        summary: docs.length ? `${docs.length} doc${docs.length === 1 ? "" : "s"}.` : "No docs.",
        data: docs.map((d) => ({ id: d.id, title: d.title, goal: d.goal ?? null, updatedAt: d.updatedAt, openThreads: d.openThreads ?? 0 })),
      };
    }
    const doc = this.doc(a.doc);
    if (name === "read_doc") {
      const open = this.store.threads(doc.id).filter((t) => !t.resolved);
      const read = await this.hub<Read>(doc.id, "/read", { threads: open.map((t) => ({ id: t.id, anchor: t.anchor ?? null })) });
      const where = new Map(read.threads.map((t) => [t.id, t]));
      const lines = open.map((t) => {
        const w = where.get(t.id);
        const at = !t.anchor ? "on the whole doc" : w?.orphan ? `on deleted text "${t.anchor.quote}"` : `on ${w?.block ?? "?"} "${w?.quote ?? t.anchor.quote}"`;
        const head = t.suggestion ? `- suggestion ${t.id} ${at}: replace with ${JSON.stringify(t.suggestion.replacement)}` : `- thread ${t.id} ${at}`;
        return [head, ...t.comments.map((c) => `  - ${c.author}${c.agent ? ` (${c.agent})` : ""}: ${c.text.replace(/\n/g, " ")}`)].join("\n");
      });
      const text = `# ${doc.title}\n\n${read.markdown}${lines.length ? `\n---\nOpen threads and suggestions:\n${lines.join("\n")}\n` : ""}`;
      return { summary: `"${doc.title}": ${read.blocks.length} block${read.blocks.length === 1 ? "" : "s"}, ${open.length} open thread${open.length === 1 ? "" : "s"}.`, data: text };
    }
    const members = await this.hooks.members();
    if (name === "comment_on_doc" || name === "suggest_doc_edit") {
      if (this.store.threadCount(doc.id) >= threads.MAX_THREADS) fail(`A doc holds at most ${threads.MAX_THREADS} threads.`);
      let thread: DocThread;
      if (name === "comment_on_doc") {
        const text = typeof a.text === "string" ? a.text : "";
        const why = threads.invalid(text);
        if (why) fail(why);
        thread = threads.newThread(doc.id, caller.author, text, (await this.anchor(doc, a)) as DocAnchor, members);
      } else {
        const replacement = typeof a.replacement === "string" ? a.replacement : fail("replacement is required (an empty string suggests a deletion).");
        if (replacement.length > MAX_REPLACEMENT) fail(`replacement is at most ${MAX_REPLACEMENT} characters.`);
        const anchor = (await this.anchor(doc, a)) ?? fail("Give the block or the exact quote the suggestion replaces.");
        const note = typeof a.note === "string" && a.note.trim() ? a.note : "Suggested edit.";
        if (note.length > threads.MAX_COMMENT) fail(`note is at most ${threads.MAX_COMMENT} characters.`);
        thread = { ...threads.newThread(doc.id, caller.author, note, anchor, members), suggestion: { replacement, status: "open", decidedBy: null, decidedAt: null } };
      }
      thread = this.badge(thread, caller.agent);
      this.save(thread);
      this.hooks.notify(thread);
      const kind = thread.suggestion ? "suggestion" : "thread";
      return { summary: `Started ${kind} ${thread.id} on "${doc.title}"${thread.anchor ? ` at "${thread.anchor.quote.slice(0, 80)}"` : ""}.${thread.suggestion ? " A person accepts or rejects it in the editor." : ""}`, data: { thread: thread.id } };
    }
    const t = this.thread(doc, a.thread);
    if (name === "reply_to_doc_thread") {
      const text = typeof a.text === "string" ? a.text : "";
      const why = threads.invalid(text);
      if (why) fail(why);
      const thread = this.badge(threads.addComment(t, caller.author, text, members), caller.agent);
      this.save(thread);
      this.hooks.notify(thread);
      return { summary: `Replied in ${thread.id}.`, data: { thread: thread.id } };
    }
    if (name === "resolve_doc_thread") {
      if (t.suggestion?.status === "open") fail("That's an open suggestion: a person accepts or rejects it in the editor.");
      this.save(threads.resolve(t, caller.author));
      return { summary: `Resolved ${t.id}.`, data: { thread: t.id } };
    }
    return fail(`${name} isn't a doc tool.`);
  }

  /** A person's Accept / Reject (`doc.suggestion`). Accepting applies it in DocHub first; if that's refused
   *  (the text changed) the thread stays open and the error comes back. */
  async decide(login: string, docId: string, threadId: string, accept: boolean): Promise<DocThread> {
    const doc = this.store.doc(docId) ?? fail("That doc isn't there any more.");
    if (doc.archived) fail("That doc is archived; bring it back first.");
    const t = this.store.thread(threadId);
    if (!t || t.doc !== doc.id || !t.suggestion) fail("That suggestion isn't there any more.");
    if (t!.suggestion!.status !== "open") fail(`That suggestion was already ${t!.suggestion!.status}.`);
    if (accept) await this.hub(doc.id, "/apply", { anchor: t!.anchor, markdown: t!.suggestion!.replacement });
    const at = Date.now();
    const thread = { ...threads.resolve(t!, login, at), suggestion: { ...t!.suggestion!, status: accept ? "accepted" as const : "rejected" as const, decidedBy: login, decidedAt: at } };
    this.save(thread);
    return thread;
  }
}

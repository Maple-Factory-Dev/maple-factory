// Doc comment threads (MF-364, docs/planning-docs.md): the pure pieces OrgHub's doc.comment / doc.resolve /
// doc.reopen use, kept here so they're unit-testable. The anchor is two base64 Y.RelativePositions the
// server only checks the shape of; the editor resolves them against the doc's Yjs text.
import type { DocAnchor, DocComment, DocThread } from "../wire.ts";
import { mentionsIn } from "./mentions.ts";

export const MAX_COMMENT = 10_000;
export const MAX_THREADS = 500;
export const MAX_ANCHOR = 2048;
const BASE64 = /^[A-Za-z0-9+/]*={0,2}$/;

/** Why a comment's text or anchor won't do, or null. */
export function invalid(text: string, anchor?: DocAnchor | null): string | null {
  if (!text.trim()) return "Write something first.";
  if (text.length > MAX_COMMENT) return `A comment is at most ${MAX_COMMENT} characters.`;
  if (anchor) {
    for (const pos of [anchor.from, anchor.to]) {
      if (typeof pos !== "string" || !pos || pos.length > MAX_ANCHOR || !BASE64.test(pos)) return "That comment's anchor isn't valid.";
    }
    if (typeof anchor.quote !== "string" || anchor.quote.length > MAX_COMMENT) return "That comment's anchor isn't valid.";
  }
  return null;
}

function comment(author: string, text: string, members: { login: string }[], at: number): DocComment {
  const mentions = mentionsIn(text, members, author);
  return { id: crypto.randomUUID(), author, text: text.trim(), at, mentions: mentions.length ? mentions : null };
}

export function newThread(doc: string, author: string, text: string, anchor: DocAnchor, members: { login: string }[], at = Date.now()): DocThread {
  return { id: crypto.randomUUID(), doc, anchor, comments: [comment(author, text, members, at)], resolved: null, resolvedBy: null, resolvedAt: null, createdBy: author, createdAt: at };
}

/** A reply; it reopens a resolved thread. */
export function addComment(t: DocThread, author: string, text: string, members: { login: string }[], at = Date.now()): DocThread {
  return { ...t, comments: [...t.comments, comment(author, text, members, at)], resolved: null, resolvedBy: null, resolvedAt: null };
}

export function resolve(t: DocThread, by: string, at = Date.now()): DocThread {
  return { ...t, resolved: true, resolvedBy: by, resolvedAt: at };
}

export function reopen(t: DocThread): DocThread {
  return { ...t, resolved: null, resolvedBy: null, resolvedAt: null };
}

/** Who a thread's newest comment should push to: its mentions (already without the author). */
export function mentionTargets(t: DocThread): string[] {
  return t.comments.at(-1)?.mentions ?? [];
}

/** Push each mentioned member with ref `doc:<id>`; Push.send skips quiet hours and a relay that's off. */
export async function notifyMentions(push: { send(login: string, what: { ref: string; reason: "mention" }): Promise<number> }, t: DocThread): Promise<number> {
  let sent = 0;
  for (const login of mentionTargets(t)) sent += await push.send(login, { ref: `doc:${t.doc}`, reason: "mention" });
  return sent;
}

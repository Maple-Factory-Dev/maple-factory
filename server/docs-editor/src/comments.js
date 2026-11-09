// Doc comments (MF-364, docs/planning-docs.md): anchors, highlights, and the margin rail / thread list.
// An anchor is two Yjs relative positions on the `prosemirror` fragment (base64) plus the quoted text, so
// the doc's content and its Markdown stay untouched and concurrent edits move the anchor with the text.
// Threads themselves live server-side (OrgHub's doc_threads); the host feeds them in and relays commands.
import * as Y from "yjs";
import { Plugin, PluginKey } from "@tiptap/pm/state";
import { Decoration, DecorationSet } from "@tiptap/pm/view";
import { absolutePositionToRelativePosition, relativePositionToAbsolutePosition, ySyncPluginKey } from "@tiptap/y-tiptap";

const SHARED_TYPE = "prosemirror";

const toB64 = (bytes) => {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s);
};
const fromB64 = (str) => Uint8Array.from(atob(str), (c) => c.charCodeAt(0));

/** The binding's position mapping inside an editor; tests pass the `mapping` from initProseMirrorDoc. */
export const mappingOf = (state) => ySyncPluginKey.getState(state)?.binding?.mapping ?? new Map();

/** An anchor for the ProseMirror range from..to of `pmDoc`, in `ydoc`'s shared fragment. */
export function anchorFromRange(ydoc, mapping, pmDoc, from, to) {
  const type = ydoc.getXmlFragment(SHARED_TYPE);
  const enc = (pos) => toB64(Y.encodeRelativePosition(absolutePositionToRelativePosition(pos, type, mapping)));
  return { from: enc(from), to: enc(to), quote: pmDoc.textBetween(from, to, " ", " ").slice(0, 2000) };
}

/** Where an anchor sits now: {from, to}, or {orphan: true} when its text was deleted (or it can't be read). */
export function resolveAnchor(ydoc, mapping, anchor) {
  if (!anchor) return { orphan: true };
  try {
    const type = ydoc.getXmlFragment(SHARED_TYPE);
    const at = (s) => relativePositionToAbsolutePosition(ydoc, type, Y.decodeRelativePosition(fromB64(s)), mapping);
    const from = at(anchor.from), to = at(anchor.to);
    if (from == null || to == null || from >= to) return { orphan: true };
    return { from, to };
  } catch {
    return { orphan: true };
  }
}

export const commentsKey = new PluginKey("docComments");

/** Highlights open threads' ranges; the active one is emphasised. `get()` → {threads, active, ydoc}. */
export function commentHighlights(get) {
  return new Plugin({
    key: commentsKey,
    props: {
      decorations(state) {
        const { threads, active, ydoc } = get();
        if (!threads.length) return null;
        const mapping = mappingOf(state);
        const decos = [];
        for (const t of threads) {
          if (t.resolved) continue;
          const r = resolveAnchor(ydoc, mapping, t.anchor);
          if (r.orphan || r.to > state.doc.content.size) continue;
          const kind = t.suggestion ? "doc-suggestion-mark" : "doc-comment-mark";
          decos.push(Decoration.inline(r.from, r.to, { class: kind + (t.id === active ? " active" : ""), "data-thread": t.id }));
        }
        return DecorationSet.create(state.doc, decos);
      },
    },
  });
}

const el = (tag, cls, text) => {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text != null) e.textContent = text;
  return e;
};
const ago = (at) => {
  const s = Math.max(0, (Date.now() - at) / 1000);
  if (s < 60) return "now";
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  if (s < 86400) return `${Math.floor(s / 3600)}h`;
  return new Date(at).toLocaleDateString();
};

/** A textarea that offers `@login` completions from members(). */
function composer(members, placeholder, onSubmit, onCancel) {
  const box = el("div", "doc-composer");
  const ta = el("textarea");
  ta.rows = 2;
  ta.placeholder = placeholder;
  const list = el("div", "doc-composer-mentions");
  list.hidden = true;
  const row = el("div", "doc-composer-actions");
  const send = el("button", "doc-btn primary", "Comment");
  send.type = "button";
  row.append(send);
  if (onCancel) {
    const cancel = el("button", "doc-btn", "Cancel");
    cancel.type = "button";
    cancel.addEventListener("click", onCancel);
    row.append(cancel);
  }
  const submit = () => {
    const text = ta.value.trim();
    if (!text) return;
    onSubmit(text);
    ta.value = "";
    list.hidden = true;
  };
  send.addEventListener("click", submit);
  const query = () => /(?:^|\s)@([\w-]*)$/.exec(ta.value.slice(0, ta.selectionStart))?.[1];
  const complete = (login) => {
    const before = ta.value.slice(0, ta.selectionStart).replace(/@([\w-]*)$/, `@${login} `);
    ta.value = before + ta.value.slice(ta.selectionStart);
    ta.selectionStart = ta.selectionEnd = before.length;
    list.hidden = true;
    ta.focus();
  };
  ta.addEventListener("input", () => {
    const q = query();
    if (q == null) return (list.hidden = true);
    const hits = members().filter((m) => m.login.toLowerCase().startsWith(q.toLowerCase()) || (m.name || "").toLowerCase().startsWith(q.toLowerCase())).slice(0, 6);
    list.replaceChildren(...hits.map((m) => {
      const b = el("button", "doc-menu-item", m.name && m.name !== m.login ? `${m.name} @${m.login}` : `@${m.login}`);
      b.type = "button";
      b.addEventListener("mousedown", (e) => { e.preventDefault(); complete(m.login); });
      return b;
    }));
    list.hidden = !hits.length;
  });
  ta.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { e.preventDefault(); submit(); }
    if (e.key === "Escape" && onCancel) onCancel();
  });
  box.append(ta, list, row);
  return { box, focus: () => ta.focus() };
}

/**
 * The margin rail: thread cards aligned to their anchors (orphans under "On deleted text"), with Open /
 * Resolved filters, reply, Resolve and Reopen; suggested edits (MF-365) get Accept / Reject (doc.suggestion). `threads()` → DocThread[]; `send(cmd)` relays
 * doc.comment / doc.resolve / doc.reopen; `onCount(open)` tells the host the open count (for badges).
 */
export function createCommentRail({ editor, ydoc, docId, threads, members, send, onCount = () => {} }) {
  const rail = el("aside", "doc-rail");
  const head = el("div", "doc-rail-head");
  const tabs = { open: el("button", "doc-rail-tab on"), resolved: el("button", "doc-rail-tab") };
  let filter = "open", active = null, draft = null;
  for (const [k, b] of Object.entries(tabs)) {
    b.type = "button";
    b.dataset.filter = k;
    b.addEventListener("click", () => { filter = k; draw(); });
    head.append(b);
  }
  const body = el("div", "doc-rail-body");
  rail.append(head, body);

  const view = () => editor.view;
  const where = (t) => resolveAnchor(ydoc, mappingOf(editor.state), t.anchor);

  /** Starts a thread on the current selection (a text range or a selected block). */
  function startThread() {
    const { from, to } = editor.state.selection;
    if (from === to) return;
    draft = { anchor: anchorFromRange(ydoc, mappingOf(editor.state), editor.state.doc, from, to), from };
    filter = "open";
    draw();
    rail.querySelector(".doc-composer textarea")?.focus();
  }

  function card(t) {
    const c = el("div", "doc-thread" + (t.id === active ? " active" : "") + (t.resolved ? " resolved" : ""));
    c.dataset.thread = t.id;
    const sug = t.suggestion;
    if (sug) {
      // A tracked change (MF-365): the original struck through, the replacement in green, Accept / Reject.
      c.classList.add("suggestion");
      const by = t.comments[0]?.agent || t.createdBy;
      c.append(el("div", "doc-suggest-label", `Suggested edit by ${by}`));
      const diff = el("div", "doc-suggest-diff");
      if (t.anchor?.quote) diff.append(el("del", "doc-suggest-old", t.anchor.quote));
      diff.append(sug.replacement ? el("ins", "doc-suggest-new", sug.replacement) : el("span", "doc-suggest-delete", "(delete it)"));
      c.append(diff);
    } else if (t.anchor?.quote) c.append(el("div", "doc-thread-quote", t.anchor.quote));
    for (const m of t.comments) {
      const row = el("div", "doc-comment");
      const meta = el("div", "doc-comment-meta");
      meta.append(el("strong", null, m.author));
      if (m.agent) meta.append(el("span", "doc-agent-badge", m.agent));
      meta.append(el("span", null, ` · ${ago(m.at)}`));
      const text = el("div", "doc-comment-text");
      for (const part of m.text.split(/(@[\w-]+)/)) text.append(part.startsWith("@") ? el("span", "doc-comment-mention", part) : document.createTextNode(part));
      row.append(meta, text);
      c.append(row);
    }
    const actions = el("div", "doc-thread-actions");
    if (sug?.status === "open") {
      for (const [label, accept] of [["Accept", true], ["Reject", false]]) {
        const b = el("button", "doc-btn" + (accept ? " primary doc-suggest-accept" : " doc-suggest-reject"), label);
        b.type = "button";
        b.addEventListener("click", (e) => { e.stopPropagation(); send({ type: "doc.suggestion", doc: docId, thread: t.id, accept }); });
        actions.append(b);
      }
    } else if (sug) {
      actions.append(el("span", `doc-suggest-status ${sug.status}`, `${sug.status === "accepted" ? "Accepted" : "Rejected"}${sug.decidedBy ? ` by ${sug.decidedBy}` : ""}`));
    } else {
      const toggle = el("button", "doc-btn", t.resolved ? "Reopen" : "Resolve");
      toggle.type = "button";
      toggle.addEventListener("click", (e) => { e.stopPropagation(); send({ type: t.resolved ? "doc.reopen" : "doc.resolve", doc: docId, thread: t.id }); });
      actions.append(toggle);
      if (t.resolved) actions.append(el("span", "doc-thread-by", `Resolved by ${t.resolvedBy}`));
    }
    c.append(actions);
    if (t.id === active && !t.resolved) {
      const reply = composer(members, "Reply…", (text) => send({ type: "doc.comment", doc: docId, thread: t.id, text }));
      reply.box.addEventListener("click", (e) => e.stopPropagation());
      c.append(reply.box);
    }
    c.addEventListener("click", () => {
      active = active === t.id ? null : t.id;
      const r = where(t);
      if (active && !r.orphan) editor.commands.setTextSelection(r.from);
      refresh();
    });
    return c;
  }

  function draw() {
    const all = threads();
    const open = all.filter((t) => !t.resolved);
    tabs.open.textContent = `Open ${open.length}`;
    tabs.resolved.textContent = `Resolved ${all.length - open.length}`;
    tabs.open.classList.toggle("on", filter === "open");
    tabs.resolved.classList.toggle("on", filter === "resolved");
    onCount(open.length);
    const shown = all.filter((t) => (filter === "open" ? !t.resolved : t.resolved));
    const placed = [], orphans = [];
    for (const t of shown) {
      const r = where(t);
      if (r.orphan) orphans.push(t);
      else placed.push({ t, pos: r.from });
    }
    placed.sort((a, b) => a.pos - b.pos);
    const nodes = [];
    if (draft) {
      const c = el("div", "doc-thread draft");
      c.dataset.pos = draft.from;
      c.append(el("div", "doc-thread-quote", draft.anchor.quote));
      const comp = composer(members, "Comment, @mention someone…", (text) => {
        send({ type: "doc.comment", doc: docId, text, anchor: draft.anchor });
        draft = null;
        draw();
      }, () => { draft = null; draw(); });
      c.append(comp.box);
      nodes.push(c);
    }
    for (const { t, pos } of placed) {
      const node = card(t);
      if (filter === "open") node.dataset.pos = pos;
      nodes.push(node);
    }
    if (orphans.length) {
      nodes.push(el("div", "doc-rail-heading", "On deleted text"));
      for (const t of orphans) nodes.push(card(t));
    }
    if (!nodes.length) nodes.push(el("div", "doc-rail-empty", filter === "open" ? "No open comments. Select text and choose Comment." : "No resolved comments."));
    body.replaceChildren(...nodes);
    // Each card sits level with its anchor, pushed down past the card above it.
    const base = body.getBoundingClientRect().top;
    let bottom = 0;
    for (const n of body.children) {
      if (n.dataset.pos != null) {
        let want = bottom;
        try { want = view().coordsAtPos(Number(n.dataset.pos)).top - base; } catch {}
        n.style.marginTop = `${Math.max(0, want - bottom)}px`;
      }
      bottom = n.offsetTop + n.offsetHeight + 8;
    }
  }

  /** Redraws the highlights (editor) and the rail. */
  function refresh() {
    view()?.dispatch(view().state.tr.setMeta(commentsKey, true));
    draw();
  }
  let pending = 0;
  editor.on("update", () => { cancelAnimationFrame(pending); pending = requestAnimationFrame(draw); });
  // Clicking highlighted text makes its thread active.
  editor.view.dom.addEventListener("click", (e) => {
    const id = e.target.closest?.("[data-thread]")?.dataset.thread;
    if (id && id !== active) { active = id; filter = "open"; refresh(); }
  });

  return { rail, startThread, refresh, active: () => active };
}

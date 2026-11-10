// Decision embeds (MF-367, docs/planning-docs.md): a `decision` atom whose only attribute is the decision's
// id. What was decided lives on the server (OrgHub's decisions table and append-only log), so editing the
// doc's text can't change it: the card draws live from host.decisions(), the way TaskEmbed draws from tasks.
//
// Host additions:
//   decisions(): Decision[] (the feed's, kept current by `decision.updated`)
//   onEvent("decision", msg): a client message to send as is: decision.propose / edit / accept / reject
//   me: the signed-in login (optional)
import { Node } from "@tiptap/core";
import { decisionSource } from "./make-tasks.js";

const el = (tag, attrs = {}, ...kids) => {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v == null || v === false) continue;
    if (k.startsWith("on")) e.addEventListener(k.slice(2), v);
    else if (k === "class") e.className = v;
    else e.setAttribute(k, v === true ? "" : v);
  }
  for (const k of kids.flat()) if (k != null && k !== false) e.append(k.nodeType ? k : String(k));
  return e;
};
const subscribe = (host, fn) => { host?.listeners?.add(fn); return () => host?.listeners?.delete(fn); };
const ownEvent = (e) => !!e.target.closest?.("input, textarea, select, button, a, [data-own]");
const when = (ms) => (ms ? new Date(ms).toLocaleString(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }) : "");
const uuid = () => crypto.randomUUID();
export const findDecision = (host, id) => (id ? host?.decisions?.().find((d) => d.id === id) ?? null : null);

/** A fresh proposal's content: a question to fill in and two options. */
/** What a decision card draws from. The tasks made from it are in it, so a new task or a state change in the feed
 * redraws the card (tasksChanged() runs the listeners without force). */
export function cardKey(host, id, d = findDecision(host, id)) {
  const made = d ? (host?.tasks?.() ?? []).filter((t) => t.fromDoc?.decision === d.id).map((t) => [t.id, t.state, t.title]) : [];
  return JSON.stringify([id, d, host?.editing?.has(id) ?? false, made]);
}

// What you've typed into a card and not sent yet (MF-414), per editor on host.drafts: decision id →
// { question, options, rationale, base } while its edit form is open (options as the textarea's text; base is
// what the form was opened with), plus { why, pick } for a proposed card's action row. The card's DOM is rebuilt
// from the feed, and a node view can be recreated by a collaborative change, so the inputs can't be the only copy.
const optionsText = (d) => (d?.options ?? []).map((o) => o.label).join("\n");
const editSeed = (d) => ({ question: d?.question ?? "", options: optionsText(d), rationale: d?.rationale ?? "" });

/** The draft for a decision's edit form: the one being typed, else seeded (once) from the decision. */
export function draftFor(host, d) {
  const cur = host?.drafts?.get(d.id);
  if (cur?.base) return cur;
  const seed = editSeed(d);
  const draft = { ...cur, ...seed, base: seed };
  if (host) (host.drafts ??= new Map()).set(d.id, draft);
  return draft;
}

/** Merges typed values into a decision's draft. */
export function setDraft(host, id, patch) {
  if (!host) return null;
  const draft = { ...host.drafts?.get(id), ...patch };
  (host.drafts ??= new Map()).set(id, draft);
  return draft;
}

/** Drops a decision's draft; `part: "edit"` drops only the edit form's fields (Save, Cancel) and keeps why / pick. */
export function clearDraft(host, id, part = null) {
  const cur = host?.drafts?.get(id);
  if (!cur) return;
  const rest = {};
  if (part === "edit") for (const k of ["why", "pick"]) if (cur[k] != null && cur[k] !== "") rest[k] = cur[k];
  if (Object.keys(rest).length) host.drafts.set(id, rest);
  else host.drafts.delete(id);
}

/** Whether the server's copy has moved on from what the edit form was opened with. */
export function draftDiffers(draft, d) {
  if (!draft?.base || !d) return false;
  const now = editSeed(d);
  return now.question !== draft.base.question || now.options !== draft.base.options || now.rationale !== draft.base.rationale;
}

const STALE = "This decision changed while you were editing. Saving replaces it with your version.";

/** The option picker's choices, from the decision; what you picked wins while it's still an option. */
function fillPick(pick, d, host) {
  const opts = JSON.stringify(d.options.map((o) => [o.id, o.label]));
  if (pick.dataset.opts !== opts) {
    pick.dataset.opts = opts;
    pick.replaceChildren(el("option", { value: "" }, "Choose an option…"), ...d.options.map((o) => el("option", { value: o.id }, o.label)));
  }
  const picked = host?.drafts?.get(d.id)?.pick;
  pick.value = picked != null && (picked === "" || d.options.some((o) => o.id === picked)) ? picked : d.chosen ?? "";
}

/** A background redraw of a proposed card keeps the part you type in (the edit form, or the action row) and
 * replaces everything around it, so the text, caret and focus stay. False when there's nothing to keep. */
function redrawAround(dom, next, d, host, editing) {
  const sel = editing ? ".doc-decision-form" : ".doc-decision-actions";
  const body = dom.firstElementChild;
  const kept = [...(body?.children ?? [])].find((c) => c.matches(sel));
  const fresh = [...next.children].find((c) => c.matches(sel));
  if (!kept || !fresh) return false;
  const kids = [...next.childNodes];
  const i = kids.indexOf(fresh);
  for (const c of [...body.childNodes]) if (c !== kept) c.remove();
  kept.before(...kids.slice(0, i));
  kept.after(...kids.slice(i + 1));
  if (editing) kept.querySelector(".doc-decision-stale").hidden = !draftDiffers(host?.drafts?.get(d.id), d);
  else fillPick(kept.querySelector(".doc-decision-pick"), d, host);
  return true;
}

export function draftDecision(from = null) {
  if (from) return { question: from.question, options: from.options.map((o) => ({ id: uuid().slice(0, 8), label: o.label, note: o.note ?? null })), chosen: null, rationale: "" };
  return { question: "What are we deciding?", options: [{ id: uuid().slice(0, 8), label: "Option 1", note: null }, { id: uuid().slice(0, 8), label: "Option 2", note: null }], chosen: null, rationale: "" };
}

/** Inserts a decision embed at the selection and proposes it (the id is made here, so the node goes in first). */
export function proposeDecision(editor, host, { supersedes = null, at = null, from = null } = {}) {
  const id = uuid();
  const content = { type: "decision", attrs: { id } };
  const chain = editor.chain().focus();
  (at == null ? chain.insertContent(content) : chain.insertContentAt(at, content)).run();
  host?.editing?.add(id);
  host?.onEvent?.("decision", { type: "decision.propose", id, doc: host.docId, ...draftDecision(from), supersedes });
  return id;
}

function card(d, id, host, ctx) {
  // Not in the feed (yet, or the propose was refused): offer to take the orphan card out of the doc.
  if (!d) return el("div", { class: "doc-decision-body" }, el("div", { class: "doc-decision-head" }, el("span", { class: "doc-decision-kind" }, "Decision"), el("span", { class: "muted" }, "Saving…"),
    el("button", { type: "button", class: "doc-btn ghost", "data-decision-remove": "", onclick: () => ctx.remove() }, "Remove")));
  const send = (msg) => host?.onEvent?.("decision", msg);
  const head = el("div", { class: "doc-decision-head" },
    el("span", { class: "doc-decision-kind" }, "Decision"),
    el("span", { class: `doc-pill decision-${d.status}`, "data-status": d.status }, d.status),
    el("span", { class: "doc-decision-who muted" },
      d.status === "proposed" ? `Proposed by @${d.proposedBy}${d.agent ? ` (${d.agent})` : ""} · ${when(d.proposedAt)}`
        : `${d.status === "rejected" ? "Rejected" : "Accepted"} by @${d.decidedBy} · ${when(d.decidedAt)}`));
  if (host?.editing?.has(id) && d.status === "proposed") return el("div", { class: "doc-decision-body" }, head, editForm(d, host, ctx));
  const options = el("ul", { class: "doc-decision-options" }, d.options.map((o) =>
    el("li", { class: o.id === d.chosen ? "chosen" : "" }, el("span", { class: "doc-decision-mark" }, o.id === d.chosen ? "✓" : "○"), el("span", {}, o.label), o.note ? el("span", { class: "muted" }, ` — ${o.note}`) : null)));
  const links = [];
  if (d.supersedes) links.push(el("a", { href: `#decision-${d.supersedes}`, "data-decision-link": d.supersedes }, "Supersedes an earlier decision"));
  if (d.supersededBy) links.push(el("a", { href: `#decision-${d.supersededBy}`, "data-decision-link": d.supersededBy }, "Superseded by a newer decision"));
  const body = el("div", { class: "doc-decision-body" },
    head,
    el("div", { class: "doc-decision-question" }, d.question),
    options,
    d.rationale ? el("div", { class: "doc-decision-rationale" }, d.rationale) : null,
    d.why ? el("div", { class: "doc-decision-why" }, el("strong", {}, "Why: "), d.why) : null,
    links.length ? el("div", { class: "doc-decision-links" }, links) : null);
  if (d.status === "proposed") {
    const why = el("input", { class: "doc-decision-why-input", placeholder: "Why? (optional)", "aria-label": "Why", oninput: () => setDraft(host, d.id, { why: why.value }) });
    why.value = host?.drafts?.get(d.id)?.why ?? "";
    const pick = el("select", { class: "doc-decision-pick", "aria-label": "Chosen option", onchange: () => setDraft(host, d.id, { pick: pick.value }) });
    fillPick(pick, d, host);
    const decide = (msg) => { clearDraft(host, d.id); send(msg); };
    body.append(el("div", { class: "doc-decision-actions" },
      pick, why,
      el("button", { type: "button", class: "doc-btn primary", onclick: () => decide({ type: "decision.accept", id: d.id, chosen: pick.value || null, why: why.value.trim() || null }) }, "Accept"),
      el("button", { type: "button", class: "doc-btn", onclick: () => decide({ type: "decision.reject", id: d.id, why: why.value.trim() || null }) }, "Reject"),
      el("button", { type: "button", class: "doc-btn ghost", onclick: () => { host.editing?.add(d.id); ctx.redraw(true); } }, "Edit")));
  } else if (d.status === "accepted") {
    // MF-368: the tasks made from it, live from the feed, and Make tasks.
    const made = (host?.tasks?.() ?? []).filter((t) => t.fromDoc?.decision === d.id);
    if (made.length) body.append(el("ul", { class: "doc-decision-tasks" }, made.map((t) =>
      el("li", {}, el("a", { href: `#/t/${t.id}`, "data-task-link": t.id }, t.id), ` ${t.title ?? ""} `, el("span", { class: `doc-pill state-${t.state}`, "data-state": t.state }, t.state)))));
    body.append(el("div", { class: "doc-decision-actions" },
      host?.sendCommand ? el("button", { type: "button", class: "doc-btn", "data-decision-maketasks": "", onclick: () => host.makeTasks?.(decisionSource(d)) }, "Make tasks") : null,
      el("button", { type: "button", class: "doc-btn", onclick: () => ctx.supersede(d) }, "Supersede")));
  }
  return body;
}

function editForm(d, host, ctx) {
  const draft = draftFor(host, d);
  const typed = (field) => (e) => setDraft(host, d.id, { [field]: e.target.value });
  const question = el("input", { class: "doc-decision-q-input", value: draft.question, "aria-label": "Question", maxlength: 500, oninput: typed("question") });
  const options = el("textarea", { class: "doc-decision-o-input", rows: Math.max(2, d.options.length, draft.options.split("\n").length), "aria-label": "Options, one per line", oninput: typed("options") });
  options.value = draft.options;
  const rationale = el("textarea", { class: "doc-decision-r-input", rows: 3, placeholder: "Rationale", "aria-label": "Rationale", oninput: typed("rationale") });
  rationale.value = draft.rationale;
  const close = () => { host.editing?.delete(d.id); clearDraft(host, d.id, "edit"); };
  const save = () => {
    const now = findDecision(host, d.id) ?? d; // the form outlives redraws: option ids and notes come from the current copy
    const labels = options.value.split("\n").map((s) => s.trim()).filter(Boolean);
    const opts = labels.map((label, i) => ({ id: now.options[i]?.id ?? uuid().slice(0, 8), label, note: now.options[i]?.label === label ? now.options[i].note ?? null : null }));
    const chosen = opts.some((o) => o.id === now.chosen) ? now.chosen : null;
    close();
    host?.onEvent?.("decision", { type: "decision.edit", id: d.id, question: question.value, options: opts, chosen, rationale: rationale.value });
    ctx.redraw(true);
  };
  return el("div", { class: "doc-decision-form" },
    el("label", {}, "Question", question),
    el("label", {}, "Options (one per line, 2–10)", options),
    el("label", {}, "Rationale", rationale),
    el("div", { class: "doc-decision-stale muted", role: "status", hidden: !draftDiffers(draft, d) }, STALE),
    el("div", { class: "doc-decision-actions" },
      el("button", { type: "button", class: "doc-btn primary", onclick: save }, "Save"),
      el("button", { type: "button", class: "doc-btn ghost", onclick: () => { close(); ctx.redraw(true); } }, "Cancel")));
}

export const DecisionEmbed = Node.create({
  name: "decision",
  group: "block",
  atom: true,
  selectable: true,
  draggable: true,
  addOptions: () => ({ host: null }),
  addAttributes: () => ({ id: { default: null, parseHTML: (e) => e.getAttribute("data-decision") } }),
  parseHTML: () => [{ tag: "div[data-type=decision]" }],
  renderHTML: ({ node }) => ["div", { "data-type": "decision", "data-decision": node.attrs.id, class: "doc-decision" }, node.attrs.id ?? ""],
  addNodeView() {
    const host = this.options.host;
    if (host && !host.editing) host.editing = new Set();
    if (host && !host.drafts) host.drafts = new Map();
    return ({ node, editor, getPos }) => {
      let current = node;
      const dom = el("div", { class: "doc-decision", "data-type": "decision", contenteditable: "false" });
      let last = "";
      const ctx = {
        redraw: (force) => draw(force),
        remove: () => {
          const pos = getPos();
          if (typeof pos === "number") editor.chain().focus().deleteRange({ from: pos, to: pos + current.nodeSize }).run();
        },
        supersede: (d) => {
          const pos = getPos();
          if (typeof pos === "number") proposeDecision(editor, host, { supersedes: d.id, at: pos + current.nodeSize, from: d });
        },
      };
      const draw = (force = false) => {
        const id = current.attrs.id;
        const d = findDecision(host, id);
        // Decided (or superseded) while its form was open: the form closes and what was typed goes.
        if (d && d.status !== "proposed") { host?.editing?.delete(id); clearDraft(host, id); }
        const key = cardKey(host, id, d);
        if (key === last && !force) return;
        last = key;
        dom.id = `decision-${current.attrs.id ?? ""}`;
        dom.dataset.decision = current.attrs.id ?? "";
        dom.dataset.status = d?.status ?? "";
        const next = card(d, id, host, ctx);
        // Only Edit, Save and Cancel (forced) replace the inputs; a feed update redraws around them (MF-414).
        if (!force && d?.status === "proposed" && redrawAround(dom, next, d, host, host?.editing?.has(id) ?? false)) return;
        dom.replaceChildren(next);
      };
      dom.addEventListener("click", (e) => {
        const a = e.target.closest?.("[data-decision-link]");
        if (!a) return;
        e.preventDefault();
        const target = dom.ownerDocument.getElementById(`decision-${a.dataset.decisionLink}`);
        if (target) { target.scrollIntoView({ block: "center", behavior: "smooth" }); flash(target); }
      });
      draw();
      const off = subscribe(host, draw);
      return {
        dom,
        update(next) { if (next.type !== current.type) return false; current = next; draw(); return true; },
        stopEvent: ownEvent,
        ignoreMutation: () => true,
        destroy: off,
      };
    };
  },
});

/** Briefly highlights a decision card (a #/docs/<id>?decision=<id> link, or a supersede link). */
export function flash(dom) {
  dom.classList.remove("doc-decision-flash");
  void dom.offsetWidth;
  dom.classList.add("doc-decision-flash");
  setTimeout(() => dom.classList.remove("doc-decision-flash"), 2000);
}

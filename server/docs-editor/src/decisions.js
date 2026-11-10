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
    const why = el("input", { class: "doc-decision-why-input", placeholder: "Why? (optional)", "aria-label": "Why" });
    const pick = el("select", { class: "doc-decision-pick", "aria-label": "Chosen option" },
      el("option", { value: "" }, "Choose an option…"), d.options.map((o) => el("option", { value: o.id, selected: o.id === d.chosen }, o.label)));
    body.append(el("div", { class: "doc-decision-actions" },
      pick, why,
      el("button", { type: "button", class: "doc-btn primary", onclick: () => send({ type: "decision.accept", id: d.id, chosen: pick.value || null, why: why.value.trim() || null }) }, "Accept"),
      el("button", { type: "button", class: "doc-btn", onclick: () => send({ type: "decision.reject", id: d.id, why: why.value.trim() || null }) }, "Reject"),
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
  const question = el("input", { class: "doc-decision-q-input", value: d.question, "aria-label": "Question", maxlength: 500 });
  const options = el("textarea", { class: "doc-decision-o-input", rows: Math.max(2, d.options.length), "aria-label": "Options, one per line" });
  options.value = d.options.map((o) => o.label).join("\n");
  const rationale = el("textarea", { class: "doc-decision-r-input", rows: 3, placeholder: "Rationale", "aria-label": "Rationale" });
  rationale.value = d.rationale ?? "";
  const save = () => {
    const labels = options.value.split("\n").map((s) => s.trim()).filter(Boolean);
    const opts = labels.map((label, i) => ({ id: d.options[i]?.id ?? uuid().slice(0, 8), label, note: d.options[i]?.label === label ? d.options[i].note ?? null : null }));
    const chosen = opts.some((o) => o.id === d.chosen) ? d.chosen : null;
    host.editing?.delete(d.id);
    host?.onEvent?.("decision", { type: "decision.edit", id: d.id, question: question.value, options: opts, chosen, rationale: rationale.value });
    ctx.redraw(true);
  };
  return el("div", { class: "doc-decision-form" },
    el("label", {}, "Question", question),
    el("label", {}, "Options (one per line, 2–10)", options),
    el("label", {}, "Rationale", rationale),
    el("div", { class: "doc-decision-actions" },
      el("button", { type: "button", class: "doc-btn primary", onclick: save }, "Save"),
      el("button", { type: "button", class: "doc-btn ghost", onclick: () => { host.editing?.delete(d.id); ctx.redraw(true); } }, "Cancel")));
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
        const d = findDecision(host, current.attrs.id);
        const key = JSON.stringify([current.attrs.id, d, host?.editing?.has(current.attrs.id)]);
        if (key === last && !force) return;
        last = key;
        dom.id = `decision-${current.attrs.id ?? ""}`;
        dom.dataset.decision = current.attrs.id ?? "";
        dom.dataset.status = d?.status ?? "";
        dom.replaceChildren(card(d, current.attrs.id, host, ctx));
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

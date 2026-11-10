// Make tasks (MF-368, docs/planning-docs.md): a selection, a heading's section or an accepted decision becomes
// draft tasks. The dialog is prefilled from the editor's own Markdown serializer and split with the same code the
// server uses (split.js); it sends `doc.makeTasks` through the host's command channel, and the server checks the
// source, makes the drafts and inserts live task embeds after it.
import { Extension } from "@tiptap/core";
import { Plugin, PluginKey } from "@tiptap/pm/state";
import { Decoration, DecorationSet } from "@tiptap/pm/view";
import { toMarkdown } from "./markdown.js";
import { anchorFromRange, mappingOf } from "./comments.js";
import { splitSection, MAX_TASKS } from "./split.js";

const el = (tag, attrs = {}, ...kids) => {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v == null || v === false) continue;
    if (k.startsWith("on")) e.addEventListener(k.slice(2), v);
    else if (k === "class") e.className = v;
    else if (k === "value") e.value = v;
    else e.setAttribute(k, v === true ? "" : v);
  }
  for (const k of kids.flat()) if (k != null && k !== false) e.append(k.nodeType ? k : String(k));
  return e;
};

const md = (state, nodes) => toMarkdown(state.schema.topNodeType.create(null, nodes)).trim();

/** A heading's section in the editor: from the heading at `pos` to the next heading of the same or higher level. */
export function headingSource(editor, ydoc, pos) {
  const { state } = editor;
  const heading = state.doc.nodeAt(pos);
  if (!heading || heading.type.name !== "heading") return null;
  const nodes = [];
  let started = false;
  state.doc.forEach((node, offset) => {
    if (offset === pos) started = true;
    else if (started && node.type.name === "heading" && node.attrs.level <= heading.attrs.level) started = null;
    if (started) nodes.push(node);
  });
  return {
    anchor: anchorFromRange(ydoc, mappingOf(state), state.doc, pos + 1, pos + heading.nodeSize - 1),
    markdown: md(state, nodes), heading: heading.textContent.trim(), decision: null,
  };
}

/** The selection: its text, or the blocks it spans. */
export function selectionSource(editor, ydoc) {
  const { state } = editor;
  const { from, to } = state.selection;
  if (from === to) return null;
  const blocks = [];
  state.doc.nodesBetween(from, to, (node, pos) => { if (pos + node.nodeSize > from) blocks.push(node); return false; });
  let heading = null;
  state.doc.forEach((node, offset) => { if (offset < from && node.type.name === "heading") heading = node.textContent.trim(); });
  const text = state.doc.textBetween(from, to, "\n", " ").trim();
  return { anchor: anchorFromRange(ydoc, mappingOf(state), state.doc, from, to), markdown: blocks.length > 1 ? md(state, blocks) : text, heading, decision: null };
}

/** An accepted decision: its question, choice and rationale. */
export function decisionSource(d) {
  const chosen = d.options.find((o) => o.id === d.chosen);
  const markdown = [`Decision: ${d.question}`, chosen ? `Chosen: ${chosen.label}${chosen.note ? ` — ${chosen.note}` : ""}` : null, d.rationale ? `\n${d.rationale}` : null].filter(Boolean).join("\n");
  return { anchor: null, markdown, heading: chosen?.label ?? d.question, decision: d.id };
}

/** Opens the Make tasks dialog for `source` ({anchor, decision, markdown, heading}). */
export function openMakeTasks(host, source) {
  if (!source || !host?.sendCommand) return;
  document.querySelector(".doc-maketasks")?.remove();
  let mode = "one";
  let rows = [];
  const list = el("div", { class: "doc-maketasks-rows" });
  const chain = el("input", { type: "checkbox", class: "doc-maketasks-chain" });
  const effort = el("input", { class: "doc-maketasks-effort", placeholder: "Effort (optional)", value: source.heading ?? "", "aria-label": "Effort" });
  const goals = host.goals?.() ?? [];
  const needsGoal = !host.docGoal?.();
  const goal = needsGoal ? el("select", { class: "doc-maketasks-goal", "aria-label": "Goal" }, el("option", { value: "" }, "Pick a goal…"), goals.map((g) => el("option", { value: g.id }, g.name))) : null;
  const error = el("div", { class: "doc-maketasks-error", role: "alert" });
  const draw = () => {
    list.replaceChildren(...rows.map((r, i) => el("div", { class: "doc-maketasks-row" },
      el("input", { class: "doc-maketasks-title", value: r.title, "aria-label": `Task ${i + 1} title`, oninput: (e) => { r.title = e.target.value; } }),
      el("textarea", { class: "doc-maketasks-brief", rows: 3, "aria-label": `Task ${i + 1} brief`, oninput: (e) => { r.brief = e.target.value; } }, r.brief),
      el("button", { type: "button", class: "doc-btn ghost", title: "Remove", onclick: () => { rows.splice(i, 1); draw(); } }, "✕"))));
    submit.textContent = rows.length === 1 ? "Make 1 task" : `Make ${rows.length} tasks`;
  };
  const split = (m) => { mode = m; rows = splitSection(source.markdown, m, source.heading ?? ""); draw(); };
  const modes = el("div", { class: "doc-maketasks-modes", role: "radiogroup" }, [["one", "One task"], ["headings", "One per sub-heading"], ["items", "One per list item"]].map(([m, label]) =>
    el("label", {}, el("input", { type: "radio", name: "doc-maketasks-mode", value: m, checked: m === "one", onchange: () => split(m) }), ` ${label}`)));
  const close = () => dialog.remove();
  const submit = el("button", { type: "button", class: "doc-btn primary doc-maketasks-submit", onclick: () => {
    const tasks = rows.map((r) => ({ title: r.title.trim(), brief: r.brief.trim() })).filter((r) => r.title || r.brief);
    if (!tasks.length) return (error.textContent = "Add at least one task.");
    if (tasks.length > MAX_TASKS) return (error.textContent = `At most ${MAX_TASKS} tasks at once.`);
    if (tasks.some((t) => !t.title || !t.brief)) return (error.textContent = "Each task needs a title and a brief.");
    if (goal && !goal.value) return (error.textContent = "Pick the goal the tasks go in.");
    host.sendCommand({
      type: "doc.makeTasks", doc: host.docId, anchor: source.anchor ?? null, decision: source.decision ?? null,
      goal: goal?.value || null, tasks, chain: tasks.length > 1 && chain.checked, effort: effort.value.trim() || null,
    });
    close();
  } }, "Make 1 task");
  const dialog = el("div", { class: "doc-maketasks", role: "dialog", "aria-label": "Make tasks", onkeydown: (e) => { if (e.key === "Escape") close(); } },
    el("div", { class: "doc-maketasks-card" },
      el("div", { class: "doc-maketasks-head" }, el("strong", {}, "Make tasks"), el("span", { class: "muted" }, source.decision ? " from this decision" : source.heading ? ` from “${source.heading}”` : " from the selection")),
      modes, list,
      el("label", { class: "doc-maketasks-opt" }, chain, " Each waits on the one before"),
      effort, goal, error,
      el("div", { class: "doc-maketasks-actions" }, el("button", { type: "button", class: "doc-btn ghost", onclick: close }, "Cancel"), submit)));
  document.body.append(dialog);
  split(mode);
  dialog.querySelector("input,textarea")?.focus();
}

/** A "Make tasks" action at the end of each heading, shown on hover (editor.css). */
export const HeadingMakeTasks = (host, ydoc, getEditor) => Extension.create({
  name: "headingMakeTasks",
  addProseMirrorPlugins: () => [new Plugin({
    key: new PluginKey("headingMakeTasks"),
    props: {
      decorations(state) {
        if (!host.sendCommand) return null;
        const decos = [];
        state.doc.forEach((node, offset) => {
          if (node.type.name !== "heading" || !node.textContent.trim()) return;
          decos.push(Decoration.widget(offset + node.nodeSize - 1, () => {
            const b = el("button", { type: "button", class: "doc-heading-maketasks", contenteditable: "false", title: "Make tasks from this section" }, "Make tasks");
            b.addEventListener("mousedown", (e) => { e.preventDefault(); e.stopPropagation(); openMakeTasks(host, headingSource(getEditor(), ydoc, offset)); });
            return b;
          }, { side: 1, ignoreSelection: true, key: `mt-${offset}-${node.attrs.level}` }));
        });
        return DecorationSet.create(state.doc, decos);
      },
    },
  })],
});

// The docs editor's menus: a slash (`/`) block menu, `@` member and `#` task suggestion menus, and a
// bubble menu on selection. Small DOM-only renderers, styled by editor.css from app.css's tokens.
import { Extension } from "@tiptap/core";
import Suggestion from "@tiptap/suggestion";
import { PluginKey } from "@tiptap/pm/state";

/** A floating list under the caret for @tiptap/suggestion: ↑/↓ to move, ↵/⇥ to pick, esc to close. */
export function listRenderer(label) {
  return () => {
    let el, items = [], index = 0, command;
    const draw = () => {
      el.replaceChildren(
        ...(items.length
          ? items.map((item, i) => {
              const b = document.createElement("button");
              b.type = "button";
              b.className = "doc-menu-item" + (i === index ? " on" : "");
              b.innerHTML = "";
              if (item.icon) { const s = document.createElement("span"); s.className = "doc-menu-icon"; s.textContent = item.icon; b.append(s); }
              const t = document.createElement("span"); t.textContent = label(item); b.append(t);
              if (item.hint) { const h = document.createElement("span"); h.className = "doc-menu-hint"; h.textContent = item.hint; b.append(h); }
              b.addEventListener("mousedown", (e) => { e.preventDefault(); command(item); });
              return b;
            })
          : [Object.assign(document.createElement("div"), { className: "doc-menu-empty", textContent: "No matches" })]),
      );
    };
    const place = (rect) => {
      const r = rect?.();
      if (!r) return;
      el.style.left = `${Math.max(8, Math.min(r.left + scrollX, innerWidth - 280))}px`;
      el.style.top = `${r.bottom + scrollY + 6}px`;
    };
    return {
      onStart(props) {
        el = document.createElement("div");
        el.className = "doc-menu";
        document.body.append(el);
        items = props.items; index = 0; command = props.command;
        draw(); place(props.clientRect);
      },
      onUpdate(props) { items = props.items; index = 0; command = props.command; draw(); place(props.clientRect); },
      onKeyDown({ event }) {
        if (event.key === "Escape") { el?.remove(); el = null; return true; }
        if (!items.length) return false;
        if (event.key === "ArrowDown") { index = (index + 1) % items.length; draw(); return true; }
        if (event.key === "ArrowUp") { index = (index + items.length - 1) % items.length; draw(); return true; }
        if (event.key === "Enter" || event.key === "Tab") { command(items[index]); return true; }
        return false;
      },
      onExit() { el?.remove(); el = null; },
    };
  };
}

export const SLASH_ITEMS = [
  { title: "Heading 1", icon: "H1", run: (c) => c.setNode("heading", { level: 1 }) },
  { title: "Heading 2", icon: "H2", run: (c) => c.setNode("heading", { level: 2 }) },
  { title: "Heading 3", icon: "H3", run: (c) => c.setNode("heading", { level: 3 }) },
  { title: "Bullet list", icon: "•", run: (c) => c.toggleBulletList() },
  { title: "Numbered list", icon: "1.", run: (c) => c.toggleOrderedList() },
  { title: "Task list", icon: "☐", run: (c) => c.toggleTaskList() },
  { title: "Quote", icon: "❝", run: (c) => c.toggleBlockquote() },
  { title: "Code block", icon: "</>", run: (c) => c.toggleCodeBlock() },
  { title: "Divider", icon: "—", run: (c) => c.setHorizontalRule() },
  // Planning visuals (MF-363)
  { title: "Diagram", icon: "◇", hint: "Mermaid", run: (c) => c.insertContent({ type: "mermaid", attrs: { source: "flowchart LR\n  A[Idea] --> B[Plan] --> C[Build]" } }) },
  { title: "Table", icon: "▦", run: (c) => c.insertTable({ rows: 3, cols: 3, withHeaderRow: true }) },
  { title: "Chart", icon: "▂▅", hint: "of the table above", run: (c) => c.insertContent({ type: "chart", attrs: { kind: "bar" } }) },
  { title: "Image", icon: "▣", run: (c, editor) => { setTimeout(() => editor.storage.docVisuals?.pick("image/png,image/jpeg,image/gif,image/webp")); return c; } },
  { title: "File", icon: "📎", run: (c, editor) => { setTimeout(() => editor.storage.docVisuals?.pick("")); return c; } },
  { title: "Callout", icon: "!", run: (c) => c.wrapIn("callout", { tone: "note" }) },
  { title: "Toggle", icon: "▸", run: (c) => c.wrapIn("toggle", { summary: "", open: true }) },
  { title: "Task embed", icon: "#", hint: "live card", run: (c, editor) => { if (editor.storage.docVisuals) editor.storage.docVisuals.embedNext = true; return c.insertContent("#"); } },
  // MF-367: a reviewable decision, proposed on the server once inserted (only when the host can send it).
  { title: "Decision", icon: "⚖", hint: "propose · accept", run: (c, editor) => { const v = editor.storage.docVisuals; if (v?.decide) setTimeout(() => v.decide()); return c; } },
];

/** `/` at the start of a word opens the block menu. */
export const SlashMenu = Extension.create({
  name: "slashMenu",
  addProseMirrorPlugins() {
    return [
      Suggestion({
        editor: this.editor,
        pluginKey: new PluginKey("slashMenu"),
        char: "/",
        startOfLine: false,
        allow: ({ state, range }) => !state.doc.resolve(range.from).parent.type.spec.code,
        items: ({ query }) => SLASH_ITEMS.filter((i) => i.title.toLowerCase().includes(query.toLowerCase())),
        command: ({ editor, range, props }) => props.run(editor.chain().focus().deleteRange(range), editor).run(),
        render: listRenderer((i) => i.title),
      }),
    ];
  },
});

/** Mention suggestion configs: `@` for members, `#` for tasks by id or title. */
export function mentionSuggestions({ members, tasks }) {
  return [
    {
      char: "@",
      pluginKey: new PluginKey("memberMention"),
      items: ({ query }) => {
        const q = query.toLowerCase();
        return members().filter((m) => m.login.toLowerCase().startsWith(q) || (m.name ?? "").toLowerCase().includes(q)).slice(0, 8)
          .map((m) => ({ id: m.login, label: m.name || m.login, hint: m.name ? `@${m.login}` : "" }));
      },
      render: listRenderer((i) => i.label),
    },
    {
      char: "#",
      pluginKey: new PluginKey("taskMention"),
      items: ({ query }) => {
        const q = query.toLowerCase();
        return tasks().filter((t) => t.id.toLowerCase().startsWith(q) || (t.title ?? "").toLowerCase().includes(q)).slice(0, 8)
          .map((t) => ({ id: t.id, title: t.title, hint: t.id }));
      },
      // A task inserts a taskRef node, not a mention; after the slash menu's "Task embed", a live card.
      command: ({ editor, range, props }) => {
        const v = editor.storage.docVisuals;
        if (v?.embedNext) { v.embedNext = false; return editor.chain().focus().insertContentAt(range, { type: "taskEmbed", attrs: { id: props.id } }).run(); }
        return editor.chain().focus().insertContentAt(range, [{ type: "taskRef", attrs: { id: props.id, title: props.title } }, { type: "text", text: " " }]).run();
      },
      render: listRenderer((i) => i.title || i.id),
    },
  ];
}

/** The bubble menu's buttons over a text selection. */
export function bubbleMenuElement(editor, onComment = null) {
  const el = document.createElement("div");
  el.className = "doc-bubble";
  const buttons = [
    { label: "B", title: "Bold", active: "bold", run: (c) => c.toggleBold() },
    { label: "I", title: "Italic", active: "italic", run: (c) => c.toggleItalic() },
    { label: "S", title: "Strikethrough", active: "strike", run: (c) => c.toggleStrike() },
    { label: "</>", title: "Code", active: "code", run: (c) => c.toggleCode() },
    { label: "Link", title: "Link", active: "link", run: (c) => {
        if (editor.isActive("link")) return c.unsetLink();
        const href = prompt("Link to", "https://");
        return href ? c.extendMarkRange("link").setLink({ href }) : c;
      } },
    { label: "H2", title: "Heading", active: ["heading", { level: 2 }], run: (c) => c.toggleHeading({ level: 2 }) },
    { label: "❝", title: "Quote", active: "blockquote", run: (c) => c.toggleBlockquote() },
    // In a table: add and delete rows and columns.
    { label: "+Row", title: "Add row", table: true, run: (c) => c.addRowAfter() },
    { label: "+Col", title: "Add column", table: true, run: (c) => c.addColumnAfter() },
    { label: "−Row", title: "Delete row", table: true, run: (c) => c.deleteRow() },
    { label: "−Col", title: "Delete column", table: true, run: (c) => c.deleteColumn() },
    // MF-364: start a comment thread on the selection.
    ...(onComment ? [{ label: "Comment", title: "Comment", comment: true }] : []),
  ].map((b) => {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.textContent = b.label;
    btn.title = b.title;
    btn.className = `doc-bubble-${b.title.toLowerCase().replace(/\s+/g, "-")}`;
    btn.addEventListener("mousedown", (e) => { e.preventDefault(); if (b.comment) onComment(); else b.run(editor.chain().focus()).run(); });
    el.append(btn);
    return { btn, b };
  });
  const sync = () => {
    const inTable = editor.isActive("table");
    buttons.forEach(({ btn, b }) => {
      if (b.comment) return;
      if (b.table) btn.hidden = !inTable;
      else btn.classList.toggle("on", editor.isActive(...[].concat(b.active)));
    });
  };
  editor.on("selectionUpdate", sync);
  editor.on("transaction", sync);
  return el;
}

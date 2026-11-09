// Code blocks with syntax highlighting and a language picker (MF-384). TipTap's CodeBlockLowlight colors the
// code through ProseMirror decorations, using every highlight.js grammar lowlight ships (~190). The language
// lives in the node's `language` attr exactly as the Markdown fence wrote it (```ts stays `ts`), so fences
// round-trip unchanged; the picker only ever writes a grammar id, or null for Plain text.
// The schema parts load in Node (the Markdown tests); the node view only runs in the browser.
import CodeBlockLowlight from "@tiptap/extension-code-block-lowlight";
import hljs from "highlight.js/lib/core";
import { all, createLowlight } from "lowlight";

export const lowlight = createLowlight(all);

// Plain text and anything we can't name are never guessed at: lowlight's auto-detect (what the plugin runs
// for an unknown language) is swapped for no highlighting at all.
const noGuess = { ...lowlight, highlightAuto: (code) => lowlight.highlight("plaintext", code) };

const PLAIN = new Set(["plaintext", "text", "txt", "plain"]);
const COMMON = ["typescript", "javascript", "swift", "go", "ruby", "python", "bash", "json", "yaml", "sql", "xml", "css", "markdown", "diff"];
// Grammars whose own names are missing or read oddly in a menu.
const LABELS = { bash: "Shell (Bash)", shell: "Shell session", xml: "HTML, XML", php: "PHP", "python-repl": "Python REPL", dsconfig: "dsconfig", ini: "TOML, INI" };

// Each grammar's display name and aliases, read once from the grammar definitions themselves.
const grammars = (() => {
  const h = hljs.newInstance();
  const names = {};
  const alias = {};
  for (const id of lowlight.listLanguages()) {
    const g = all[id]?.(h) ?? {};
    names[id] = LABELS[id] ?? g.name ?? id;
    alias[id] = id;
    for (const a of g.aliases ?? []) alias[String(a).toLowerCase()] ??= id;
  }
  const aliases = {};
  for (const [a, id] of Object.entries(alias)) (aliases[id] ??= []).push(a);
  return { names, alias, aliases };
})();

/** The picker's choices: Plain text (id null) first, then the common languages, then every other grammar A–Z. */
export const CODE_LANGUAGES = [
  { id: null, label: "Plain text" },
  ...COMMON.map((id) => ({ id, label: grammars.names[id] })),
  ...lowlight.listLanguages()
    .filter((id) => id !== "plaintext" && !COMMON.includes(id))
    .map((id) => ({ id, label: grammars.names[id] }))
    .sort((a, b) => a.label.localeCompare(b.label, "en", { sensitivity: "base" })),
];

/** A `language` attr as the picker sees it: null for Plain text (none, text, txt, plaintext), a grammar id
 *  for a known language or alias (`ts` → `typescript`), or undefined when lowlight doesn't know it. */
export function canonicalLanguage(attr) {
  const lang = String(attr ?? "").trim().toLowerCase();
  if (!lang || PLAIN.has(lang)) return null;
  const id = grammars.alias[lang];
  if (id) return id === "plaintext" ? null : id;
  return undefined;
}

/** The picker's choices matching what was typed: by name, id or alias (`ts`, `py`, `txt`), case-insensitive.
 *  Names that start with the query come first, then the rest in list order. An empty query lists them all. */
export function filterLanguages(query) {
  const q = String(query ?? "").trim().toLowerCase();
  if (!q) return CODE_LANGUAGES;
  const keys = (l) => [l.label.toLowerCase(), ...(l.id ? grammars.aliases[l.id] ?? [l.id] : [...PLAIN, "none"])];
  const scored = [];
  for (const l of CODE_LANGUAGES) {
    const k = keys(l);
    if (k.some((x) => x === q)) scored.push([0, l]);
    else if (k.some((x) => x.startsWith(q))) scored.push([1, l]);
    else if (k.some((x) => x.includes(q))) scored.push([2, l]);
  }
  return scored.sort((a, b) => a[0] - b[0]).map(([, l]) => l);
}

const labelFor = (attr) => {
  const id = canonicalLanguage(attr);
  return id === undefined ? `${attr} (unknown)` : id === null ? "Plain text" : grammars.names[id];
};

const h = (tag, cls) => {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  return e;
};

export const DocCodeBlock = CodeBlockLowlight.extend({
  // CodeBlock defaults the attr to `defaultLanguage`; keep it null so a new block exports as a bare ``` fence
  // (the plugin still treats null as plaintext: no highlighting).
  addAttributes() {
    const attrs = this.parent?.() ?? {};
    return { ...attrs, language: { ...attrs.language, default: null } };
  },
  addNodeView() {
    return ({ node, editor, getPos }) => {
      let current = node;
      // A button showing the language; clicking it opens a search box over the list (type to filter, arrows
      // to move, Enter to pick, Escape to close). An unknown attr shows as '<lang> (unknown)' and is never
      // rewritten unless someone picks a language.
      const button = h("button", "doc-code-lang");
      button.type = "button";
      button.setAttribute("aria-haspopup", "listbox");
      button.setAttribute("aria-label", "Code language");
      const search = h("input", "doc-code-search");
      search.type = "text";
      search.placeholder = "Search languages";
      search.spellcheck = false;
      search.setAttribute("aria-label", "Search languages");
      const list = h("div", "doc-code-list");
      list.setAttribute("role", "listbox");
      const pop = h("div", "doc-code-pop");
      pop.hidden = true;
      pop.append(search, list);
      let shown = [];
      let active = 0;
      const highlight = (i) => {
        active = Math.max(0, Math.min(i, shown.length - 1));
        [...list.children].forEach((c, n) => c.classList.toggle("on", n === active));
        list.children[active]?.scrollIntoView?.({ block: "nearest" });
      };
      const choose = (lang) => {
        close();
        const pos = getPos();
        if (typeof pos !== "number") return;
        const at = editor.state.doc.nodeAt(pos);
        if (at && canonicalLanguage(at.attrs.language) !== lang) editor.view.dispatch(editor.state.tr.setNodeMarkup(pos, null, { ...at.attrs, language: lang }));
        editor.commands.focus();
      };
      const render = () => {
        shown = filterLanguages(search.value);
        const mine = canonicalLanguage(current.attrs.language);
        list.replaceChildren(...shown.map((l, n) => {
          const item = h("div", "doc-code-item" + (l.id === mine ? " current" : ""));
          item.setAttribute("role", "option");
          item.textContent = l.label;
          item.addEventListener("mousedown", (e) => { e.preventDefault(); choose(l.id); });
          item.addEventListener("mousemove", () => { if (active !== n) highlight(n); });
          return item;
        }));
        if (!shown.length) list.append(Object.assign(h("div", "doc-code-empty"), { textContent: "No matching language" }));
        highlight(search.value ? 0 : Math.max(0, shown.findIndex((l) => l.id === mine)));
      };
      const onOutside = (e) => { if (!head.contains(e.target)) close(); };
      const open = () => {
        pop.hidden = false;
        search.value = "";
        render();
        search.focus();
        document.addEventListener("mousedown", onOutside, true);
      };
      const close = () => {
        if (pop.hidden) return;
        pop.hidden = true;
        document.removeEventListener("mousedown", onOutside, true);
      };
      button.addEventListener("click", () => (pop.hidden ? open() : close()));
      search.addEventListener("input", render);
      search.addEventListener("keydown", (e) => {
        if (e.key === "ArrowDown") { e.preventDefault(); highlight(active + 1); }
        else if (e.key === "ArrowUp") { e.preventDefault(); highlight(active - 1); }
        else if (e.key === "Enter") { e.preventDefault(); if (shown[active]) choose(shown[active].id); }
        else if (e.key === "Escape") { e.preventDefault(); close(); editor.commands.focus(); }
      });
      const head = h("div", "doc-code-head");
      head.contentEditable = "false";
      head.setAttribute("data-own", "");
      head.append(button, pop);
      const pre = document.createElement("pre");
      const code = document.createElement("code");
      pre.append(code);
      const dom = h("div", "doc-codeblock");
      dom.append(head, pre);
      const sync = () => { button.textContent = labelFor(current.attrs.language); };
      sync();
      return {
        dom,
        contentDOM: code,
        update(next) {
          if (next.type !== current.type) return false;
          const changed = next.attrs.language !== current.attrs.language;
          current = next;
          if (changed) { sync(); if (!pop.hidden) render(); }
          return true;
        },
        stopEvent: (e) => head.contains(e.target),
        ignoreMutation: (m) => m.type !== "selection" && !code.contains(m.target),
        destroy: () => document.removeEventListener("mousedown", onOutside, true),
      };
    };
  },
}).configure({ lowlight: noGuess, defaultLanguage: "plaintext" });

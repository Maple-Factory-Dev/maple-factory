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
  return { names, alias };
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
      const select = document.createElement("select");
      select.className = "doc-code-lang";
      select.setAttribute("aria-label", "Code language");
      for (const { id, label } of CODE_LANGUAGES) select.append(new Option(label, id ?? ""));
      let unknown = null; // the '<lang> (unknown)' option, while the attr is a language lowlight doesn't know
      const sync = () => {
        const attr = current.attrs.language;
        const id = canonicalLanguage(attr);
        unknown?.remove();
        unknown = null;
        if (id === undefined) {
          unknown = new Option(`${attr} (unknown)`, `?${attr}`);
          select.prepend(unknown);
          select.value = unknown.value;
        } else select.value = id ?? "";
      };
      select.addEventListener("change", () => {
        if (select.value.startsWith("?")) return;
        const pos = getPos();
        if (typeof pos !== "number") return;
        const at = editor.state.doc.nodeAt(pos);
        if (at) editor.view.dispatch(editor.state.tr.setNodeMarkup(pos, null, { ...at.attrs, language: select.value || null }));
      });
      const head = document.createElement("div");
      head.className = "doc-code-head";
      head.contentEditable = "false";
      head.setAttribute("data-own", "");
      head.append(select);
      const pre = document.createElement("pre");
      const code = document.createElement("code");
      pre.append(code);
      const dom = document.createElement("div");
      dom.className = "doc-codeblock";
      dom.append(head, pre);
      sync();
      return {
        dom,
        contentDOM: code,
        update(next) {
          if (next.type !== current.type) return false;
          const changed = next.attrs.language !== current.attrs.language;
          current = next;
          if (changed) sync();
          return true;
        },
        stopEvent: (e) => head.contains(e.target),
        ignoreMutation: (m) => m.type !== "selection" && !code.contains(m.target),
      };
    };
  },
}).configure({ lowlight: noGuess, defaultLanguage: "plaintext" });

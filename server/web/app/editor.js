// The Markdown editor for briefs, notes and comments: the Mac app's MarkdownEditor (MarkdownViews.swift)
// on the web. Write/Preview tabs, a toolbar that wraps the selection, ⌘B/⌘I/⌘K, and the same preview
// as everywhere else (markdown.js).
//
// applyFormat() is pure, so it's tested without a DOM; markdownEditor() builds through the app's h().

import { markdown } from "./markdown.js";

/** Wraps text[start, end) (or inserts at the cursor) the way GitHub's issue editor does, like
 *  MarkdownEditor.apply. Returns the new text, what replaced the selection, and where the cursor goes. */
export function applyFormat(text, start, end, format) {
  const selected = text.slice(start, end);
  const lineBreak = start === 0 || text[start - 1] === "\n" ? "" : "\n";
  const or = (fallback) => selected || fallback;
  const insert = {
    heading: `${lineBreak}## ${or("Heading")}`,
    bold: `**${or("bold")}**`,
    italic: `_${or("italic")}_`,
    code: selected.includes("\n") ? `\n\`\`\`\n${selected}\n\`\`\`\n` : `\`${or("code")}\``,
    link: `[${or("title")}](https://)`,
    bullet: `${lineBreak}- ${selected}`,
    numbered: `${lineBreak}1. ${selected}`,
    task: `${lineBreak}- [ ] ${selected}`,
    quote: `${lineBreak}> ${selected}`,
    mention: "@",
  }[format];
  if (insert == null) throw new Error(`unknown format ${format}`);
  return { text: text.slice(0, start) + insert + text.slice(end), insert, cursor: start + insert.length };
}

// Icons drawn in a 16-point box, stroked like SF Symbols at a small size.
const ICONS = {
  heading: "M3 3v10M10 3v10M3 8h7M12.5 8.5l1.5-1v5.5",
  bold: "M4.5 3h4a2.5 2.5 0 0 1 0 5h-4zM4.5 8h4.75a2.5 2.5 0 0 1 0 5H4.5z",
  italic: "M7 3h5M4 13h5M10 3 6.5 13",
  code: "M5.5 4.5 2 8l3.5 3.5M10.5 4.5 14 8l-3.5 3.5M9 3 7 13",
  link: "M7 9a3 3 0 0 0 4.2.3l2-2a3 3 0 0 0-4.2-4.2l-1 1M9 7a3 3 0 0 0-4.2-.3l-2 2a3 3 0 0 0 4.2 4.2l1-1",
  bullet: "M6 4h8M6 8h8M6 12h8M2.5 4h.01M2.5 8h.01M2.5 12h.01",
  numbered: "M7 4h7M7 8h7M7 12h7M2 3l1-.5V6M2 9.5c0-.6.5-1 1-1s1 .4 1 1-1 1.2-2 2h2",
  task: "M2 3.5l1 1 2-2M2 8.5l1 1 2-2M2 13l1 1 2-2M7.5 4h6.5M7.5 9h6.5M7.5 13.5h6.5",
  quote: "M3 7h3v4H3zM3 7c0-2 1-3 3-3.5M10 7h3v4h-3zM10 7c0-2 1-3 3-3.5",
  mention: "M10.5 8a2.5 2.5 0 1 1-5 0 2.5 2.5 0 0 1 5 0zM10.5 8v1.2a1.8 1.8 0 0 0 3.5.3A6 6 0 1 0 11 13.2",
};
const TOOLS = [
  ["heading", "Heading"], ["bold", "Bold (⌘B)"], ["italic", "Italic (⌘I)"], ["code", "Code"], ["link", "Link (⌘K)"], null,
  ["bullet", "Bulleted list"], ["numbered", "Numbered list"], ["task", "Task list"], ["quote", "Quote"], null,
  ["mention", "Mention"],
];
const KEYS = { b: "bold", i: "italic", k: "link" };

function icon(d) {
  const ns = "http://www.w3.org/2000/svg";
  const svg = document.createElementNS(ns, "svg");
  svg.setAttribute("viewBox", "0 0 16 16");
  svg.setAttribute("aria-hidden", "true");
  const path = document.createElementNS(ns, "path");
  path.setAttribute("d", d);
  svg.append(path);
  return svg;
}

/** The editor: a card with Write/Preview tabs and the toolbar, the text box, and a footer. The box is
 *  `.textarea`; `.clear()` empties it and goes back to Write. Every change fires the box's input
 *  event, so callers' oninput (and their dirty tracking) see toolbar edits too. */
export function markdownEditor({ value = "", placeholder = "Write in Markdown…", rows = 8, minHeight, oninput, onblur, onsubmit, keep } = {}, h) {
  const box = h("textarea", { class: "md-input", placeholder, rows, oninput, onblur, style: minHeight ? `min-height:${minHeight}` : null });
  box.value = value;
  const preview = h("div", { class: "md-preview", hidden: true });
  let previewing = false;

  const apply = (format) => {
    if (previewing) return;
    const { selectionStart: start, selectionEnd: end } = box;
    const out = applyFormat(box.value, start, end, format);
    box.focus();
    box.setSelectionRange(start, end);
    // insertText keeps the browser's undo stack and fires input itself; if it's not there, set the value.
    if (!document.execCommand?.("insertText", false, out.insert) || box.value !== out.text) {
      box.value = out.text;
      box.dispatchEvent(new Event("input", { bubbles: true }));
    }
    box.setSelectionRange(out.cursor, out.cursor);
  };

  const write = h("button", { type: "button", class: "md-tab on", onclick: () => show(false) }, "Write");
  const look = h("button", { type: "button", class: "md-tab", onclick: () => show(true) }, "Preview");
  const tools = h("div", { class: "md-tools" }, TOOLS.map((t) => t
    ? h("button", { type: "button", class: "md-tool", title: t[1], "aria-label": t[1], tabindex: "-1",
      // mousedown, not click, so the box keeps its selection.
      onmousedown: (e) => { e.preventDefault(); apply(t[0]); } }, icon(ICONS[t[0]]))
    : h("span", { class: "md-divider" })));
  const wrap = h("div", { class: "md-editor", "data-keep": keep },
    h("div", { class: "md-head" }, h("div", { class: "md-tabs" }, write, look), tools),
    box, preview,
    h("div", { class: "md-foot" }, h("span", { class: "md-m" }, "M"), "Markdown supported"));

  // Back in Write, the cursor is where it was.
  let saved = [0, 0];
  function show(on) {
    if (on === previewing) return;
    if (on) {
      saved = [box.selectionStart, box.selectionEnd];
      preview.style.minHeight = `${box.offsetHeight}px`;
      preview.replaceChildren(box.value.trim() ? markdown(box.value, h) : h("p", { class: "md-nothing" }, "Nothing to preview"));
    }
    previewing = on;
    box.hidden = on;
    preview.hidden = !on;
    wrap.classList.toggle("previewing", on);
    write.classList.toggle("on", !on);
    look.classList.toggle("on", on);
    if (!on) {
      box.focus();
      box.setSelectionRange(...saved);
    }
  }

  box.addEventListener("keydown", (e) => {
    if (!(e.metaKey || e.ctrlKey) || e.altKey) return;
    const format = !e.shiftKey && KEYS[e.key.toLowerCase()];
    if (format) {
      e.preventDefault();
      apply(format);
    } else if (e.key === "Enter" && onsubmit) {
      e.preventDefault();
      onsubmit();
    }
  });

  wrap.textarea = box;
  wrap.clear = () => {
    box.value = "";
    show(false);
    box.blur();
  };
  return wrap;
}

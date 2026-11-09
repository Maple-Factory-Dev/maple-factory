// Markdown import/export for the docs editor (docs/planning-docs.md), with prosemirror-markdown over the
// TipTap schema: headings, bullet/ordered/task lists, quotes, fenced code with its language, links, bold/
// italic/code/strike, and two inline atoms: member mentions (`@login`) and task refs (`MF-12`).
import MarkdownIt from "markdown-it";
import { MarkdownParser, MarkdownSerializer } from "prosemirror-markdown";
import { Slice, Fragment } from "@tiptap/pm/model";
import { taskResolver } from "../../web/app/markdown.js";
import { TASK_ID } from "./schema.js";

export { taskResolver };

/** markdown-it with `@login` and `MF-12` inline rules and GitHub-style task lists.
 *  `members`: logins that make a mention (null: any `@login`); `tasks`: an id → task lookup (taskResolver). */
function tokenizer({ members, tasks }) {
  const md = MarkdownIt("commonmark", { html: false, linkify: false }).enable("strikethrough");
  const known = members ? new Map(members.map((m) => [m.login.toLowerCase(), m])) : null;

  // `@login` and `MF-12` in text (not in links or code) become mention and taskref tokens. A core rule
  // over the joined text, because markdown-it's text rule swallows letters before an inline rule sees them.
  const INLINE = new RegExp(`(?<![\\w@./-])(?:@([A-Za-z0-9][A-Za-z0-9-]{0,38})|(${TASK_ID.source}))(?![\\w-])`, "g");
  md.core.ruler.push("refs", (state) => {
    for (const block of state.tokens) {
      if (block.type !== "inline" || !block.children) continue;
      const out = [];
      let inLink = 0;
      for (const tok of block.children) {
        if (tok.type === "link_open") inLink++;
        if (tok.type === "link_close") inLink--;
        if (tok.type !== "text" || inLink) { out.push(tok); continue; }
        let last = 0;
        const text = (s) => { if (!s) return; const t = new state.Token("text", "", 0); t.content = s; out.push(t); };
        for (const m of tok.content.matchAll(INLINE)) {
          let t;
          if (m[1]) {
            const member = known ? known.get(m[1].toLowerCase()) : { login: m[1] };
            if (!member) continue;
            t = new state.Token("mention", "", 0);
            t.attrs = [["id", member.login], ["label", member.name || member.login]];
          } else {
            const task = tasks?.(m[2]);
            if (!task) continue;
            t = new state.Token("taskref", "", 0);
            t.attrs = [["id", m[2]], ["title", task.title ?? null]];
          }
          text(tok.content.slice(last, m.index));
          out.push(t);
          last = m.index + m[0].length;
        }
        if (last === 0) out.push(tok);
        else text(tok.content.slice(last));
      }
      block.children = out;
    }
  });

  // `- [ ] x` / `- [x] x`: a bullet list whose every item starts that way becomes a task list.
  md.core.ruler.push("tasklists", (state) => {
    const toks = state.tokens;
    for (let i = 0; i < toks.length; i++) {
      if (toks[i].type !== "bullet_list_open") continue;
      const items = [];
      let depth = 0;
      let close = -1;
      for (let j = i; j < toks.length; j++) {
        if (toks[j].type === "bullet_list_open" || toks[j].type === "ordered_list_open") depth++;
        if (toks[j].type === "bullet_list_close" || toks[j].type === "ordered_list_close") depth--;
        if (depth === 1 && toks[j].type === "list_item_open") items.push(j);
        if (depth === 0) { close = j; break; }
      }
      const box = (j) => toks[j + 1]?.type === "paragraph_open" && toks[j + 2]?.type === "inline" && /^\[[ xX]\](\s|$)/.test(toks[j + 2].content);
      if (!items.length || !items.every(box)) continue;
      toks[i].type = "task_list_open";
      toks[close].type = "task_list_close";
      for (const j of items) {
        const inline = toks[j + 2];
        const checked = /^\[[xX]\]/.test(inline.content);
        toks[j].type = "task_item_open";
        toks[j].attrs = [["checked", checked ? "true" : "false"]];
        inline.content = inline.content.replace(/^\[[ xX]\]\s?/, "");
        const first = inline.children?.[0];
        if (first?.type === "text") first.content = first.content.replace(/^\[[ xX]\]\s?/, "");
        const level = toks[j].level;
        for (let k = j + 1; k < toks.length; k++) {
          if (toks[k].type === "list_item_close" && toks[k].level === level) { toks[k].type = "task_item_close"; break; }
        }
      }
    }
  });
  return md;
}

/** A parser from Markdown to a ProseMirror doc in `schema`. */
export function markdownParser(schema, ctx = {}) {
  return new MarkdownParser(schema, tokenizer(ctx), {
    blockquote: { block: "blockquote" },
    paragraph: { block: "paragraph" },
    list_item: { block: "listItem" },
    bullet_list: { block: "bulletList" },
    ordered_list: { block: "orderedList", getAttrs: (tok) => ({ start: +tok.attrGet("start") || 1 }) },
    task_list: { block: "taskList" },
    task_item: { block: "taskItem", getAttrs: (tok) => ({ checked: tok.attrGet("checked") === "true" }) },
    heading: { block: "heading", getAttrs: (tok) => ({ level: +tok.tag.slice(1) }) },
    code_block: { block: "codeBlock", noCloseToken: true },
    fence: { block: "codeBlock", getAttrs: (tok) => ({ language: tok.info.trim().split(/\s+/)[0] || null }), noCloseToken: true },
    hr: { node: "horizontalRule" },
    hardbreak: { node: "hardBreak" },
    mention: { node: "mention", getAttrs: (tok) => ({ id: tok.attrGet("id"), label: tok.attrGet("label") }) },
    taskref: { node: "taskRef", getAttrs: (tok) => ({ id: tok.attrGet("id"), title: tok.attrGet("title") }) },
    em: { mark: "italic" },
    strong: { mark: "bold" },
    s: { mark: "strike" },
    link: { mark: "link", getAttrs: (tok) => ({ href: tok.attrGet("href"), title: tok.attrGet("title") || null }) },
    code_inline: { mark: "code", noCloseToken: true },
  });
}

/** Markdown → a ProseMirror doc. */
export function fromMarkdown(schema, text, ctx = {}) {
  return markdownParser(schema, ctx).parse(text);
}

const list = (indent, delim) => (state, node) => state.renderList(node, indent, typeof delim === "function" ? delim(node) : () => delim);

export const serializer = new MarkdownSerializer(
  {
    doc: (state, node) => state.renderContent(node),
    paragraph: (state, node) => { state.renderInline(node); state.closeBlock(node); },
    text: (state, node) => state.text(node.text, !state.inAutolink),
    heading: (state, node) => { state.write(`${"#".repeat(node.attrs.level)} `); state.renderInline(node, false); state.closeBlock(node); },
    blockquote: (state, node) => state.wrapBlock("> ", null, node, () => state.renderContent(node)),
    codeBlock: (state, node) => {
      const fence = node.textContent.match(/`{3,}/gm) ? "~~~~" : "```";
      state.write(fence + (node.attrs.language || "") + "\n");
      state.text(node.textContent, false);
      state.write("\n");
      state.write(fence);
      state.closeBlock(node);
    },
    horizontalRule: (state, node) => { state.write("---"); state.closeBlock(node); },
    hardBreak: (state, node, parent, index) => {
      for (let i = index + 1; i < parent.childCount; i++) if (parent.child(i).type !== node.type) { state.write("\\\n"); return; }
    },
    bulletList: list("  ", "- "),
    taskList: list("  ", "- "),
    orderedList: (state, node) => {
      const start = node.attrs.start || 1;
      const width = String(start + node.childCount - 1).length;
      const space = state.repeat(" ", width + 2);
      state.renderList(node, space, (i) => { const n = String(start + i); return state.repeat(" ", width - n.length) + n + ". "; });
    },
    listItem: (state, node) => state.renderContent(node),
    taskItem: (state, node) => { state.write(node.attrs.checked ? "[x] " : "[ ] "); state.renderContent(node); },
    mention: (state, node) => state.write(`@${node.attrs.id}`),
    taskRef: (state, node) => state.write(node.attrs.id),
  },
  {
    italic: { open: "*", close: "*", mixable: true, expelEnclosingWhitespace: true },
    bold: { open: "**", close: "**", mixable: true, expelEnclosingWhitespace: true },
    strike: { open: "~~", close: "~~", mixable: true, expelEnclosingWhitespace: true },
    underline: { open: "", close: "" },
    code: {
      open: (_s, _m, parent, index) => backticks(parent.child(index), -1),
      close: (_s, _m, parent, index) => backticks(parent.child(index - 1), 1),
      escape: false,
    },
    link: {
      open: () => "[",
      close: (state, mark) => `](${mark.attrs.href.replace(/[()"]/g, "\\$&")}${mark.attrs.title ? ` "${mark.attrs.title.replace(/"/g, '\\"')}"` : ""})`,
      mixable: true,
    },
  },
  { tightLists: true },
);

function backticks(node, side) {
  const ticks = /`+/g;
  let m, len = 0;
  if (node.isText) while ((m = ticks.exec(node.text))) len = Math.max(len, m[0].length);
  let result = len > 0 && side > 0 ? " `" : "`";
  for (let i = 0; i < len; i++) result += "`";
  if (len > 0 && side < 0) result += " ";
  return result;
}

/** A ProseMirror doc → Markdown. */
export function toMarkdown(doc) {
  return serializer.serialize(doc).replace(/\n+$/, "") + "\n";
}

/** Whether pasted plain text reads as Markdown (and so goes through the parser, not in as plain text). */
export function looksLikeMarkdown(text) {
  return /^(#{1,6}\s|\s*[-*+]\s|\s*\d+[.)]\s|>\s?|```|~~~|---\s*$)|\*\*[^*\n]+\*\*|~~[^~\n]+~~|\[[^\]\n]+\]\([^)\s]+\)|`[^`\n]+`/m.test(text);
}

/** The slice a plain-text paste inserts: parsed Markdown when it looks like Markdown, else null (default paste). */
export function markdownPasteSlice(schema, text, ctx = {}) {
  if (!looksLikeMarkdown(text)) return null;
  const doc = fromMarkdown(schema, text, ctx);
  // One paragraph pastes inline (no new block); anything else pastes as blocks.
  const open = doc.childCount === 1 && doc.firstChild.type.name === "paragraph" ? 1 : 0;
  return new Slice(Fragment.from(doc.content), open, open);
}

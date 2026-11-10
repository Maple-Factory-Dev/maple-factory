// Markdown import/export for the docs editor (docs/planning-docs.md), with prosemirror-markdown over the
// TipTap schema: headings, bullet/ordered/task lists, quotes, fenced code with its language, links, bold/
// italic/code/strike, and two inline atoms: member mentions (`@login`) and task refs (`MF-12`). MF-363 adds
// the planning visuals: ```mermaid and ```chart fences, GFM tables, attachment images and file links, and
// GitHub alert quotes for callouts, toggles and task embeds. Images
// load only from /attachments/; any other image stays a plain link.
import MarkdownIt from "markdown-it";
import { MarkdownParser, MarkdownSerializer } from "prosemirror-markdown";
import { Slice, Fragment } from "@tiptap/pm/model";
import { taskResolver } from "../../web/app/markdown.js";
import { TASK_ID } from "./schema.js";

export { taskResolver };

/** markdown-it with `@login` and `MF-12` inline rules and GitHub-style task lists.
 *  `members`: logins that make a mention (null: any `@login`); `tasks`: an id → task lookup (taskResolver). */
function tokenizer({ members, tasks }) {
  const md = MarkdownIt("commonmark", { html: false, linkify: false }).enable(["strikethrough", "table"]);
  md.core.ruler.push("visuals", visuals);
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

const ALERT = /^\[!(NOTE|TIP|WARNING|IMPORTANT|TOGGLE|TASK|DECISION)\][ \t]*([^\n]*)/;
const ATTACHMENT = /^\/attachments\//;

/** An image that isn't an attachment alone in its paragraph (those became image nodes), as a link to its src:
 *  docs never make viewers' browsers load outside URLs (tracking pixels in pasted or agent-written Markdown). */
function imageAsLink(T, img) {
  const src = img.attrGet("src") ?? "";
  const open = new T("link_open", "a", 1);
  open.attrs = [["href", src]];
  const text = new T("text", "", 0);
  text.content = img.content || src;
  return [open, text, new T("link_close", "a", -1)];
}

/** A core rule (before task refs) that turns block tokens into the planning-visual tokens. */
function visuals(state) {
  const T = state.Token;
  let toks = state.tokens;
  const closeOf = (i) => { for (let j = i + 1; j < toks.length; j++) if (toks[j].type === "blockquote_close" && toks[j].level === toks[i].level) return j; return toks.length - 1; };
  for (let i = 0; i < toks.length; i++) {
    const tok = toks[i];
    if (tok.type === "inline" && tok.children?.some((k) => k.type === "image")) tok.children = tok.children.flatMap((k) => (k.type === "image" ? imageAsLink(T, k) : [k]));
    if (tok.type === "fence") {
      const lang = tok.info.trim().split(/\s+/)[0];
      if (lang === "mermaid") tok.type = "mermaid";
      if (lang === "chart") {
        tok.type = "chart";
        const kind = tok.content.match(/^type:\s*(\w+)/m)?.[1];
        tok.attrs = [["kind", kind === "line" ? "line" : "bar"], ["title", tok.content.match(/^title:[ \t]*(.*)$/m)?.[1].trim() ?? ""]];
      }
    } else if ((tok.type === "th_open" || tok.type === "td_open") && toks[i + 1]?.type === "inline") {
      // Table cells hold blocks: wrap the cell's inline content in a paragraph.
      toks.splice(i + 1, 0, new T("paragraph_open", "p", 1));
      toks.splice(i + 3, 0, new T("paragraph_close", "p", -1));
    } else if (tok.type === "paragraph_open" && toks[i + 1]?.type === "inline" && toks[i + 2]?.type === "paragraph_close") {
      const kids = toks[i + 1].children ?? [];
      let t = null;
      if (kids.length === 1 && kids[0].type === "image" && ATTACHMENT.test(kids[0].attrGet("src") ?? "")) {
        t = new T("doc_image", "", 0);
        const width = +(kids[0].attrGet("title") ?? "").match(/^width=(\d+)$/)?.[1] || null;
        t.attrs = [["src", kids[0].attrGet("src")], ["alt", kids[0].content], ["width", width]];
      } else if (kids.length === 3 && kids[0].type === "link_open" && ATTACHMENT.test(kids[0].attrGet("href") ?? "") && kids[1].type === "text" && kids[2].type === "link_close") {
        t = new T("file_attachment", "", 0);
        let size = null, mime = null;
        for (const part of (kids[0].attrGet("title") ?? "").split(" · ")) {
          const n = part.match(/^(\d+) bytes$/);
          if (n) size = +n[1]; else if (part.includes("/")) mime = part;
        }
        t.attrs = [["href", kids[0].attrGet("href")], ["name", kids[1].content], ["size", size], ["mime", mime]];
      }
      if (t) toks.splice(i, 3, t);
    } else if (tok.type === "blockquote_open" && toks[i + 1]?.type === "paragraph_open" && toks[i + 2]?.type === "inline") {
      const m = toks[i + 2].content.match(ALERT);
      if (!m) continue;
      const [, kind, rest] = m;
      const j = closeOf(i);
      if (kind === "DECISION") {
        // An atom (MF-367): only the id is read back; the question, status and choice live on the server.
        const id = rest.match(/^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\b/i)?.[1] ?? null;
        const t = new T("decision_embed", "", 0);
        t.attrs = [["id", id]];
        toks.splice(i, j - i + 1, t);
        continue;
      }
      if (kind === "TASK") {
        // An atom: only the marker line's id is read back; the rest (the task's live state) is a snapshot.
        const id = rest.match(new RegExp(`^(${TASK_ID.source})\\b`))?.[1] ?? null;
        const t = new T("task_embed", "", 0);
        t.attrs = [["id", id]];
        toks.splice(i, j - i + 1, t);
        continue;
      }
      tok.type = kind === "TOGGLE" ? "toggle_open" : "callout_open";
      toks[j].type = kind === "TOGGLE" ? "toggle_close" : "callout_close";
      tok.attrs = kind === "TOGGLE" ? [["summary", rest.trim()]] : [["tone", kind.toLowerCase()]];
      // Drop the marker line from the first paragraph (and the paragraph, when that was all of it).
      const inline = toks[i + 2];
      const kids = inline.children ?? [];
      const br = kids.findIndex((k) => k.type === "softbreak" || k.type === "hardbreak");
      if (br < 0) toks.splice(i + 1, 3);
      else { inline.children = kids.slice(br + 1); inline.content = inline.content.slice(inline.content.indexOf("\n") + 1); }
    }
  }
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
    mermaid: { node: "mermaid", getAttrs: (tok) => ({ source: tok.content.replace(/\n$/, "") }), noCloseToken: true },
    chart: { node: "chart", getAttrs: (tok) => ({ kind: tok.attrGet("kind"), title: tok.attrGet("title") }), noCloseToken: true },
    table: { block: "table" },
    thead: { ignore: true },
    tbody: { ignore: true },
    tr: { block: "tableRow" },
    th: { block: "tableHeader" },
    td: { block: "tableCell" },
    doc_image: { node: "image", getAttrs: (tok) => ({ src: tok.attrGet("src"), alt: tok.attrGet("alt") ?? "", width: tok.attrGet("width") }), noCloseToken: true },
    file_attachment: { node: "fileAttachment", getAttrs: (tok) => ({ href: tok.attrGet("href"), name: tok.attrGet("name"), size: tok.attrGet("size"), mime: tok.attrGet("mime") }), noCloseToken: true },
    callout: { block: "callout", getAttrs: (tok) => ({ tone: tok.attrGet("tone") }) },
    toggle: { block: "toggle", getAttrs: (tok) => ({ summary: tok.attrGet("summary") }) },
    task_embed: { node: "taskEmbed", getAttrs: (tok) => ({ id: tok.attrGet("id") }), noCloseToken: true },
    decision_embed: { node: "decision", getAttrs: (tok) => ({ id: tok.attrGet("id") }), noCloseToken: true },
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

// The task lookup an export snapshots embeds from (set by toMarkdown for the length of one serialize).
let exportTasks = null;
let exportDecisions = null;
const oneLine = (s) => String(s ?? "").replace(/\s*\n\s*/g, " ").trim();
const fence = (state, node, lang, body) => {
  const f = body.match(/`{3,}/gm) ? "~~~~" : "```";
  state.write(f + lang + "\n");
  state.text(body, false);
  state.write("\n");
  state.write(f);
  state.closeBlock(node);
};
const linkTarget = (href) => (/[\s()<>]/.test(href) ? `<${href.replace(/[<>]/g, encodeURIComponent)}>` : href);
/** One table cell as single-line Markdown, its pipes escaped. */
const cellText = (cell) => serializer.serialize(cell).trim().replace(/\n+/g, " ").replace(/(?<!\\)\|/g, "\\|");
/** An alert quote with a single marker line: `> [!KIND] line`. */
const alert = (state, node, line) => state.wrapBlock("> ", null, node, () => state.write(line));

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
    mermaid: (state, node) => fence(state, node, "mermaid", node.attrs.source),
    chart: (state, node) => fence(state, node, "chart", `type: ${node.attrs.kind}${node.attrs.title ? `\ntitle: ${oneLine(node.attrs.title)}` : ""}`),
    table: (state, node) => {
      const rows = [];
      node.forEach((row) => { const cells = []; row.forEach((c) => cells.push(cellText(c))); rows.push(cells); });
      const cols = Math.max(1, ...rows.map((r) => r.length));
      const line = (r) => `| ${Array.from({ length: cols }, (_, i) => r[i] ?? "").join(" | ")} |`;
      [line(rows[0] ?? []), `|${" --- |".repeat(cols)}`, ...rows.slice(1).map(line)].forEach((l, i) => { if (i) state.ensureNewLine(); state.write(l); });
      state.closeBlock(node);
    },
    tableRow: () => {},
    tableHeader: () => {},
    tableCell: () => {},
    image: (state, node) => {
      state.write(`![${(node.attrs.alt ?? "").replace(/[[\]\\]/g, "\\$&")}](${linkTarget(node.attrs.src ?? "")}${node.attrs.width ? ` "width=${node.attrs.width}"` : ""})`);
      state.closeBlock(node);
    },
    fileAttachment: (state, node) => {
      const title = [node.attrs.mime, node.attrs.size != null ? `${node.attrs.size} bytes` : null].filter(Boolean).join(" · ");
      state.write(`[${(node.attrs.name ?? "file").replace(/[[\]\\]/g, "\\$&")}](${linkTarget(node.attrs.href ?? "")}${title ? ` "${title}"` : ""})`);
      state.closeBlock(node);
    },
    callout: (state, node) => state.wrapBlock("> ", null, node, () => { state.write(`[!${node.attrs.tone.toUpperCase()}]\n`); state.renderContent(node); }),
    toggle: (state, node) => state.wrapBlock("> ", null, node, () => { state.write(`[!TOGGLE]${node.attrs.summary ? ` ${oneLine(node.attrs.summary)}` : ""}\n`); state.renderContent(node); }),
    decision: (state, node) => {
      const d = exportDecisions?.(node.attrs.id);
      const chosen = d?.options?.find((o) => o.id === d.chosen)?.label;
      const parts = [node.attrs.id ?? "", d ? oneLine(d.question) : null, d?.status ?? null];
      alert(state, node, `[!DECISION] ${parts.filter(Boolean).join(" · ")}${chosen && d.status !== "proposed" ? ` → ${oneLine(chosen)}` : ""}`);
    },
    taskEmbed: (state, node) => {
      const t = exportTasks?.(node.attrs.id);
      const parts = [node.attrs.id ?? "", t?.title && oneLine(t.title), t?.state, t?.pr?.number && `PR #${t.pr.number}`, t?.assignee && `@${t.assignee}`];
      alert(state, node, `[!TASK] ${parts.filter(Boolean).join(" · ")}`);
    },
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

/** A ProseMirror doc → Markdown. `tasks` (an id → task lookup) snapshots task embeds' state, PR and owner,
 *  into the export. */
export function toMarkdown(doc, { tasks = null, decisions = null } = {}) {
  exportTasks = tasks;
  exportDecisions = decisions;
  try {
    return serializer.serialize(doc).replace(/\n+$/, "") + "\n";
  } finally {
    exportTasks = null;
    exportDecisions = null;
  }
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

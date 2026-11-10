// Splitting a doc section into task drafts (MF-368): shared by the editor's Make tasks dialog and the server
// (server/src/factory/doc-tasks.ts), so what the dialog prefills is what the server would make.

/** The most tasks one Make tasks makes. */
export const MAX_TASKS = 20;
export const MAX_TITLE = 120;

const clip = (s, n) => (s.length > n ? s.slice(0, n - 1).trimEnd() + "…" : s);
/** A title from a line of Markdown: no heading marks, list marks, checkboxes or emphasis. */
export function titleOf(line) {
  const t = String(line ?? "")
    .replace(/^\s*#{1,6}\s+/, "")
    .replace(/^\s*(?:[-*+]|\d+[.)])\s+/, "")
    .replace(/^\[[ xX]\]\s+/, "")
    .replace(/[*_`~]+/g, "")
    .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
    .trim();
  return clip(t, MAX_TITLE);
}

const HEADING = /^(#{1,6})\s+(.*)$/;
const ITEM = /^(?:[-*+]|\d+[.)])\s+/;

/**
 * [{title, brief}] from a section's Markdown. `one`: a single task, titled by its heading (or first line).
 * `headings`: one per sub-heading (headings below the section's own). `items`: one per top-level list item.
 * A mode that finds nothing to split falls back to one task.
 */
export function splitSection(markdown, mode = "one", fallbackTitle = "") {
  const md = String(markdown ?? "").trim();
  const lines = md.split("\n");
  const firstLine = lines.find((l) => l.trim()) ?? "";
  const one = () => [{ title: titleOf(firstLine) || clip(fallbackTitle, MAX_TITLE) || "Untitled", brief: md }];
  if (!md) return [];
  if (mode === "headings") {
    const own = HEADING.exec(firstLine)?.[1].length ?? 0;
    const out = [];
    let cur = null;
    for (const line of lines) {
      const h = HEADING.exec(line);
      if (h && h[1].length > own && (!cur || h[1].length <= cur.level)) {
        cur = { level: h[1].length, title: titleOf(h[2]), body: [] };
        out.push(cur);
      } else if (cur) cur.body.push(line);
    }
    return out.length ? out.map((c) => ({ title: c.title || "Untitled", brief: c.body.join("\n").trim() || c.title })) : one();
  }
  if (mode === "items") {
    const out = [];
    let cur = null;
    for (const line of lines) {
      if (ITEM.test(line)) {
        cur = { first: line, body: [] };
        out.push(cur);
      } else if (cur && /^\s+\S/.test(line)) cur.body.push(line.replace(/^ {2,4}/, ""));
      else if (cur && line.trim()) cur = null;
    }
    return out.length ? out.map((c) => {
      const text = c.first.replace(ITEM, "").replace(/^\[[ xX]\]\s+/, "");
      return { title: titleOf(text) || "Untitled", brief: [text, ...c.body].join("\n").trim() };
    }) : one();
  }
  return one();
}

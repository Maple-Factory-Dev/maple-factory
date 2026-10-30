// Reviewing a task's diff on the web: lines picked in a file turned into review notes, the same way the
// Mac app does it (DiffReview.swift). A file's rows are its parsed lines one after another (app.js
// parseDiff): `add`, `del` and `ctx` lines, with `hunk` headers between them that can't be picked.

/** Lines picked in one file, by row: where the click started stays put, and shift-click moves the other end. */
export function pick(path, row) {
  return { path, anchor: row, head: row };
}

/** The selection with its other end moved to `row`, or a new one when it's another file. */
export function extend(selection, path, row) {
  return selection?.path === path ? { ...selection, head: row } : pick(path, row);
}

/** The first and last row a selection covers. */
export const rowsOf = (s) => ({ first: Math.min(s.anchor, s.head), last: Math.max(s.anchor, s.head) });

/** Whether `row` of `path` is picked. */
export const picked = (s, path, row) => !!s && s.path === path && row >= rowsOf(s).first && row <= rowsOf(s).last;

/** Whether a row can be commented on: any line but a hunk header. */
export const pickable = (line) => !!line && line.kind !== "hunk";

/** The lines a selection covers, numbered the way GitHub would: removed lines alone are on the old side;
 *  otherwise the new side, by the added and unchanged lines' numbers. Null when there's no line there. */
export function span(lines) {
  const numbered = lines.filter(pickable);
  const nums = numbered.filter((l) => l.kind !== "del" && l.new != null).map((l) => l.new);
  if (nums.length) return { start: Math.min(...nums), end: Math.max(...nums), side: "new" };
  const old = numbered.filter((l) => l.old != null).map((l) => l.old);
  if (old.length) return { start: Math.min(...old), end: Math.max(...old), side: "old" };
  return null;
}

/** The lines as the diff showed them: `+`, `-` or a space, then the line. Hunk headers are left out. */
export function snippet(lines) {
  return lines.filter(pickable).map((l) => (l.kind === "add" ? "+" : l.kind === "del" ? "-" : " ") + l.text).join("\n");
}

/** A ReviewNote (wire.ts) on `lines`, or null when there's nothing there to comment on. */
export function toNote(path, lines, text) {
  const s = span(lines);
  return s ? { path, start: s.start, end: s.end, side: s.side, snippet: snippet(lines), text } : null;
}

/** The lines a selection's rows hold in a file's `lines`. */
export function selected(s, lines) {
  const { first, last } = rowsOf(s);
  return lines.slice(Math.max(first, 0), Math.min(last, lines.length - 1) + 1);
}

/** "line 12", or "lines 12–15", with "(removed)" for the old side: how the comment box names its lines. */
export function linesLabel(note) {
  const lines = note.end > note.start ? `lines ${note.start}–${note.end}` : `line ${note.start}`;
  return note.side === "old" ? `${lines} (removed)` : lines;
}

/** Where a pending note's rows are in a file's reloaded `lines`: the same rows if they still hold its code,
 *  else the first rows that do, or null when its code is gone and the note should be dropped. */
export function relocate(rows, note, lines) {
  const count = rows.last - rows.first;
  // Hunk headers aren't in a snippet, so a note across two hunks still finds its rows.
  const at = (first) => pickable(lines[first]) && snippet(lines.slice(first, first + count + 1)) === note.snippet;
  if (rows.first + count < lines.length && at(rows.first)) return rows;
  for (let first = 0; first + count < lines.length; first++) if (at(first)) return { first, last: first + count };
  return null;
}

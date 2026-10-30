// Turning lines picked in the web app's Diff tab into review notes, numbered the way the Mac app does it.
import { test } from "node:test";
import assert from "node:assert/strict";
import { extend, pick, pickable, picked, relocate, rowsOf, selected, snippet, span, toNote } from "../web/app/review.js";

// A file's rows as parseDiff makes them: a hunk header, then its lines.
const lines = [
  { kind: "hunk", text: "@@ -10,4 +10,5 @@ function save()" },
  { kind: "ctx", old: 10, new: 10, text: "  const a = 1;" },
  { kind: "del", old: 11, text: "  const b = 2;" },
  { kind: "add", new: 11, text: "  const b = 3;" },
  { kind: "add", new: 12, text: "  const c = 4;" },
  { kind: "ctx", old: 12, new: 13, text: "  return a + b;" },
];

test("a single added line is on the new side", () => {
  assert.deepEqual(span([lines[3]]), { start: 11, end: 11, side: "new" });
  assert.deepEqual(toNote("src/save.js", [lines[3]], "Why 3?"),
    { path: "src/save.js", start: 11, end: 11, side: "new", snippet: "+  const b = 3;", text: "Why 3?" });
});

test("a mixed range is numbered by its added and unchanged lines", () => {
  const s = shiftClick(1, 5);
  assert.deepEqual(rowsOf(s), { first: 1, last: 5 });
  assert.deepEqual(span(selected(s, lines)), { start: 10, end: 13, side: "new" });
  // From the removed line down: still the new side, from the first added line.
  assert.deepEqual(span(lines.slice(2, 5)), { start: 11, end: 12, side: "new" });
});

test("removed lines alone are on the old side", () => {
  assert.deepEqual(span([lines[2]]), { start: 11, end: 11, side: "old" });
  assert.equal(toNote("src/save.js", [lines[2]], "Keep this")?.side, "old");
});

test("the snippet shows each line with its +, - or space", () => {
  assert.equal(snippet(lines.slice(1, 6)), "   const a = 1;\n-  const b = 2;\n+  const b = 3;\n+  const c = 4;\n   return a + b;");
});

test("a hunk header can't be picked and is left out of a note", () => {
  assert.equal(pickable(lines[0]), false);
  assert.equal(span([lines[0]]), null);
  assert.equal(toNote("src/save.js", [lines[0]], "Here"), null);
  assert.equal(toNote("src/save.js", lines.slice(0, 2), "Here")?.snippet, "   const a = 1;");
});

test("shift-click extends a pick in the same file, and starts over in another", () => {
  const s = pick("a.js", 4);
  const up = extend(s, "a.js", 1);
  assert.deepEqual(rowsOf(up), { first: 1, last: 4 });
  assert.equal(picked(up, "a.js", 2), true);
  assert.equal(picked(up, "b.js", 2), false);
  assert.deepEqual(extend(up, "b.js", 3), { path: "b.js", anchor: 3, head: 3 });
});

test("a pending note follows its code when the diff reloads, and is dropped once it's gone", () => {
  const note = toNote("src/save.js", lines.slice(3, 5), "Rename these")!;
  assert.deepEqual(relocate({ first: 3, last: 4 }, note, lines), { first: 3, last: 4 });
  const moved = [lines[0], { kind: "add", new: 10, text: "// header" }, ...lines.slice(1)];
  assert.deepEqual(relocate({ first: 3, last: 4 }, note, moved), { first: 4, last: 5 });
  assert.equal(relocate({ first: 3, last: 4 }, note, lines.slice(0, 3)), null);
});

function shiftClick(from: number, to: number) {
  return extend(pick("src/save.js", from), "src/save.js", to);
}

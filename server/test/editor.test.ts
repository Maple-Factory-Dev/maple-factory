// The web Markdown editor's toolbar: applyFormat() is pure, so every format is checked without a DOM,
// against what the Mac app's MarkdownEditor.apply does.
import { test } from "node:test";
import assert from "node:assert/strict";
import { applyFormat } from "../web/app/editor.js";

/** Applies a format to the `[…]` in `marked` (or at a lone `|`), and returns the text with a `|` at the cursor. */
function run(marked: string, format: string) {
  let start: number, end: number, text: string;
  if (marked.includes("[")) {
    start = marked.indexOf("[");
    end = marked.indexOf("]") - 1;
    text = marked.replace("[", "").replace("]", "");
  } else {
    start = end = marked.indexOf("|");
    text = marked.replace("|", "");
  }
  const out = applyFormat(text, start, end, format);
  return out.text.slice(0, out.cursor) + "|" + out.text.slice(out.cursor);
}

test("inline formats wrap the selection, and the cursor lands after it", () => {
  assert.equal(run("make [this] loud", "bold"), "make **this**| loud");
  assert.equal(run("make [this] lean", "italic"), "make _this_| lean");
  assert.equal(run("run [npm test] now", "code"), "run `npm test`| now");
  assert.equal(run("see [the docs]", "link"), "see [the docs](https://)|");
});

test("inline formats with nothing selected insert a placeholder word", () => {
  assert.equal(run("a |b", "bold"), "a **bold**|b");
  assert.equal(run("|", "italic"), "_italic_|");
  assert.equal(run("x |", "code"), "x `code`|");
  assert.equal(run("|", "link"), "[title](https://)|");
  assert.equal(run("hi |", "mention"), "hi @|");
});

test("block formats at the start of a line insert no break", () => {
  assert.equal(run("[Plan]", "heading"), "## Plan|");
  assert.equal(run("one\n[two]", "bullet"), "one\n- two|");
  assert.equal(run("one\n[first]", "numbered"), "one\n1. first|");
  assert.equal(run("[ship it]", "task"), "- [ ] ship it|");
  assert.equal(run("[said so]", "quote"), "> said so|");
});

test("block formats mid-line start a new line first", () => {
  assert.equal(run("intro [Plan]", "heading"), "intro \n## Plan|");
  assert.equal(run("intro|", "bullet"), "intro\n- |");
  assert.equal(run("intro|", "numbered"), "intro\n1. |");
  assert.equal(run("todo: [ship]", "task"), "todo: \n- [ ] ship|");
  assert.equal(run("he said [no]", "quote"), "he said \n> no|");
});

test("block formats with nothing selected at a line start", () => {
  assert.equal(run("|", "heading"), "## Heading|");
  assert.equal(run("a\n|", "bullet"), "a\n- |");
  assert.equal(run("|", "numbered"), "1. |");
  assert.equal(run("|", "task"), "- [ ] |");
  assert.equal(run("|", "quote"), "> |");
});

test("code over several lines becomes a fenced block", () => {
  assert.equal(run("before\n[let a = 1\nlet b = 2]\nafter", "code"), "before\n\n```\nlet a = 1\nlet b = 2\n```\n|\nafter");
  const out = applyFormat("x\ny", 0, 3, "code");
  assert.equal(out.text, "\n```\nx\ny\n```\n");
  assert.equal(out.insert, out.text);
  assert.equal(out.cursor, out.text.length);
});

test("an unknown format throws", () => {
  assert.throws(() => applyFormat("a", 0, 0, "strike"));
});

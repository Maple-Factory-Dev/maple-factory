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

// The @ picker: what's being typed after an `@`, and who it matches.
import { matchMembers, mentionAt } from "../web/app/editor.js";

test("an @ starts a mention at the start, after a space or punctuation, not inside an email", () => {
  assert.deepEqual(mentionAt("@", 1), { start: 0, query: "" });
  assert.deepEqual(mentionAt("hey @bo", 7), { start: 4, query: "bo" });
  assert.deepEqual(mentionAt("(@b", 3), { start: 1, query: "b" });
  assert.equal(mentionAt("mail a@b", 8), null);
  assert.equal(mentionAt("@bob done", 9), null);
  assert.deepEqual(mentionAt("@bob done", 4), { start: 0, query: "bob" });
});

test("members match by login first, then by name, then anywhere", () => {
  const members = [{ login: "carol" }, { login: "bob", name: "Robert Smith" }, { login: "abby", name: "Abby B" }, { login: "zed", name: "Bea" }];
  assert.deepEqual(matchMembers(members, "b").map((m) => m.login), ["bob", "abby", "zed"]);
  assert.deepEqual(matchMembers(members, "smi").map((m) => m.login), ["bob"]);
  assert.deepEqual(matchMembers(members, "").map((m) => m.login), ["abby", "bob", "carol", "zed"]);
  assert.deepEqual(matchMembers(members, "q"), []);
});

// The # picker: what's being typed after a `#`, and which tasks it matches.
import { matchTasks, taskRefAt } from "../web/app/editor.js";

test("a # starts a task reference at the start or after a space, not inside a word or URL", () => {
  assert.deepEqual(taskRefAt("#", 1), { start: 0, query: "" });
  assert.deepEqual(taskRefAt("see #MF-1", 9), { start: 4, query: "MF-1" });
  assert.deepEqual(taskRefAt("(#lo", 4), { start: 1, query: "lo" });
  assert.equal(taskRefAt("a#b", 3), null);
  assert.equal(taskRefAt("foo#bar", 7), null);
  assert.equal(taskRefAt("https://x.dev/page#top", 22), null);
  assert.equal(taskRefAt("#MF-1 done", 10), null);
  assert.deepEqual(taskRefAt("#MF-1 done", 5), { start: 0, query: "MF-1" });
});

test("tasks match by ID, then a title word, then anywhere; at most six", () => {
  const tasks = [
    { id: "MF-1", title: "Login page" }, { id: "MF-12", title: "Reference other tickets" },
    { id: "MF-13", title: "Mention people" }, { id: "MF-20", title: "Fix the MF-1 logo" }, { id: "MF-21", title: "Logging" },
  ];
  assert.deepEqual(matchTasks(tasks, "MF-1").map((t) => t.id), ["MF-1", "MF-13", "MF-12", "MF-20"]);
  assert.deepEqual(matchTasks(tasks, "mf-12").map((t) => t.id), ["MF-12"]);
  assert.deepEqual(matchTasks(tasks, "log").map((t) => t.id), ["MF-21", "MF-20", "MF-1"]);
  assert.deepEqual(matchTasks(tasks, "ence").map((t) => t.id), ["MF-12"]);
  assert.deepEqual(matchTasks(tasks, "zzz"), []);
  const many = Array.from({ length: 10 }, (_, i) => ({ id: `MF-${i + 1}`, title: "" }));
  assert.equal(matchTasks(many, "").length, 6);
});

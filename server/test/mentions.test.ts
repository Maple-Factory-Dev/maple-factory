// Who a comment @mentions: members only, matched case-insensitively, once each, never the author.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mentionsIn } from "../src/factory/mentions.ts";

const members = [{ login: "alice" }, { login: "Bob" }, { login: "carol-k" }];

test("finds members around punctuation, as their own login", () => {
  assert.deepEqual(mentionsIn("@bob, can you look? (cc @carol-k).", members), ["Bob", "carol-k"]);
  assert.deepEqual(mentionsIn("thanks @BOB!\n@alice: yes", members), ["Bob", "alice"]);
});

test("leaves out emails, unknown logins and code-ish text", () => {
  assert.deepEqual(mentionsIn("mail alice@bob.com or a@b.com", members), []);
  assert.deepEqual(mentionsIn("cc @nobody and @bobby", members), []);
  assert.deepEqual(mentionsIn("see @bob.com and x@@bob", members), []);
});

test("each member once, never the author", () => {
  assert.deepEqual(mentionsIn("@bob @Bob @bob", members), ["Bob"]);
  assert.deepEqual(mentionsIn("@alice note to self, @bob", members, "Alice"), ["Bob"]);
  assert.deepEqual(mentionsIn("@alice", members, "alice"), []);
});

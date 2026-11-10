// MF-370: a newly proposed doc decision pushes reason `decision`, ref `doc:<id>`, to the org members @mentioned in
// its question, rationale or option notes, never the proposer; an agent's proposal also goes to its person.
import { test } from "node:test";
import assert from "node:assert/strict";
import { pushTargets, notifyProposed } from "../src/factory/decisions.ts";
import type { Decision } from "../src/wire.ts";

const members = [{ login: "ada" }, { login: "Linus" }, { login: "grace" }];
const decision = (over: Partial<Decision> = {}): Decision => ({
  id: "11111111-1111-4111-8111-111111111111", doc: "doc-1", question: "Which database?",
  options: [{ id: "a", label: "Postgres", note: null }, { id: "b", label: "SQLite", note: null }],
  chosen: null, rationale: "", status: "proposed", proposedBy: "ada", agent: null, proposedAt: 1, ...over,
});

test("members @mentioned in the question, rationale or option notes get it", () => {
  const d = decision({
    question: "Which database, @linus?", rationale: "cc @grace and @nobody (not a member)",
    options: [{ id: "a", label: "Postgres @ada", note: null }, { id: "b", label: "SQLite", note: "@Grace knows this" }],
    proposedBy: "someone",
  });
  // Labels aren't searched; logins come back as the member's own spelling.
  assert.deepEqual(pushTargets(d, members), ["Linus", "grace"]);
});

test("a person proposing never gets their own push, even when they @mention themselves", () => {
  const d = decision({ question: "@ada @linus which one?", rationale: "@ADA again", proposedBy: "ada" });
  assert.deepEqual(pushTargets(d, members), ["Linus"]);
  assert.deepEqual(pushTargets(decision({ question: "@ada?", proposedBy: "ada" }), members), []);
});

test("an agent's proposal goes to the person it works for", () => {
  assert.deepEqual(pushTargets(decision({ proposedBy: "ada", agent: "agent on mbp" }), members), ["ada"]);
  assert.deepEqual(pushTargets(decision({ proposedBy: "ada", agent: "claude via MCP", rationale: "@grace" }), members), ["ada", "grace"]);
  // A proposer that isn't a member (a task id) gets nothing.
  assert.deepEqual(pushTargets(decision({ proposedBy: "MF-370", agent: "MF-370 builder" }), members), []);
});

test("no one gets it twice", () => {
  const d = decision({
    question: "@grace @grace", rationale: "@Grace, @ada", options: [{ id: "a", label: "x", note: "@ada @grace" }, { id: "b", label: "y", note: "@ADA" }],
    proposedBy: "ada", agent: "agent on mbp",
  });
  assert.deepEqual(pushTargets(d, members), ["ada", "grace"]);
});

test("notifyProposed sends reason decision with ref doc:<id> to each target", async () => {
  const sent: Array<{ login: string; ref: string; reason: string }> = [];
  const push = { send: async (login: string, what: { ref: string; reason: "decision" }) => (sent.push({ login, ...what }), 1) };
  const n = await notifyProposed(push, decision({ question: "@linus @grace?", proposedBy: "ada" }), members);
  assert.equal(n, 2);
  assert.deepEqual(sent, [{ login: "Linus", ref: "doc:doc-1", reason: "decision" }, { login: "grace", ref: "doc:doc-1", reason: "decision" }]);
});

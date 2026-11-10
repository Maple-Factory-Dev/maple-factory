// Search and filters behind the outside MCP tools list_goals and list_tasks (src/factory/mcp-search.ts).
import { test } from "node:test";
import assert from "node:assert/strict";
import { filterGoals, filterTasks, findGoal, matchesWords, words } from "../src/factory/mcp-search.ts";
import type { Goal, Task } from "../src/wire.ts";

const goal = (g: Partial<Goal> & { id: string; name: string; prefix: string }): Goal => ({ color: "#000000", summary: "", lead: "alice", repos: [], ...g });
const task = (t: Partial<Task> & { id: string; goal: string; title: string }): Task => ({ state: "backlog", owner: "alice", brief: "", updatedAt: 0, after: [], ...t } as Task);

const goals = [
  goal({ id: "g1", name: "Maple Factory", prefix: "MF", summary: "Where we build the Factory.", repos: ["acme/maple-factory", "acme/site"] }),
  goal({ id: "g2", name: "Atlas", prefix: "ATL", summary: "Maps and routing.", repo: "acme/atlas" }),
  goal({ id: "g3", name: "Old billing", prefix: "BIL", summary: "Retired factory invoices.", repos: ["acme/billing"], archived: true }),
];
const tasks = [
  task({ id: "MF-1", goal: "g1", title: "Rate-limit /mcp per token", brief: "A token can call as fast as the Worker answers.", state: "building", owner: "alice", priority: "p1", effort: "MCP hardening", updatedAt: 10 }),
  task({ id: "MF-2", goal: "g1", title: "Docs editor: decision cards", brief: "Mention rate of edits.", state: "merged", owner: "bob", priority: "p2", updatedAt: 30 }),
  task({ id: "MF-416", goal: "g1", title: "MCP: tasks for outside clients", brief: "Propose tasks from Claude.", state: "drafting", owner: "bob", priority: "p1", effort: "mcp hardening", updatedAt: 20 }),
  task({ id: "ATL-4", goal: "g2", title: "Tile cache", brief: "Cache map tiles; see MF-416 for the MCP side.", state: "cancelled", owner: "alice", updatedAt: 40 }),
  task({ id: "ATL-416", goal: "g2", title: "Routing", brief: "", state: "closed", owner: "carol", updatedAt: 5 }),
];
const ids = (ts: Task[]) => ts.map((t) => t.id);

test("matchesWords: every word, any field, any case; capped", () => {
  assert.equal(matchesWords("mcp rate", "Rate-limit /mcp per token"), true, "'mcp rate' finds 'Rate-limit /mcp per token'");
  assert.equal(matchesWords("MCP  RATE", "rate-limit", "the /mcp route"), true, "words may be in different fields");
  assert.equal(matchesWords("mcp billing", "Rate-limit /mcp per token"), false, "every word must appear");
  assert.equal(matchesWords("", "anything"), true);
  assert.equal(matchesWords(undefined, null, undefined), true);
  assert.equal(matchesWords("x", null, undefined), false);
  assert.equal(words("a b c d e f g h i j").length, 8, "at most 8 words");
  assert.deepEqual(words(`${"x".repeat(200)} tail`), ["x".repeat(200)], "at most 200 characters");
  assert.equal(matchesWords("a b c d e f g h zzz", "a b c d e f g h"), true, "a ninth word isn't looked at");
});

test("list_goals search: name, prefix, summary or a repo; archived hidden unless asked", () => {
  const names = (f: Parameters<typeof filterGoals>[1]) => filterGoals(goals, f).map((g) => g.prefix);
  assert.deepEqual(names({}), ["ATL", "MF"], "by name, archived left out");
  assert.deepEqual(names({ q: "maple" }), ["MF"]);
  assert.deepEqual(names({ q: "atl" }), ["ATL"], "by prefix, whatever the case");
  assert.deepEqual(names({ q: "ROUTING maps" }), ["ATL"], "by summary");
  assert.deepEqual(names({ q: "acme/site" }), ["MF"], "by a repo");
  assert.deepEqual(names({ q: "acme/atlas" }), ["ATL"], "by an older goal's one repo");
  assert.deepEqual(names({ q: "factory" }), ["MF"], "an archived match stays out");
  assert.deepEqual(names({ q: "factory", archived: true }), ["MF", "BIL"]);
  assert.deepEqual(names({ archived: true }).length, 3);
  assert.deepEqual(names({ q: "nothing here" }), []);
  assert.equal(findGoal(goals, "mf")?.id, "g1");
  assert.equal(findGoal(goals, "ATLAS")?.id, "g2");
  assert.equal(findGoal(goals, "g3")?.id, "g3");
  assert.equal(findGoal(goals, "nope"), null);
});

test("list_tasks search: id, title or brief; most recently updated first, an exact id first", () => {
  const find = (f: Parameters<typeof filterTasks>[2]) => ids(filterTasks(tasks, goals, f));
  assert.deepEqual(find({}), ["ATL-4", "MF-2", "MF-416", "MF-1", "ATL-416"], "newest first");
  assert.deepEqual(find({ q: "mcp rate" }), ["MF-1"], "multi-word, in the title");
  assert.deepEqual(find({ q: "RATE" }), ["MF-2", "MF-1"], "case-insensitive, title or brief");
  assert.deepEqual(find({ q: "claude" }), ["MF-416"], "in the brief");
  assert.deepEqual(find({ q: "MF-416" }), ["MF-416", "ATL-4"], "the task with that id first, then ones mentioning it");
  assert.deepEqual(find({ q: "416" }), ["MF-416", "ATL-416", "ATL-4"], "a bare number is an exact id too");
  assert.deepEqual(find({ q: "atl-4" }), ["ATL-4", "ATL-416"]);
  assert.deepEqual(find({ q: "no such thing" }), []);
});

test("list_tasks filters: each alone, and with q", () => {
  const find = (f: Parameters<typeof filterTasks>[2]) => ids(filterTasks(tasks, goals, f));
  assert.deepEqual(find({ goal: "ATL" }), ["ATL-4", "ATL-416"], "goal by prefix");
  assert.deepEqual(find({ goal: "maple factory" }), ["MF-2", "MF-416", "MF-1"], "goal by name");
  assert.deepEqual(find({ goal: "g2" }), ["ATL-4", "ATL-416"], "goal by id");
  assert.deepEqual(find({ goal: "nope" }), [], "a goal that isn't there matches nothing");
  assert.deepEqual(find({ state: "merged" }), ["MF-2"]);
  assert.deepEqual(find({ state: "open" }), ["MF-416", "MF-1"], "open: not merged, closed or cancelled");
  assert.deepEqual(find({ owner: "bob" }), ["MF-2", "MF-416"]);
  assert.deepEqual(find({ owner: "@Alice" }), ["ATL-4", "MF-1"]);
  assert.deepEqual(find({ priority: "p1" }), ["MF-416", "MF-1"]);
  assert.deepEqual(find({ effort: "MCP Hardening" }), ["MF-416", "MF-1"]);
  assert.deepEqual(find({ q: "mcp", goal: "MF", state: "open" }), ["MF-416", "MF-1"]);
  assert.deepEqual(find({ q: "mcp", state: "open", owner: "alice" }), ["MF-1"]);
  assert.deepEqual(find({ q: "mcp", goal: "ATL" }), ["ATL-4"]);
  assert.deepEqual(find({ q: "rate", priority: "p2" }), ["MF-2"]);
  assert.deepEqual(find({ q: "rate", goal: "MF", state: "open", owner: "alice", priority: "p1", effort: "mcp hardening" }), ["MF-1"]);
  assert.deepEqual(find({ q: "tile", state: "open" }), []);
});

test("list_tasks never searches plan text, comments or logs; the caller caps what it returns", () => {
  const hidden = task({ id: "MF-9", goal: "g1", title: "Quiet", brief: "", plan: [{ text: "secretword in a step", file: "a.ts", added: false }],
    comments: [{ id: "c1", author: "bob", text: "secretword in a comment", at: 1 }], liveLog: "secretword in a log", planSummary: "secretword" });
  assert.deepEqual(filterTasks([hidden], goals, { q: "secretword" }), []);
  assert.deepEqual(ids(filterTasks([hidden], goals, { q: "quiet" })), ["MF-9"]);
  const many = Array.from({ length: 150 }, (_, i) => task({ id: `MF-${1000 + i}`, goal: "g1", title: `Bulk ${i}`, updatedAt: i }));
  const found = filterTasks(many, goals, { q: "bulk" });
  assert.equal(found.length, 150, "the filter returns every match, so the tool can say 'N of M'");
  assert.equal(found.slice(0, 100)[0]!.id, "MF-1149", "and the cap keeps the most recent");
});

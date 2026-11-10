// The org's and a goal's prompt additions: each role gets its own, the org's before the goal's, and
// both after the brief but before the factory's own instructions.
import { test } from "node:test";
import assert from "node:assert/strict";
import { builderPrompt, cleanPrompts, MEMORY_SECTION_MAX, memorySection, pickMemories, plannerPrompt, reviewerPrompt } from "../src/factory/prompts.ts";
import type { Goal, Memory, PromptAdditions, Task } from "../src/wire.ts";

const task = {
  id: "MF-1", goal: "g", title: "Add a thing", state: "planning", owner: "me", brief: "Add the thing.", createdAt: 0, updatedAt: 0,
  plan: [{ text: "Do it", file: "a.ts", added: true }], planVersion: 1, planSummary: "Do it.", doneWhen: [{ text: "It works", proof: "tests", status: "pending" }],
  approvals: [], approvalsNeeded: 1, reviews: [], reviewsNeeded: 1, comments: [], changes: [], events: [], mockups: [], tickets: [],
  shareable: false, agent: "claude", after: [],
} as unknown as Task;

const org: PromptAdditions = { planner: "ORG PLANNING", builder: "ORG BUILDING", reviewer: "ORG REVIEW" };
const goal = (prompts: PromptAdditions | null) =>
  ({ id: "g", name: "Goal", prefix: "MF", color: "#000000", summary: "", lead: "me", repos: [], prompts }) as unknown as Goal;

test("a planner prompt gets the org's planning text, then the goal's, after the brief and before submit_plan", () => {
  const p = plannerPrompt(task, goal({ planner: "GOAL PLANNING", builder: "GOAL BUILDING", reviewer: "" }), org);
  const at = (s: string) => p.indexOf(s);
  assert.ok(at("## Brief") < at("## Org instructions\nORG PLANNING"));
  assert.ok(at("## Org instructions\nORG PLANNING") < at("## Goal instructions\nGOAL PLANNING"));
  assert.ok(at("## Goal instructions\nGOAL PLANNING") < at("`submit_plan`"));
  assert.ok(!p.includes("ORG BUILDING") && !p.includes("GOAL BUILDING") && !p.includes("ORG REVIEW"));
});

test("a planner prompt offers an optional title, quoting the current one", () => {
  const p = plannerPrompt(task, goal(null), null);
  assert.ok(p.includes('- title (optional): a clearer title for the task, only when its current one ("Add a thing") is vague or misleading'));
  assert.ok(p.indexOf("- title (optional)") < p.indexOf("- steps:"));
});

test("a builder prompt with no additions is what it was without them", () => {
  const empty = { planner: "", builder: "  ", reviewer: "" };
  const before = builderPrompt(task, goal(null), null);
  assert.equal(builderPrompt(task, goal(empty), null, empty), before);
  assert.equal(builderPrompt(task, goal(null), null, null), before);
  assert.ok(!before.includes("## Org instructions") && !before.includes("## Goal instructions"));
});

test("a reviewer prompt gets only the reviewer field", () => {
  const p = reviewerPrompt(task, goal({ planner: "GOAL PLANNING", builder: "", reviewer: "GOAL REVIEW" }), "main", org);
  assert.ok(p.includes("## Org instructions\nORG REVIEW"));
  assert.ok(p.includes("## Goal instructions\nGOAL REVIEW"));
  assert.ok(p.indexOf("ORG REVIEW") < p.indexOf("GOAL REVIEW") && p.indexOf("GOAL REVIEW") < p.indexOf("`submit_review`"));
  assert.ok(!p.includes("PLANNING") && !p.includes("ORG BUILDING"));
});

test("saved additions are trimmed and capped", () => {
  const p = cleanPrompts({ planner: "  hi  ", builder: "x".repeat(5000), reviewer: "" });
  assert.equal(p.planner, "hi");
  assert.equal(p.builder.length, 4000);
});

test("planner and builder prompts list the work in flight in the same repo, with its files", () => {
  const others = [
    { id: "MF-2", title: "Rework the engine", state: "reviewing", files: ["src/engine.ts", "src/store.ts"] },
    { id: "MF-3", title: "Just started", state: "building", files: [] },
  ];
  for (const p of [plannerPrompt(task, goal(null), null, others), builderPrompt(task, goal(null), null, null, others)]) {
    assert.ok(p.includes("## Work in flight in this repo"));
    assert.ok(p.includes("- MF-2 · Rework the engine (reviewing): src/engine.ts, src/store.ts"));
    assert.ok(p.includes("- MF-3 · Just started (building): no files pushed yet"));
  }
  assert.ok(!plannerPrompt(task, goal(null)).includes("## Work in flight"));
});

test("only the builder prompt invites subagents, capped at 3", () => {
  const b = builderPrompt(task, goal(null), null);
  assert.match(b, /You may use subagents/);
  assert.match(b, /at most 3 at a time/);
  // It sits with the how-to-work lines, right after the commit line.
  assert.match(b, /call `progress` with its id in `applied`\.\nYou may use subagents/);
  for (const p of [plannerPrompt(task, goal(null)), reviewerPrompt(task, goal(null), "main")]) assert.doesNotMatch(p, /subagent/i);
});

// MF-393: "What the factory remembers".
const DAY = 24 * 60 * 60 * 1000;
const NOW = 1_000 * DAY;
const mem = (id: string, kind: "org" | "repo" | "goal", more: Partial<Memory> = {}): Memory => ({
  id, scope: { kind, key: kind === "org" ? null : kind === "repo" ? "acme/app" : "g" }, kind: "gotcha", text: `note ${id}`, tags: [], status: "active",
  source: { by: "me" }, createdAt: NOW - 30 * DAY, updatedAt: NOW - 30 * DAY, lastUsedAt: null, uses: 0, ...more,
});

test("memories rank goal over repo over org, all else equal", () => {
  const picked = pickMemories([mem("a", "org"), mem("b", "repo"), mem("c", "goal")], [], MEMORY_SECTION_MAX, NOW);
  assert.deepEqual(picked.map((m) => m.id), ["c", "b", "a"]);
});

test("a match on the task's title and brief lifts a memory above a wider scope's", () => {
  const picked = pickMemories([mem("a", "org"), mem("b", "repo"), mem("c", "goal")], ["a"], MEMORY_SECTION_MAX, NOW);
  assert.deepEqual(picked.map((m) => m.id), ["a", "c", "b"]);
});

test("uses and recency break ties within a scope, then the id", () => {
  const used = pickMemories([mem("a", "repo"), mem("b", "repo", { uses: 7 })], [], MEMORY_SECTION_MAX, NOW);
  assert.deepEqual(used.map((m) => m.id), ["b", "a"]);
  const recent = pickMemories([mem("a", "repo"), mem("b", "repo", { lastUsedAt: NOW - DAY })], [], MEMORY_SECTION_MAX, NOW);
  assert.deepEqual(recent.map((m) => m.id), ["b", "a"]);
  const edited = pickMemories([mem("a", "repo"), mem("b", "repo", { updatedAt: NOW })], [], MEMORY_SECTION_MAX, NOW);
  assert.deepEqual(edited.map((m) => m.id), ["b", "a"]);
  assert.deepEqual(pickMemories([mem("b", "repo"), mem("a", "repo")], [], MEMORY_SECTION_MAX, NOW).map((m) => m.id), ["a", "b"]);
});

test("the list keeps whole entries and stays within about 3,000 characters", () => {
  const many = Array.from({ length: 20 }, (_, i) => mem(`m${String(i).padStart(2, "0")}`, "repo", { text: "x".repeat(580) }));
  const picked = pickMemories(many, [], MEMORY_SECTION_MAX, NOW);
  assert.ok(picked.length > 0 && picked.length < many.length);
  const section = memorySection("builder", picked);
  const lines = section.split("\n").filter((l) => l.startsWith("- [gotcha]"));
  assert.equal(lines.length, picked.length);
  for (const l of lines) assert.match(l, /^- \[gotcha\] x{580} \(m\d\d\)$/, "whole entries only");
  assert.ok(lines.join("\n").length <= MEMORY_SECTION_MAX, `${lines.join("\n").length}`);
  // One more would have gone past it.
  const next = `- [gotcha] ${"x".repeat(580)} (m99)`;
  assert.ok(lines.join("\n").length + 1 + next.length > MEMORY_SECTION_MAX);
  assert.equal(MEMORY_SECTION_MAX, 3000);
});

test("the section goes after the role's instructions from extra() and before its tool instructions", () => {
  const g = goal({ planner: "GOAL PLANNING", builder: "GOAL BUILDING", reviewer: "GOAL REVIEW" });
  const picked = [mem("c", "goal", { text: "Use the scheme MapleTests." })];
  const cases = [
    ["planner", plannerPrompt(task, g, org, [], null, [], null, null, memorySection("planner", picked)), "GOAL PLANNING", "Read the repository"],
    ["builder", builderPrompt(task, g, null, org, [], null, [], null, memorySection("builder", picked)), "GOAL BUILDING", "## Approved plan"],
    ["reviewer", reviewerPrompt(task, g, "main", org, null, null, null, memorySection("reviewer", picked)), "GOAL REVIEW", "## The plan it was built to"],
  ] as const;
  for (const [role, p, goalText, next] of cases) {
    const at = p.indexOf("## What the factory remembers");
    assert.ok(at > p.indexOf(goalText) && p.indexOf(goalText) > 0, role);
    assert.ok(at < p.indexOf(next), role);
    assert.ok(p.includes("- [gotcha] Use the scheme MapleTests. (c)"), role);
  }
});

test("each role gets its own nudge; the reviewer's says forget", () => {
  const planner = memorySection("planner", [mem("a", "org")]);
  const builder = memorySection("builder", [mem("a", "org")]);
  const reviewer = memorySection("reviewer", [mem("a", "org")]);
  for (const s of [planner, builder, reviewer]) {
    assert.match(s, /`recall`/);
    assert.match(s, /`remember` anything non-obvious/);
    assert.match(s, /not what the code, git history or this prompt already say/);
  }
  assert.match(planner, /Before `submit_plan`/);
  assert.match(builder, /Before `finish`/);
  assert.match(reviewer, /Before `submit_review`/);
  assert.match(reviewer, /`forget` it \(with a reason\)/);
  assert.match(reviewer, /`supersedes`/);
  assert.ok(!planner.includes("`forget`") && !builder.includes("`forget`"));
});

test("with nothing remembered the section still says so and still nudges", () => {
  const s = memorySection("builder", []);
  assert.match(s, /## What the factory remembers/);
  assert.match(s, /Nothing remembered for this org, repo or goal yet\./);
  assert.match(s, /`recall`/);
  assert.match(s, /Before `finish`, `remember`/);
  assert.equal(builderPrompt(task, goal(null), null), builderPrompt(task, goal(null), null, null, [], null, [], null, ""), "no section unless the engine passes one");
});

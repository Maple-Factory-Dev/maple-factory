// The org's and a goal's prompt additions: each role gets its own, the org's before the goal's, and
// both after the brief but before the factory's own instructions.
import { test } from "node:test";
import assert from "node:assert/strict";
import { builderPrompt, cleanPrompts, plannerPrompt, reviewerPrompt } from "../src/factory/prompts.ts";
import type { Goal, PromptAdditions, Task } from "../src/wire.ts";

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

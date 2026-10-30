// forecast.ts: in-flight tasks in one repo and base whose diffs share files are linked both ways;
// merged, cancelled and drafting tasks, other repos and other bases never are.
import { test } from "node:test";
import assert from "node:assert/strict";
import { affectedBy, overlaps, refreshOverlaps, type Lane } from "../src/factory/forecast.ts";
import type { Task } from "../src/wire.ts";

function task(id: string, files: string[], f: Record<string, unknown> = {}): Task {
  return {
    id, goal: "g1", title: id, state: "reviewing", owner: "me", brief: "", createdAt: 0, updatedAt: 0, plan: [], planVersion: 1, doneWhen: [],
    approvals: [], approvalsNeeded: 1, reviews: [], reviewsNeeded: 1, comments: [], changes: [], events: [], mockups: [], tickets: [],
    shareable: false, agent: "claude", repo: "acme/app", after: [], followUps: [], diff: { added: 1, removed: 0, files }, ...f,
  } as never;
}

const lane = (t: Task & { base?: string }): Lane | null => (t.repo ? { repo: t.repo, base: t.base ?? "main" } : null);

test("overlapping open tasks in the same repo and base are linked both ways", () => {
  const tasks = [
    task("MF-1", ["src/engine.ts", "src/a.ts"]),
    task("MF-2", ["src/engine.ts", "src/a.ts", "README.md"], { state: "building" }),
    task("MF-3", ["src/other.ts"]),
  ];
  const o = overlaps(tasks, lane);
  assert.deepEqual(o.get("MF-1"), [{ task: "MF-2", files: ["src/a.ts", "src/engine.ts"] }]);
  assert.deepEqual(o.get("MF-2"), [{ task: "MF-1", files: ["src/a.ts", "src/engine.ts"] }]);
  assert.deepEqual(o.get("MF-3"), []);
});

test("merged and cancelled tasks, other repos and other bases are ignored", () => {
  const tasks = [
    task("MF-1", ["src/engine.ts"]),
    task("MF-2", ["src/engine.ts"], { state: "merged" }),
    task("MF-3", ["src/engine.ts"], { state: "cancelled" }),
    task("MF-4", ["src/engine.ts"], { repo: "acme/web" }),
    task("MF-5", ["src/engine.ts"], { base: "release" }),
    task("MF-6", ["src/engine.ts"], { state: "drafting" }),
    task("MF-7", ["src/engine.ts"], { repo: "ACME/App" }),
  ];
  const o = overlaps(tasks, lane);
  assert.deepEqual(o.get("MF-1"), [{ task: "MF-7", files: ["src/engine.ts"] }]);
  assert.equal(o.get("MF-2"), undefined);
  assert.equal(o.get("MF-3"), undefined);
  assert.deepEqual(o.get("MF-4"), []);
  assert.deepEqual(o.get("MF-5"), []);
});

test("refreshOverlaps writes the forecasts, clears them once a task merges, and reports only changes", () => {
  const a = task("MF-1", ["x.ts"]);
  const b = task("MF-2", ["x.ts"], { mergeForecast: { overlaps: [], conflicts: ["x.ts"], since: "MF-9", checkedAt: 5, base: "main" } });
  const c = task("MF-10", ["y.ts"]);
  assert.deepEqual(refreshOverlaps([a, b, c], lane).map((t) => t.id), ["MF-1", "MF-2"]);
  assert.deepEqual(a.mergeForecast!.overlaps, [{ task: "MF-2", files: ["x.ts"] }]);
  // The rest of a forecast (a conflict found earlier) is kept.
  assert.deepEqual(b.mergeForecast, { overlaps: [{ task: "MF-1", files: ["x.ts"] }], conflicts: ["x.ts"], since: "MF-9", checkedAt: 5, base: "main" });
  assert.deepEqual(refreshOverlaps([a, b, c], lane), []);

  // MF-1 merges: it's what MF-2 must be checked against, then neither lists the other.
  assert.deepEqual(affectedBy(a, [a, b, c]).map((t) => t.id), ["MF-2"]);
  a.state = "merged";
  assert.deepEqual(refreshOverlaps([a, b, c], lane).map((t) => t.id), ["MF-1", "MF-2"]);
  assert.deepEqual([a.mergeForecast!.overlaps, b.mergeForecast!.overlaps], [[], []]);
});

test("tasks without a diff or a lane overlap nothing", () => {
  const o = overlaps([task("MF-1", ["x.ts"]), task("MF-2", [], { diff: null }), task("MF-3", ["x.ts"], { repo: null })], lane);
  assert.deepEqual([o.get("MF-1"), o.get("MF-2"), o.get("MF-3")], [[], [], []]);
});

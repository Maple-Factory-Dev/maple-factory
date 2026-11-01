import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { checkDir, checkEvents, checkJsonl } from "./check.ts";

const dir = join(dirname(fileURLToPath(import.meta.url)), "session-events");
const load = (f: string) => JSON.parse(readFileSync(join(dir, f), "utf8")) as Record<string, unknown>[];

test("the committed Claude and Codex fixtures pass", () => {
  assert.deepEqual(checkDir(dir), []);
  assert.ok(load("claude.expected.json").length > 0);
  assert.ok(load("codex.expected.json").length > 0);
});

test("an unknown variant fails", () => {
  const events = load("claude.expected.json");
  events[1] = { ...events[1], type: "tool.started" };
  assert.match(checkEvents(events).join("\n"), /unknown SessionEvent type "tool.started"/);
});

test("seq out of order fails", () => {
  const events = load("codex.expected.json");
  events[2] = { ...events[2], seq: 1 };
  assert.match(checkEvents(events).join("\n"), /seq: 1 after 2/);
});

test("a missing required field, an unknown field and a bad enum fail", () => {
  const [first] = load("claude.expected.json");
  const { text: _, ...noText } = first;
  assert.match(checkEvents([noText]).join("\n"), /\.text: missing/);
  assert.match(checkEvents([{ ...first, extra: 1 }]).join("\n"), /\.extra: not in the schema/);
  const turn = load("codex.expected.json").find((e) => e.type === "turn")!;
  assert.match(checkEvents([{ ...turn, state: "paused" }]).join("\n"), /"paused" isn't a TurnState/);
});

test("a broken source line fails", () => {
  assert.deepEqual(checkJsonl('{"a":1}\n\n', "x.jsonl"), []);
  assert.match(checkJsonl('{"a":1}\n{"a":', "x.jsonl").join(), /x.jsonl:2/);
});

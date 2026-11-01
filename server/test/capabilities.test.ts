// Machine capability tags: what the apps show (detected minus hidden, plus extra), and the owner's tags tidied or refused.
import { test } from "node:test";
import assert from "node:assert/strict";
import { cleanTags, effectiveTags, offlineMachine, parseCapabilities, type MachineRow } from "../src/machines.ts";

test("tags shown: detected minus hidden, plus extra, sorted and once each", () => {
  assert.deepEqual(effectiveTags(["x86_64", "linux", "docker", "node"], { hiddenTags: ["docker"], extraTags: ["gpu", "node"] }), ["gpu", "linux", "node", "x86_64"]);
  assert.deepEqual(effectiveTags(null, { extraTags: ["big-disk"] }), ["big-disk"]);
  assert.deepEqual(effectiveTags(["macos", "arm64"], null), ["arm64", "macos"]);
  assert.deepEqual(effectiveTags(undefined, undefined), []);
  // Hiding a tag the owner also added by hand keeps it: they asked for it.
  assert.deepEqual(effectiveTags(["gpu"], { hiddenTags: ["gpu"], extraTags: ["gpu"] }), ["gpu"]);
});

test("owner tags are trimmed, lowercased and deduped; bad ones are refused with a reason", () => {
  assert.deepEqual(cleanTags([" GPU ", "big-disk", "gpu", ""], "Tags"), { tags: ["gpu", "big-disk"] });
  assert.deepEqual(cleanTags(undefined, "Tags"), { tags: [] });
  assert.match((cleanTags(["has space"], "Tags") as { error: string }).error, /isn't a tag/);
  assert.match((cleanTags(["-dash"], "Tags") as { error: string }).error, /isn't a tag/);
  assert.match((cleanTags(["émoji"], "Tags") as { error: string }).error, /isn't a tag/);
  assert.match((cleanTags(["a".repeat(33)], "Tags") as { error: string }).error, /too long/);
  assert.match((cleanTags(Array.from({ length: 21 }, (_, i) => `t${i}`), "Tags") as { error: string }).error, /at most 20/);
  assert.match((cleanTags("gpu", "Tags") as { error: string }).error, /list/);
});

test("the D1 column parses back; a missing or broken one is none", () => {
  assert.deepEqual(parseCapabilities('["linux","docker"]'), ["linux", "docker"]);
  assert.equal(parseCapabilities(null), null);
  assert.equal(parseCapabilities("not json"), null);
  const row = { id: "box", name: null, owner: "o", token_hash: "", hostname: null, os: "linux", arch: "x86_64", version: null, created_at: 0, last_seen: 1, capabilities: '["docker","linux"]' } satisfies MachineRow;
  assert.deepEqual(offlineMachine(row).capabilities, ["docker", "linux"]);
});

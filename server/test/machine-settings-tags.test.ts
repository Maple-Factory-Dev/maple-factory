// machine.settings with tags: the owner's extra and hidden tags are tidied and saved, bad ones refused, and an
// app that sends no tags keeps the saved ones. Through the engine on a node:sqlite store (as followups.test.ts does).
import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { Engine } from "../src/factory/engine.ts";
import { Store } from "../src/factory/store.ts";
import type { ClientMessage } from "../src/wire.ts";

function sqlStorage() {
  const db = new DatabaseSync(":memory:");
  return {
    exec(query: string, ...bindings: unknown[]) {
      const statements = query.split(";").map((s) => s.trim()).filter(Boolean);
      if (statements.length > 1) {
        db.exec(query);
        return { toArray: () => [], one: () => undefined };
      }
      const rows = db.prepare(query).all(...(bindings as never[]));
      return { toArray: () => rows, one: () => rows[0] };
    },
  } as unknown as SqlStorage;
}

function factory() {
  const store = new Store(sqlStorage());
  const machine = { id: "box", name: "box", owner: "me", online: true, sessions: [], usage: [], health: { cores: 8 } };
  const hooks = {
    broadcast: () => {}, sendTo: () => {}, machines: async () => [machine], members: async () => [],
    machineChanged: async () => {}, waitUntil: () => {}, wakeIn: () => {},
  };
  const DB = { prepare: () => ({ bind: () => ({ run: async () => {} }) }) };
  const engine = new Engine({ DB } as never, store, hooks as never, { forTask: () => {}, accepted: () => {} } as never, {} as never);
  const send = (settings: Record<string, unknown>, login = "me") =>
    engine.command({ type: "machine.settings", machine: "box", settings: { teamSlots: 0, lendIdle: false, loadCap: 0.8, paused: false, ...settings } } as unknown as ClientMessage, { member: { login, role: "member" } } as never);
  return { store, send };
}

test("machine.settings saves the owner's tags tidied", async () => {
  const { store, send } = factory();
  await send({ extraTags: [" GPU", "big-disk", "gpu"], hiddenTags: ["docker"] });
  assert.deepEqual(store.settings("box").extraTags, ["gpu", "big-disk"]);
  assert.deepEqual(store.settings("box").hiddenTags, ["docker"]);
  // An older app sends no tags: the saved ones stay.
  await send({ loadCap: 0.5 });
  assert.deepEqual(store.settings("box").extraTags, ["gpu", "big-disk"]);
  assert.deepEqual(store.settings("box").hiddenTags, ["docker"]);
});

test("machine.settings refuses bad tags and saves nothing", async () => {
  const { store, send } = factory();
  await send({ extraTags: ["gpu"] });
  for (const [tags, why] of [[["has space"], /isn't a tag/], [["x".repeat(40)], /too long/], [Array.from({ length: 21 }, (_, i) => `t${i}`), /at most 20/]] as const) {
    await assert.rejects(send({ extraTags: tags }), why);
  }
  await assert.rejects(send({ hiddenTags: ["Bad_Tag"] }), /isn't a tag/);
  assert.deepEqual(store.settings("box").extraTags, ["gpu"]);
});

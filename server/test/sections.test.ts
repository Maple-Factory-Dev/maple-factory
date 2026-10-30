// Which Inbox and Tasks sections are collapsed: toggled, saved in localStorage, and all expanded when storage fails.
import { test } from "node:test";
import assert from "node:assert/strict";
import { COLLAPSED_KEY, loadCollapsed, toggleCollapsed } from "../web/app/sections.js";

/** A stand-in for localStorage. */
function fakeStorage(items: Record<string, string> = {}) {
  return {
    items,
    getItem: (k: string) => (k in items ? items[k] : null),
    setItem: (k: string, v: string) => { items[k] = String(v); },
  };
}
const throwing = { getItem: () => { throw new Error("blocked"); }, setItem: () => { throw new Error("blocked"); } };

test("toggling adds a key, then takes it away", () => {
  const storage = fakeStorage();
  const collapsed = loadCollapsed(storage);
  assert.equal(toggleCollapsed(collapsed, "tasks:drafts", storage), true);
  assert.deepEqual([...collapsed], ["tasks:drafts"]);
  assert.equal(toggleCollapsed(collapsed, "inbox:mentions", storage), true);
  assert.equal(toggleCollapsed(collapsed, "tasks:drafts", storage), false);
  assert.deepEqual([...collapsed], ["inbox:mentions"]);
});

test("the collapsed sections round-trip through storage", () => {
  const storage = fakeStorage();
  const collapsed = loadCollapsed(storage);
  toggleCollapsed(collapsed, "tasks:drafts", storage);
  toggleCollapsed(collapsed, "inbox:review", storage);
  assert.deepEqual(JSON.parse(storage.items[COLLAPSED_KEY]), ["tasks:drafts", "inbox:review"]);
  assert.deepEqual([...loadCollapsed(storage)].sort(), ["inbox:review", "tasks:drafts"]);
  toggleCollapsed(collapsed, "tasks:drafts", storage);
  assert.deepEqual([...loadCollapsed(storage)], ["inbox:review"]);
});

test("empty, missing, garbled or throwing storage leaves everything expanded", () => {
  assert.equal(loadCollapsed(fakeStorage()).size, 0);
  assert.equal(loadCollapsed(null).size, 0);
  assert.equal(loadCollapsed(fakeStorage({ [COLLAPSED_KEY]: "{not json" })).size, 0);
  assert.equal(loadCollapsed(fakeStorage({ [COLLAPSED_KEY]: '{"a":1}' })).size, 0);
  assert.deepEqual([...loadCollapsed(fakeStorage({ [COLLAPSED_KEY]: '["tasks:queued", 3]' }))], ["tasks:queued"]);
  assert.equal(loadCollapsed(throwing).size, 0);
});

test("toggling still works for the visit when storage throws or is missing", () => {
  const collapsed = loadCollapsed(throwing);
  assert.equal(toggleCollapsed(collapsed, "tasks:backlog", throwing), true);
  assert.equal(toggleCollapsed(collapsed, "tasks:queued", null), true);
  assert.deepEqual([...collapsed], ["tasks:backlog", "tasks:queued"]);
});

test("with no localStorage at all (as in node), the default is everything expanded", () => {
  const collapsed = loadCollapsed();
  assert.equal(collapsed.size, 0);
  assert.equal(toggleCollapsed(collapsed, "tasks:drafts"), true);
});

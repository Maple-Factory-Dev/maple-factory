// Which sections of the Inbox and Tasks pages are collapsed, kept in this browser like dismissed mentions.
// Keys are "<page>:<section>" ("tasks:drafts", "inbox:mentions"). Storage that's blocked or throws
// leaves every section expanded, and toggling still works for this visit.

export const COLLAPSED_KEY = "maple.collapsedSections";

const storageOf = (storage) => {
  try { return storage === undefined ? globalThis.localStorage : storage; } catch { return null; }
};

/** The collapsed section keys saved in `storage` (localStorage by default); empty if there are none or it can't be read. */
export function loadCollapsed(storage) {
  try {
    const keys = JSON.parse(storageOf(storage)?.getItem(COLLAPSED_KEY) ?? "[]");
    return new Set(Array.isArray(keys) ? keys.filter((k) => typeof k === "string") : []);
  } catch {
    return new Set();
  }
}

/** Collapses `key` if it's expanded or expands it if it's collapsed, saves the set, and says whether it's now collapsed. */
export function toggleCollapsed(collapsed, key, storage) {
  if (collapsed.has(key)) collapsed.delete(key);
  else collapsed.add(key);
  try { storageOf(storage)?.setItem(COLLAPSED_KEY, JSON.stringify([...collapsed])); } catch {}
  return collapsed.has(key);
}

// The task page's sections in its stage's order (TaskPageLayout.sections(for:) on the Mac): while a
// plan is written and approved the brief leads; once there are changes the review and its proofs
// lead, and the brief and plan fold to a line each.
const REVIEW_ORDER = ["summary", "doneWhen", "review", "artifacts", "mockups", "brief", "plan", "followUps", "risk", "timeline"];
const BUILD_ORDER = ["plan", "followUps", "doneWhen", "review", "artifacts", "mockups", "brief", "risk", "timeline"];
const PLAN_ORDER = ["brief", "review", "mockups", "artifacts", "plan", "followUps", "doneWhen", "risk", "timeline"];

/** `{ order, folded }` for a task in `state`: the section keys top to bottom, and the ones that start folded. */
export function sectionOrder(state) {
  switch (state) {
    case "reviewing": case "merged": case "closed": return { order: REVIEW_ORDER, folded: new Set(["brief", "plan"]) };
    case "building": return { order: BUILD_ORDER, folded: new Set(["brief"]) };
    default: return { order: PLAN_ORDER, folded: new Set() };
  }
}

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

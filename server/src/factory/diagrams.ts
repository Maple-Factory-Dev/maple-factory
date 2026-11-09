// Mermaid diagrams a planner attaches to a plan (MF-358). Stored on the task next to its mockups;
// every client renders them offline through the shared assets/mermaid/diagram.html viewer.
import type { Diagram } from "../wire.ts";

export const MAX_DIAGRAMS = 6;
export const MAX_DIAGRAM_SOURCE = 20_000;
const MAX_TITLE = 120;
const MAX_NOTES = 12;

/** submit_plan's `diagrams`, checked and numbered D1…; throws a message the planner can act on. */
export function parseDiagrams(raw: unknown, fail: (message: string) => never): Diagram[] {
  if (raw == null) return [];
  if (!Array.isArray(raw)) fail("diagrams: a list of { title, source, notes }.");
  const list = raw as unknown[];
  if (list.length > MAX_DIAGRAMS) fail(`diagrams: at most ${MAX_DIAGRAMS}; keep the ones that explain the change best.`);
  return list.map((x, i) => {
    const d = (x && typeof x === "object" ? x : {}) as Record<string, unknown>;
    const title = typeof d.title === "string" ? d.title.trim().slice(0, MAX_TITLE).trim() : "";
    if (!title) fail(`diagrams[${i}].title: required.`);
    const source = typeof d.source === "string" ? d.source.replace(/\r\n?/g, "\n").trim() : "";
    if (!source) fail(`diagrams[${i}].source: required, as Mermaid source (e.g. "flowchart LR\\n  A --> B").`);
    if (source.length > MAX_DIAGRAM_SOURCE) fail(`diagrams[${i}].source: ${source.length} characters; at most ${MAX_DIAGRAM_SOURCE}. Split it or leave detail out.`);
    const notes = Array.isArray(d.notes) ? d.notes.map((n) => String(n).slice(0, 500)).filter(Boolean).slice(0, MAX_NOTES) : [];
    return { id: `D${i + 1}`, title, source, notes };
  });
}

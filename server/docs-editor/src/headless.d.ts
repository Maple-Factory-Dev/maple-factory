// Types for headless.js (MF-365), for the server's TypeScript.
import type * as Yjs from "yjs";
import type { DocAnchor, DocThread } from "../../src/wire.ts";

export const SHARED_TYPE: string;
export const BLOCK_ID: RegExp;
export class DocToolError extends Error {}
export interface ReadDoc {
  markdown: string;
  blocks: { id: string | null; markdown: string }[];
  threads: { id: string; block: string | null; quote: string | null; orphan: boolean }[];
}
export function readDoc(ydoc: Yjs.Doc, threads?: Pick<DocThread, "id" | "anchor">[]): ReadDoc;
export function anchorFor(ydoc: Yjs.Doc, at?: { block?: string | null; quote?: string | null }): DocAnchor;
export function applySuggestion(ydoc: Yjs.Doc, anchor: DocAnchor, markdown: string, origin?: unknown): { before: string; after: unknown };
export function seedDoc(ydoc: Yjs.Doc, markdown: string): Yjs.Doc;
export const Y: typeof Yjs;

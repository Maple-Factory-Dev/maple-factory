// Types for split.js (MF-368), for the server's TypeScript.
export const MAX_TASKS: number;
export const MAX_TITLE: number;
export function titleOf(line: string): string;
export function splitSection(markdown: string, mode?: "one" | "headings" | "items", fallbackTitle?: string): { title: string; brief: string }[];

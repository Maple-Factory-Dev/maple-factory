// Keeps the session-event fixtures honest: every expected event must be a valid SessionEvent per
// protocol/schema.ts, seq must go strictly up, and every line of each source JSONL must parse.
// node protocol/fixtures/check.ts    (also run by `npm run gen:check`)

import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { enums, structs, unions } from "../schema.ts";

const prims: Record<string, (v: unknown) => boolean> = {
  string: (v) => typeof v === "string",
  uuid: (v) => typeof v === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v),
  bool: (v) => typeof v === "boolean",
  json: () => true,
  f64: (v) => typeof v === "number",
  u16: (v) => Number.isInteger(v) && (v as number) >= 0,
  u32: (v) => Number.isInteger(v) && (v as number) >= 0,
  u64: (v) => Number.isInteger(v) && (v as number) >= 0,
  i32: (v) => Number.isInteger(v),
};

/** Problems with `value` as type `src` (schema syntax: `T`, `T?`, `T[]`, `map<T>`), each prefixed with `at`. */
export function checkType(src: string, value: unknown, at: string): string[] {
  if (src.endsWith("?")) return value === undefined || value === null ? [] : checkType(src.slice(0, -1), value, at);
  if (value === undefined) return [`${at}: missing`];
  if (src.endsWith("[]")) {
    if (!Array.isArray(value)) return [`${at}: want a list`];
    return value.flatMap((v, i) => checkType(src.slice(0, -2), v, `${at}[${i}]`));
  }
  const map = /^map<(.+)>$/.exec(src);
  if (map) {
    if (typeof value !== "object" || value === null || Array.isArray(value)) return [`${at}: want an object`];
    return Object.entries(value).flatMap(([k, v]) => checkType(map[1], v, `${at}.${k}`));
  }
  if (src in prims) return prims[src](value) ? [] : [`${at}: want ${src}, got ${JSON.stringify(value)?.slice(0, 40)}`];
  if (src in enums) return typeof value === "string" && value in enums[src].values ? [] : [`${at}: ${JSON.stringify(value)} isn't a ${src}`];
  if (src in structs) return checkFields(structs[src].fields, value, at);
  if (src in unions) {
    if (typeof value !== "object" || value === null) return [`${at}: want an object`];
    const tag = (value as { type?: unknown }).type;
    const variant = typeof tag === "string" ? unions[src].variants[tag] : undefined;
    if (!variant) return [`${at}: unknown ${src} type ${JSON.stringify(tag)}`];
    const { type: _, ...rest } = value as Record<string, unknown>;
    return checkFields(variant.fields ?? {}, rest, `${at}(${tag})`);
  }
  throw new Error(`schema type ${src} unknown`);
}

function checkFields(fields: Record<string, string>, value: unknown, at: string): string[] {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return [`${at}: want an object`];
  const obj = value as Record<string, unknown>;
  const problems = Object.keys(obj).filter((k) => !(k in fields)).map((k) => `${at}.${k}: not in the schema`);
  for (const [name, src] of Object.entries(fields)) problems.push(...checkType(src, obj[name], `${at}.${name}`));
  return problems;
}

/** Problems with a fixture's expected events: each a valid SessionEvent, seq strictly increasing. */
export function checkEvents(events: unknown, at = "events"): string[] {
  if (!Array.isArray(events)) return [`${at}: want a list of SessionEvent`];
  const problems = events.flatMap((e, i) => checkType("SessionEvent", e, `${at}[${i}]`));
  let last = -1;
  events.forEach((e, i) => {
    const seq = (e as { seq?: unknown })?.seq;
    if (typeof seq === "number") {
      if (seq <= last) problems.push(`${at}[${i}].seq: ${seq} after ${last}; seq must go strictly up`);
      last = seq;
    }
  });
  return problems;
}

/** Problems with a source transcript: every non-empty line must be a JSON object. */
export function checkJsonl(text: string, at: string): string[] {
  return text.split("\n").flatMap((line, i) => {
    if (!line.trim()) return [];
    try {
      const v = JSON.parse(line);
      return typeof v === "object" && v !== null && !Array.isArray(v) ? [] : [`${at}:${i + 1}: not a JSON object`];
    } catch (e) {
      return [`${at}:${i + 1}: ${(e as Error).message}`];
    }
  });
}

export function checkDir(dir: string): string[] {
  const files = readdirSync(dir);
  const problems: string[] = [];
  for (const f of files) {
    const text = readFileSync(join(dir, f), "utf8");
    if (f.endsWith(".expected.json")) problems.push(...checkEvents(JSON.parse(text), f));
    else if (f.endsWith(".jsonl")) problems.push(...checkJsonl(text, f));
  }
  if (!files.some((f) => f.endsWith(".expected.json"))) problems.push(`${dir}: no *.expected.json fixtures`);
  return problems;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const dir = join(dirname(fileURLToPath(import.meta.url)), "session-events");
  const problems = checkDir(dir);
  for (const p of problems) console.error(p);
  if (problems.length) process.exit(1);
  console.log(`fixtures ok: ${readdirSync(dir).filter((f) => f.endsWith(".expected.json")).join(", ")}`);
}

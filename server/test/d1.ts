// A D1Database over node:sqlite with the server's migrations applied, for tests that read and write D1.
import { DatabaseSync } from "node:sqlite";
import { readdirSync, readFileSync } from "node:fs";

export function d1(): D1Database & { sql: DatabaseSync } {
  const sql = new DatabaseSync(":memory:");
  const dir = new URL("../migrations/", import.meta.url);
  for (const f of readdirSync(dir).filter((f) => f.endsWith(".sql")).sort()) sql.exec(readFileSync(new URL(f, dir), "utf8"));
  const statement = (query: string, args: unknown[] = []) => ({
    bind: (...next: unknown[]) => statement(query, next),
    run: async () => (sql.prepare(query).run(...(args as never[])), { success: true }),
    first: async () => sql.prepare(query).get(...(args as never[])) ?? null,
    all: async () => ({ results: sql.prepare(query).all(...(args as never[])) }),
  });
  return { sql, prepare: (query: string) => statement(query) } as never;
}

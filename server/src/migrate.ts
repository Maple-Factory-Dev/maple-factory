// D1 migrations applied by the Worker itself, for hosts without wrangler's migrations CLI (celld dev:
// server/celld-entry.ts). On Cloudflare, `wrangler d1 migrations apply` does this and nothing here runs.
// The bookkeeping table is the same one wrangler keeps, so either can pick up where the other left off.

/** Every file in migrations/, in order. test/celld.test.ts fails when one is added there and not here. */
export const MIGRATIONS = [
  "0001_init.sql",
  "0002_ended_by.sql",
  "0003_settings.sql",
  "0004_admin_grants.sql",
  "0005_revocation.sql",
  "0006_member_github_tokens.sql",
  "0007_slack_links.sql",
  "0008_machine_capabilities.sql",
] as const;

export type MigrationName = (typeof MIGRATIONS)[number];

const TABLE = "CREATE TABLE IF NOT EXISTS d1_migrations(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE, applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL)";

/** A migration file's statements, one per batch() entry: `--` comments dropped, split on `;`. The
 *  migrations have no triggers or string literals holding `;`. */
export function statements(sql: string): string[] {
  return sql.replace(/--[^\n]*/g, "").split(";").map((s) => s.trim()).filter(Boolean);
}

/** Applies the files not yet recorded in d1_migrations, each in one batch with its record, in order.
 *  Returns the names applied. */
export async function applyMigrations(db: D1Database, files: Record<MigrationName, string>): Promise<string[]> {
  await db.prepare(TABLE).run();
  const rows = (await db.prepare("SELECT name FROM d1_migrations").all<{ name: string }>()).results;
  const done = new Set(rows.map((r) => r.name));
  const applied: string[] = [];
  for (const name of MIGRATIONS) {
    if (done.has(name)) continue;
    const sql = files[name];
    if (typeof sql !== "string") throw new Error(`migration ${name} isn't bundled`);
    await db.batch([...statements(sql).map((s) => db.prepare(s)), db.prepare("INSERT INTO d1_migrations (name) VALUES (?)").bind(name)]);
    applied.push(name);
  }
  return applied;
}

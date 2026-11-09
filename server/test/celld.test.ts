// Running outside Cloudflare on celld: the Worker's own migration list covers every file in migrations/
// and applies each once; celld.jsonc keeps the bindings wrangler.jsonc has; celld-entry.ts bundles every
// migration; and celld/install.sh picks the right release asset for each platform.
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { readdirSync, readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { MIGRATIONS, applyMigrations, statements } from "../src/migrate.ts";

const server = new URL("../", import.meta.url);
const read = (path: string) => readFileSync(new URL(path, server), "utf8");
const migrationFiles = () => readdirSync(new URL("migrations/", server)).filter((f) => f.endsWith(".sql")).sort();
const files = () => Object.fromEntries(MIGRATIONS.map((n) => [n, read(`migrations/${n}`)])) as Record<(typeof MIGRATIONS)[number], string>;

/** JSONC → JSON: drops // and block comments outside strings. */
const jsonc = (text: string) => JSON.parse(text.replace(/("(?:[^"\\]|\\.)*")|\/\/[^\n]*|\/\*[\s\S]*?\*\//g, (_, s) => s ?? ""));

/** A fake D1 over an empty node:sqlite database, with batch() run in one transaction as D1 does. */
function emptyD1() {
  const sql = new DatabaseSync(":memory:");
  const statement = (query: string, args: unknown[] = []) => ({
    query, args,
    bind: (...next: unknown[]) => statement(query, next),
    run: async () => (sql.prepare(query).run(...(args as never[])), { success: true }),
    all: async () => ({ results: sql.prepare(query).all(...(args as never[])) }),
  });
  const db = {
    prepare: (query: string) => statement(query),
    batch: async (list: ReturnType<typeof statement>[]) => {
      sql.exec("BEGIN");
      try {
        for (const s of list) sql.prepare(s.query).run(...(s.args as never[]));
        sql.exec("COMMIT");
      } catch (e) {
        sql.exec("ROLLBACK");
        throw e;
      }
      return [];
    },
  };
  return { sql, db: db as unknown as D1Database };
}

test("src/migrate.ts lists exactly the files in migrations/, in order", () => {
  assert.deepEqual([...MIGRATIONS], migrationFiles());
});

test("celld-entry.ts bundles every migration under its own name", () => {
  const entry = read("celld-entry.ts");
  for (const name of migrationFiles()) {
    assert.match(entry, new RegExp(`from "\\./migrations/${name.replace(".", "\\.")}"`), `${name} isn't imported`);
    assert.match(entry, new RegExp(`"${name.replace(".", "\\.")}":`), `${name} isn't in FILES`);
  }
});

test("migrations apply once, recorded the way wrangler records them, and a second run applies nothing", async () => {
  const { sql, db } = emptyD1();
  assert.deepEqual(await applyMigrations(db, files()), migrationFiles());
  const tables = (sql.prepare("SELECT name FROM sqlite_master WHERE type = 'table'").all() as { name: string }[]).map((r) => r.name);
  for (const t of ["members", "machines", "settings", "d1_migrations"]) assert.ok(tables.includes(t), `no ${t} table`);
  const recorded = sql.prepare("SELECT id, name, applied_at FROM d1_migrations ORDER BY id").all() as { name: string; applied_at: string }[];
  assert.deepEqual(recorded.map((r) => r.name), migrationFiles());
  assert.ok(recorded.every((r) => r.applied_at));
  assert.deepEqual(await applyMigrations(db, files()), []);
  assert.equal((sql.prepare("SELECT count(*) AS n FROM d1_migrations").get() as { n: number }).n, migrationFiles().length);
});

test("a database part-way through picks up only the migrations it's missing", async () => {
  const { sql, db } = emptyD1();
  const [first, ...rest] = MIGRATIONS;
  sql.exec(`CREATE TABLE d1_migrations(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE, applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL)`);
  sql.exec(read(`migrations/${first}`));
  sql.prepare("INSERT INTO d1_migrations (name) VALUES (?)").run(first);
  assert.deepEqual(await applyMigrations(db, files()), rest);
});

test("a migration missing from the bundle fails before it's recorded", async () => {
  const { db } = emptyD1();
  const partial = { ...files() } as Record<string, string>;
  delete partial[MIGRATIONS.at(-1)!];
  await assert.rejects(applyMigrations(db, partial as never), /isn't bundled/);
});

test("statements() drops comments and splits on semicolons", () => {
  assert.deepEqual(statements("-- a; comment\nCREATE TABLE a (x);\n\n  CREATE INDEX i ON a(x); -- trailing\n"), ["CREATE TABLE a (x)", "CREATE INDEX i ON a(x)"]);
});

test("celld.jsonc has wrangler.jsonc's bindings, migrations and vars, and none of the keys celld rejects", () => {
  const wrangler = jsonc(read("wrangler.jsonc"));
  const celld = jsonc(read("celld.jsonc"));
  for (const key of ["name", "compatibility_date", "assets", "durable_objects", "migrations", "d1_databases", "r2_buckets", "vars"]) {
    assert.deepEqual(celld[key], wrangler[key], `${key} differs from wrangler.jsonc`);
  }
  assert.equal(celld.main, "celld-entry.ts");
  assert.equal("dev" in celld, false);
  assert.equal("keep_vars" in celld, false);
  for (const flag of wrangler.compatibility_flags) assert.ok(celld.compatibility_flags.includes(flag), `missing flag ${flag}`);
  assert.ok(celld.compatibility_flags.includes("delete_all_deletes_alarm"));
  assert.deepEqual(celld.rules, [{ type: "Text", globs: ["**/*.sql"] }]);
});

const install = new URL("celld/install.sh", server).pathname;
const printAsset = (s: string, m: string) => spawnSync("sh", [install, "--print-asset"], { env: { ...process.env, CELLD_UNAME_S: s, CELLD_UNAME_M: m }, encoding: "utf8" });

test("install.sh fetches the right asset for each platform it supports", () => {
  for (const [s, m, asset] of [
    ["Darwin", "arm64", "celld-aarch64-apple-darwin.gz"],
    ["Linux", "aarch64", "celld-aarch64-unknown-linux-gnu.gz"],
    ["Linux", "arm64", "celld-aarch64-unknown-linux-gnu.gz"],
    ["Linux", "x86_64", "celld-x86_64-unknown-linux-gnu.gz"],
  ]) {
    const r = printAsset(s, m);
    assert.equal(r.status, 0, r.stderr);
    assert.equal(r.stdout.trim(), asset, `${s}/${m}`);
  }
});

test("install.sh refuses a platform celld doesn't ship for", () => {
  for (const [s, m] of [["Darwin", "x86_64"], ["Linux", "armv7l"], ["FreeBSD", "amd64"], ["MINGW64_NT-10.0", "x86_64"]]) {
    const r = printAsset(s, m);
    assert.notEqual(r.status, 0, `${s}/${m} should fail`);
    assert.match(r.stderr, new RegExp(`no build for ${s}/${m}`));
  }
});

test("install.sh pins a version and a sha256 for every asset", () => {
  const script = read("celld/install.sh");
  assert.match(script, /^CELLD_VERSION=\d+\.\d+\.\d+$/m);
  for (const v of ["aarch64_apple_darwin", "aarch64_unknown_linux_gnu", "x86_64_unknown_linux_gnu"]) assert.match(script, new RegExp(`^SHA_${v}=[0-9a-f]{64}$`, "m"));
  execFileSync("sh", ["-n", install]);
});

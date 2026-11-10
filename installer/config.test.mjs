// node --test: the wrangler configs installer/config.mjs builds for each target.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { buildConfig, checkBucket, checkTarget, CELLD_DATABASE_ID } from "./config.mjs";

/** JSONC → JSON: drops // and block comments outside strings (as server/test/celld.test.ts does). */
const jsonc = (text) => JSON.parse(text.replace(/("(?:[^"\\]|\\.)*")|\/\/[^\n]*|\/\*[\s\S]*?\*\//g, (_, s) => s ?? ""));
const celldJsonc = jsonc(readFileSync(new URL("../server/celld.jsonc", import.meta.url), "utf8"));

// A release's config.json, as scripts/release-server.mjs writes it.
const shared = {
  version: "0.105.0",
  main: "worker/index.js",
  compatibility_date: "2026-09-01",
  compatibility_flags: ["nodejs_als"],
  assets: { directory: "web", html_handling: "auto-trailing-slash" },
  durable_objects: { bindings: [{ name: "ORG", class_name: "OrgHub" }, { name: "MACHINE", class_name: "MachineHub" }, { name: "DOC", class_name: "DocHub" }] },
  migrations: [{ tag: "v1", new_sqlite_classes: ["OrgHub", "MachineHub"] }, { tag: "v2", new_sqlite_classes: ["DocHub"] }],
};
const cf = { name: "maple-factory", accountId: "a".repeat(32), databaseId: "d-1", bucket: "maple-factory", org: "acme", allow: ["octocat", "hubot"], channel: "stable", domain: "factory.acme.dev" };
const cd = { name: "maple-factory", target: "celld", bucket: "s3://maple", endpoint: "http://localhost:9000", url: "https://maple.acme.dev", org: "acme", allow: [], channel: "beta" };

test("cloudflare config is the shape the installer has always written (key order included)", () => {
  const { version: _v, ...rest } = shared;
  const expected = {
    ...rest,
    name: "maple-factory",
    account_id: "a".repeat(32),
    no_bundle: true,
    workers_dev: true,
    d1_databases: [{ binding: "DB", database_name: "maple-factory", database_id: "d-1", migrations_dir: "migrations" }],
    r2_buckets: [{ binding: "RELEASES", bucket_name: "maple-factory" }],
    vars: { GITHUB_ORG: "acme", GITHUB_ALLOWED_LOGINS: "octocat,hubot", RELEASE_CHANNEL: "stable", MAPLE_DEPLOY: "installer" },
    routes: [{ pattern: "factory.acme.dev", custom_domain: true }],
  };
  assert.equal(JSON.stringify(buildConfig(shared, cf)), JSON.stringify(expected));
  assert.equal(JSON.stringify(buildConfig(shared, cf, "cloudflare")), JSON.stringify(expected));
  assert.ok(!("routes" in buildConfig(shared, { ...cf, domain: null })));
});

test("celld config has none of the keys celld rejects, and delete_all_deletes_alarm once", () => {
  const config = buildConfig({ ...shared, keep_vars: true, dev: { host: "localhost" } }, cd, "celld");
  for (const key of ["keep_vars", "dev", "account_id", "workers_dev", "routes", "version"]) assert.ok(!(key in config), `${key} is in the celld config`);
  assert.deepEqual(config.compatibility_flags, ["nodejs_als", "delete_all_deletes_alarm"]);
  const again = buildConfig({ ...shared, compatibility_flags: ["nodejs_als", "delete_all_deletes_alarm"] }, cd, "celld");
  assert.equal(again.compatibility_flags.filter((f) => f === "delete_all_deletes_alarm").length, 1);
  assert.equal(config.main, "worker/index.js");
  assert.equal(config.no_bundle, true);
  assert.deepEqual(config.durable_objects, shared.durable_objects);
  assert.deepEqual(config.migrations, shared.migrations);
  assert.deepEqual(config.vars, { GITHUB_ORG: "acme", GITHUB_ALLOWED_LOGINS: "", RELEASE_CHANNEL: "beta", MAPLE_DEPLOY: "installer", PUBLIC_URL: "https://maple.acme.dev" });
  assert.deepEqual(config.d1_databases, [{ binding: "DB", database_name: "maple-factory", database_id: CELLD_DATABASE_ID, migrations_dir: "migrations" }]);
  assert.deepEqual(config.r2_buckets, [{ binding: "RELEASES", bucket_name: "maple-factory" }]);
});

test("celld config lines up with server/celld.jsonc's bindings and flags", () => {
  const config = buildConfig(shared, cd, "celld");
  assert.deepEqual(config.durable_objects, celldJsonc.durable_objects);
  assert.deepEqual(config.migrations, celldJsonc.migrations);
  assert.deepEqual([...config.compatibility_flags].sort(), [...celldJsonc.compatibility_flags].sort());
  assert.deepEqual(config.d1_databases.map((d) => [d.binding, d.migrations_dir]), celldJsonc.d1_databases.map((d) => [d.binding, d.migrations_dir]));
  assert.deepEqual(config.r2_buckets.map((b) => b.binding), celldJsonc.r2_buckets.map((b) => b.binding));
  assert.equal(config.assets.html_handling, celldJsonc.assets.html_handling);
  for (const key of Object.keys(celldJsonc.vars)) assert.ok(key in config.vars, `${key} missing from vars`);
  for (const key of Object.keys(config)) assert.ok(key in celldJsonc || ["no_bundle"].includes(key), `${key} isn't a key server/celld.jsonc uses`);
});

test("flag checks: --bucket and --target", () => {
  assert.equal(checkBucket("s3://maple-test"), null);
  assert.equal(checkBucket("s3://maple/fleet-a"), null);
  assert.equal(checkBucket("gs://maple"), null);
  assert.match(checkBucket(undefined), /needs --bucket/);
  for (const bad of ["maple", "http://maple", "s3://", "s3://Maple", "s3://a b"]) assert.match(checkBucket(bad), /isn't a bucket URL/, bad);
  assert.equal(checkTarget("cloudflare"), null);
  assert.equal(checkTarget("celld"), null);
  assert.match(checkTarget("fly"), /--target is cloudflare or celld/);
  assert.throws(() => buildConfig(shared, cf, "fly"), /Unknown target/);
});

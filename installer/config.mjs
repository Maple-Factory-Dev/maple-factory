// The deployment's wrangler config, built from the release's shared parts (its config.json) plus this
// factory's own. Pure, so both targets are unit-tested (config.test.mjs).
//
// cloudflare: what `wrangler deploy` takes for the org's own account.
// celld:      what `celld deploy` takes for a fleet bucket (github.com/denoland/celld 0.6.x). celld rejects
//             keys it doesn't know (account_id, workers_dev, routes, keep_vars, dev), so they're left out;
//             delete_all_deletes_alarm makes deleteAll() clear a hub's alarm as on Cloudflare (as
//             server/celld.jsonc does). D1 and R2 live inside the fleet bucket under these names.

export const TARGETS = ["cloudflare", "celld"];

/** celld's stand-in D1 id: celld keys a database by its database_id when it has one, else its name. */
export const CELLD_DATABASE_ID = "00000000-0000-0000-0000-000000000000";

export function buildConfig(shared, factory, target = "cloudflare") {
  if (!TARGETS.includes(target)) throw new Error(`Unknown target ${target}.`);
  const { version: _version, ...rest } = shared;
  // MAPLE_DEPLOY tells the factory it updates with `maple update`, for its update notice.
  const vars = { GITHUB_ORG: factory.org, GITHUB_ALLOWED_LOGINS: (factory.allow ?? []).join(","), RELEASE_CHANNEL: factory.channel, MAPLE_DEPLOY: "installer" };
  if (target === "cloudflare") {
    return {
      ...rest,
      name: factory.name,
      account_id: factory.accountId,
      no_bundle: true,
      workers_dev: true,
      d1_databases: [{ binding: "DB", database_name: factory.name, database_id: factory.databaseId, migrations_dir: "migrations" }],
      r2_buckets: [{ binding: "RELEASES", bucket_name: factory.bucket }],
      vars,
      ...(factory.domain ? { routes: [{ pattern: factory.domain, custom_domain: true }] } : {}),
    };
  }
  const flags = [...(rest.compatibility_flags ?? [])];
  if (!flags.includes("delete_all_deletes_alarm")) flags.push("delete_all_deletes_alarm");
  const { keep_vars: _k, dev: _d, account_id: _a, workers_dev: _w, routes: _r, ...celld } = rest;
  return {
    ...celld,
    name: factory.name,
    compatibility_flags: flags,
    no_bundle: true,
    d1_databases: [{ binding: "DB", database_name: factory.name, database_id: CELLD_DATABASE_ID, migrations_dir: "migrations" }],
    r2_buckets: [{ binding: "RELEASES", bucket_name: factory.name }],
    vars: { ...vars, ...(factory.url ? { PUBLIC_URL: factory.url } : {}) },
  };
}

/** --bucket for celld: s3://NAME[/PREFIX] (gs:// and az:// work with celld too). */
export function checkBucket(bucket) {
  if (!bucket) return "--target celld needs --bucket s3://NAME (the fleet bucket celld nodes run from).";
  if (!/^(s3|gs|az):\/\/[a-z0-9][a-z0-9.-]{1,62}(\/[\w.\/-]*)?$/.test(bucket)) return `${bucket} isn't a bucket URL: --bucket is s3://NAME[/PREFIX] (or gs:// or az://).`;
  return null;
}

export function checkTarget(target) {
  return TARGETS.includes(target) ? null : `--target is ${TARGETS.join(" or ")}, not ${target}.`;
}

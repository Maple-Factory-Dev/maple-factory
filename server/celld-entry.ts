// The Worker under celld (server/celld.jsonc): src/index.ts unchanged, plus D1 migrations applied on the
// first request in each isolate, since `celld dev` has no local migrations CLI. Cloudflare deploys use
// src/index.ts directly and `wrangler d1 migrations apply`.
import worker, { OrgHub, MachineHub, DocHub } from "./src/index.ts";
import type { Env } from "./src/env.ts";
import { applyMigrations } from "./src/migrate.ts";
import m0001 from "./migrations/0001_init.sql";
import m0002 from "./migrations/0002_ended_by.sql";
import m0003 from "./migrations/0003_settings.sql";
import m0004 from "./migrations/0004_admin_grants.sql";
import m0005 from "./migrations/0005_revocation.sql";
import m0006 from "./migrations/0006_member_github_tokens.sql";
import m0007 from "./migrations/0007_slack_links.sql";
import m0008 from "./migrations/0008_machine_capabilities.sql";

export { OrgHub, MachineHub, DocHub };

const FILES = {
  "0001_init.sql": m0001,
  "0002_ended_by.sql": m0002,
  "0003_settings.sql": m0003,
  "0004_admin_grants.sql": m0004,
  "0005_revocation.sql": m0005,
  "0006_member_github_tokens.sql": m0006,
  "0007_slack_links.sql": m0007,
  "0008_machine_capabilities.sql": m0008,
};

let migrated: Promise<unknown> | null = null;

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    // Once per isolate; a failure is retried on the next request rather than cached.
    migrated ??= applyMigrations(env.DB, FILES).then(
      (applied) => { if (applied.length) console.log(`applied D1 migrations: ${applied.join(", ")}`); },
      (e) => { migrated = null; throw e; },
    );
    await migrated;
    return (worker as ExportedHandler<Env>).fetch!(request as never, env, ctx);
  },
};

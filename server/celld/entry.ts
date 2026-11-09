// THROWAWAY SPIKE ENTRY (MF-372). The real Worker from ../src/index.ts, unchanged, plus /__celld/*
// probe routes the spike needs because `celld d1 migrations apply` only reaches a fleet bucket, not
// `celld dev`'s local store.
import worker, { OrgHub, MachineHub, DocHub } from "../src/index.ts";
import { appJwt } from "../src/github.ts";
import * as Sentry from "@sentry/cloudflare";
import m1 from "../migrations/0001_init.sql";
import m2 from "../migrations/0002_ended_by.sql";
import m3 from "../migrations/0003_settings.sql";
import m4 from "../migrations/0004_admin_grants.sql";
import m5 from "../migrations/0005_revocation.sql";
import m6 from "../migrations/0006_member_github_tokens.sql";
import m7 from "../migrations/0007_slack_links.sql";
import m8 from "../migrations/0008_machine_capabilities.sql";

export { OrgHub, MachineHub, DocHub };
import { DurableObject } from "cloudflare:workers";

/** Spike only: an alarm that records when it fired, and whether deleteAll() takes the alarm with it. */
export class AlarmProbe extends DurableObject {
  async fetch(request: Request): Promise<Response> {
    const op = new URL(request.url).pathname;
    if (op === "/set") { await this.ctx.storage.setAlarm(Date.now() + 1000); return Response.json({ alarm: await this.ctx.storage.getAlarm() }); }
    if (op === "/forget") { await this.ctx.storage.setAlarm(Date.now() + 60_000); await this.ctx.storage.deleteAll(); return Response.json({ alarmAfterDeleteAll: await this.ctx.storage.getAlarm() }); }
    return Response.json({ fired: (await this.ctx.storage.get("fired")) ?? null, alarm: await this.ctx.storage.getAlarm() });
  }
  async alarm() { await this.ctx.storage.put("fired", Date.now()); }
}

const MIGRATIONS: [string, string][] = [
  ["0001_init.sql", m1], ["0002_ended_by.sql", m2], ["0003_settings.sql", m3], ["0004_admin_grants.sql", m4],
  ["0005_revocation.sql", m5], ["0006_member_github_tokens.sql", m6], ["0007_slack_links.sql", m7], ["0008_machine_capabilities.sql", m8],
];

// Strip -- comments and split on ; so each statement goes through batch() (exec() is per-line on CF).
const statements = (sql: string) => sql.replace(/--[^\n]*/g, "").split(";").map((s) => s.trim()).filter(Boolean);

export default {
  async fetch(request: Request, env: any, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/__celld/migrate" && request.method === "POST") {
      await env.DB.prepare("CREATE TABLE IF NOT EXISTS d1_migrations (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE, applied_at TEXT DEFAULT CURRENT_TIMESTAMP)").run();
      const done = new Set(((await env.DB.prepare("SELECT name FROM d1_migrations").all()).results as { name: string }[]).map((r) => r.name));
      const applied: string[] = [];
      for (const [name, sql] of MIGRATIONS) {
        if (done.has(name)) continue;
        await env.DB.batch([...statements(sql).map((s) => env.DB.prepare(s)), env.DB.prepare("INSERT INTO d1_migrations (name) VALUES (?)").bind(name)]);
        applied.push(name);
      }
      const tables = (await env.DB.prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name").all()).results.map((r: any) => r.name);
      return Response.json({ applied, already: [...done], tables });
    }
    if (url.pathname === "/__celld/jwt" && request.method === "POST") {
      const { pem } = (await request.json()) as { pem: string };
      try {
        return Response.json({ jwt: await appJwt({ issuer: "12345", privateKey: pem }) });
      } catch (e) {
        return Response.json({ error: String((e as Error)?.stack ?? e) }, { status: 500 });
      }
    }
    const ap = /^\/__celld\/alarm\/(\w+)\/(set|forget|state)$/.exec(url.pathname);
    if (ap) return env.ALARM_PROBE.get(env.ALARM_PROBE.idFromName(ap[1])).fetch(`https://probe/${ap[2]}`);
    if (url.pathname === "/__celld/fetch") {
      try {
        const r = await fetch(url.searchParams.get("u")!, { method: "POST", body: "probe" });
        return Response.json({ status: r.status });
      } catch (e) {
        return Response.json({ error: String(e) }, { status: 502 });
      }
    }
    if (url.pathname === "/__celld/sentry") {
      const logs: string[] = [];
      const h = Sentry.withSentry(() => ({ dsn: env.SENTRY_DSN, debug: true, beforeSend: (e: any) => (logs.push("beforeSend " + e.exception?.values?.[0]?.value), e) }), {
        async fetch() {
          const id = Sentry.captureException(new Error("celld spike probe"));
          const flushed = await Sentry.flush(3000);
          return Response.json({ id, flushed, client: !!Sentry.getClient(), logs });
        },
      } as any);
      return (h as any).fetch(request, env, ctx);
    }
    if (url.pathname === "/__celld/als") {
      const { AsyncLocalStorage } = await import("node:async_hooks");
      const als = new AsyncLocalStorage<number>();
      const seen = await als.run(42, async () => { await new Promise((r) => setTimeout(r, 5)); return als.getStore(); });
      return Response.json({ asyncLocalStorage: typeof AsyncLocalStorage, storeAfterAwait: seen, flags: (globalThis as any).Cloudflare?.compatibilityFlags ?? null });
    }
    return (worker as any).fetch(request, env, ctx);
  },
};

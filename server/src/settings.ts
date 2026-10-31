// Settings kept in D1, for what a Worker can't set on itself: a factory deployed with the Deploy to
// Cloudflare button has no installer to run `wrangler secret put`, so /setup stores the GitHub App it
// creates here. They're filled into `env` where a secret or var of the same name is missing, so the
// rest of the server reads `env.GITHUB_CLIENT_ID` and friends whichever way they were set.
//
// `env` is one object per isolate, shared by the Worker and each Durable Object living there, so it's
// filled in place: call applySettings at the top of every entry point (fetch, alarm, socket messages).

import type { Env } from "./env.ts";

/** The names /setup may store. Anything else in the table is ignored. */
export const SETTING_KEYS = [
  "GITHUB_CLIENT_ID",
  "GITHUB_CLIENT_SECRET",
  "GITHUB_APP_ID",
  "GITHUB_APP_SLUG",
  "GITHUB_APP_PRIVATE_KEY",
  "GITHUB_WEBHOOK_SECRET",
  "GITHUB_OWNER_TYPE",
  "PUBLIC_URL",
  "SESSION_SECRET",
  // "off" from Settings › General (error-reports.ts); deleting the row turns reports back on.
  "SENTRY_DSN",
  // Written once (secrets.ts), never by saveSettings: a new one would make every stored secret unreadable.
  "SECRETS_KEY",
] as const;
export type SettingKey = (typeof SETTING_KEYS)[number];

const REFRESH_MS = 30_000;
/** Per env object: which keys came from D1 (so a refresh may replace them) and when it was read. */
const filled = new WeakMap<Env, { keys: Set<string>; at: number }>();

export async function applySettings(env: Env, force = false): Promise<void> {
  const state = filled.get(env) ?? { keys: new Set<string>(), at: 0 };
  if (!force && Date.now() - state.at < REFRESH_MS) return;
  let rows: Array<{ key: string; value: string }>;
  try {
    rows = (await env.DB.prepare("SELECT key, value FROM settings").all<{ key: string; value: string }>()).results;
  } catch (e) {
    // Before migration 0003 there's no table; secrets alone still work.
    console.error("settings: couldn't read", e);
    return;
  }
  const vars = env as unknown as Record<string, unknown>;
  for (const { key, value } of rows) {
    if (!(SETTING_KEYS as readonly string[]).includes(key)) continue;
    if (vars[key] && !state.keys.has(key)) continue; // a real secret or var
    vars[key] = value;
    state.keys.add(key);
  }
  // A row deleted since: take back what it filled in.
  for (const key of state.keys) {
    if (rows.some((row) => row.key === key)) continue;
    delete vars[key];
    state.keys.delete(key);
  }
  state.at = Date.now();
  filled.set(env, state);
}

/** Whether env[key] is a real secret or var, which a stored setting can't replace. */
export function setInWorker(env: Env, key: SettingKey): boolean {
  return Boolean((env as unknown as Record<string, unknown>)[key]) && !filled.get(env)?.keys.has(key);
}

export async function deleteSetting(env: Env, key: SettingKey): Promise<void> {
  await env.DB.prepare("DELETE FROM settings WHERE key = ?").bind(key).run();
  await applySettings(env, true);
}

export async function saveSettings(env: Env, values: Partial<Record<SettingKey, string>>): Promise<void> {
  const now = Date.now();
  await env.DB.batch(Object.entries(values).map(([key, value]) =>
    env.DB.prepare("INSERT INTO settings (key, value, updated_at) VALUES (?, ?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at")
      .bind(key, value!, now)));
  await applySettings(env, true);
}

// Whether this factory sends error reports to Sentry: Settings › General's toggle. Off stores
// SENTRY_DSN=off in the settings table (settings.ts), which turns off the server's reports and, through
// /healthz's `sentry`, the web app's. A SENTRY_DSN set as a Worker var or secret wins, and locks it.

import type { Env } from "./env.ts";
import type { Member } from "./wire.ts";
import { deleteSetting, saveSettings, setInWorker } from "./settings.ts";
import { sentryDsn } from "./sentry.ts";
import { audit, text } from "./util.ts";

function state(env: Env, builtIn: string) {
  return { on: sentryDsn(env, builtIn) !== null, locked: setInWorker(env, "SENTRY_DSN") };
}

/** GET /api/error-reports: { on, locked }. */
export function get(env: Env, builtIn: string): Response {
  return Response.json(state(env, builtIn));
}

/** PUT /api/error-reports: admins only; the body is `{ on }`. */
export async function set(request: Request, env: Env, me: Member, builtIn: string): Promise<Response> {
  if (me.role !== "admin") return text("Only admins can change the factory's error reports.", 403);
  const body = (await request.json().catch(() => null)) as { on?: unknown } | null;
  if (typeof body?.on !== "boolean") return text("Send whether reports are on as { on }.", 400);
  if (setInWorker(env, "SENTRY_DSN")) return text("The Worker's SENTRY_DSN sets this; change it there.", 409);
  if (body.on) await deleteSetting(env, "SENTRY_DSN");
  else await saveSettings(env, { SENTRY_DSN: "off" });
  await audit(env, me.login, body.on ? "error_reports.on" : "error_reports.off");
  return Response.json(state(env, builtIn));
}

// Error reports to Sentry. Every factory reports to Maple Factory's own project (web/sentry.json, which
// the web app, the runner and the Mac app read too) unless SENTRY_DSN says otherwise: "off", or a
// factory's own DSN. Events carry the server's version and the org, and nothing a person typed or sent:
// no cookies, Authorization headers, request bodies or query strings (README.md, "Error reports").

import type { CloudflareOptions, ErrorEvent } from "@sentry/cloudflare";
import type { Env } from "./env.ts";

/** The DSN this factory reports to (builtIn: web/sentry.json's), or null when reports are off. */
export function sentryDsn(env: Pick<Env, "SENTRY_DSN">, builtIn: string): string | null {
  const set = env.SENTRY_DSN?.trim();
  if (set) return set.toLowerCase() === "off" ? null : set;
  return builtIn || null;
}

const SECRET_HEADERS = /^(cookie|set-cookie|authorization|proxy-authorization|x-hub-signature(-256)?|x-slack-signature|linear-signature)$/i;

/** An event with what a person sent taken out: cookies, credentials, bodies and query strings. */
export function scrub(event: ErrorEvent): ErrorEvent {
  const request = event.request;
  if (request) {
    delete request.cookies;
    delete request.data;
    delete request.query_string;
    if (request.url) request.url = request.url.split(/[?#]/)[0];
    if (request.headers) {
      for (const name of Object.keys(request.headers)) if (SECRET_HEADERS.test(name)) delete request.headers[name];
    }
  }
  for (const crumb of event.breadcrumbs ?? []) {
    if (typeof crumb.data?.url === "string") crumb.data.url = crumb.data.url.split(/[?#]/)[0];
  }
  delete event.user;
  // Or Sentry fills in the user from the connection's IP address.
  if (event.sdk) event.sdk.settings = { ...event.sdk.settings, infer_ip: "never" };
  else event.sdk = { name: "sentry.javascript.cloudflare", version: "", settings: { infer_ip: "never" } };
  return event;
}

/** withSentry's and the Durable Objects' options; undefined (no SDK) when reports are off. */
export function sentryOptions(env: Env, builtIn: string, version: string): CloudflareOptions | undefined {
  const dsn = sentryDsn(env, builtIn);
  if (!dsn) return undefined;
  return {
    dsn,
    release: `maple-server@${version}`,
    environment: env.DEV_LOGIN ? "development" : "production",
    // SDK v11's sendDefaultPii: false, and then some. scrub() still checks every event on its way out.
    dataCollection: {
      userInfo: false, cookies: false, httpHeaders: { request: { deny: ["cookie", "authorization"] }, response: false },
      httpBodies: [], urlQueryParams: false, databaseQueryData: false, genAI: { inputs: false, outputs: false },
    },
    tracesSampleRate: 0,
    initialScope: { tags: { org: env.GITHUB_ORG || "unset" } },
    // The SDK may have started before applySettings filled in a stored SENTRY_DSN=off; check again here.
    beforeSend: (event) => (sentryDsn(env, builtIn) ? scrub(event) : null),
  };
}

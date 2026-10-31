// Error reports: which DSN a factory reports to, and what never leaves it (src/sentry.ts).
import { test } from "node:test";
import assert from "node:assert/strict";
import { scrub, sentryDsn, sentryOptions } from "../src/sentry.ts";
import type { Env } from "../src/env.ts";

const BUILT_IN = "https://public@o1.ingest.us.sentry.io/2";

test("with SENTRY_DSN unset, the built-in DSN", () => {
  assert.equal(sentryDsn({}, BUILT_IN), BUILT_IN);
  assert.equal(sentryDsn({ SENTRY_DSN: "" }, BUILT_IN), BUILT_IN);
  assert.equal(sentryDsn({ SENTRY_DSN: "  " }, BUILT_IN), BUILT_IN);
});

test("SENTRY_DSN set to a factory's own DSN wins", () => {
  assert.equal(sentryDsn({ SENTRY_DSN: "https://mine@o9.ingest.sentry.io/9" }, BUILT_IN), "https://mine@o9.ingest.sentry.io/9");
});

test("SENTRY_DSN=off turns reports off, and so does a build without a DSN", () => {
  assert.equal(sentryDsn({ SENTRY_DSN: "off" }, BUILT_IN), null);
  assert.equal(sentryDsn({ SENTRY_DSN: "OFF" }, BUILT_IN), null);
  assert.equal(sentryDsn({}, ""), null);
  assert.equal(sentryOptions({ SENTRY_DSN: "off", GITHUB_ORG: "acme" } as Env, BUILT_IN, "1.2.3"), undefined);
});

test("options carry the release and org, and collect nothing personal", () => {
  const options = sentryOptions({ GITHUB_ORG: "acme" } as Env, BUILT_IN, "1.2.3")!;
  assert.equal(options.dsn, BUILT_IN);
  assert.equal(options.release, "maple-server@1.2.3");
  assert.deepEqual(options.initialScope, { tags: { org: "acme" } });
  assert.equal(options.dataCollection?.userInfo, false);
  assert.equal(options.dataCollection?.cookies, false);
  assert.deepEqual(options.dataCollection?.httpBodies, []);
  assert.equal(options.dataCollection?.urlQueryParams, false);
});

test("beforeSend strips cookies, credentials, bodies and query strings", () => {
  const options = sentryOptions({ GITHUB_ORG: "acme" } as Env, BUILT_IN, "1.2.3")!;
  const event = {
    request: {
      url: "https://factory.example/api/tasks?token=abc#frag",
      method: "POST",
      query_string: "token=abc",
      cookies: { maple_session: "s3cret" },
      data: '{"secret":"x"}',
      headers: { Cookie: "maple_session=s3cret", authorization: "Bearer mfr_x", "X-Hub-Signature-256": "sha256=…", "content-type": "application/json" },
    },
    user: { id: "1", ip_address: "1.2.3.4" },
    breadcrumbs: [{ category: "fetch", data: { url: "https://api.github.com/x?access_token=y", method: "GET" } }],
  };
  const out = (options.beforeSend as (e: unknown, h: unknown) => typeof event)(event, {});
  assert.equal(out.request.url, "https://factory.example/api/tasks");
  assert.equal(out.request.method, "POST");
  assert.equal("query_string" in out.request, false);
  assert.equal("cookies" in out.request, false);
  assert.equal("data" in out.request, false);
  assert.deepEqual(out.request.headers, { "content-type": "application/json" });
  assert.equal("user" in out, false);
  assert.equal(out.breadcrumbs[0].data.url, "https://api.github.com/x");
});

test("an event without a request passes through", () => {
  const event = { message: "boom" };
  assert.deepEqual(scrub(event), { message: "boom" });
});

// Error reports from the web app to Maple Factory's Sentry project (/sentry.json), tagged with the
// server's version and org. Off when the server's are (SENTRY_DSN=off: /healthz says sentry: false).
// Nothing a person typed goes: no user, no request bodies or query strings, no console messages.

const SDK = "https://browser.sentry-cdn.com/11.10.0/bundle.min.js";
const SDK_INTEGRITY = "sha384-O/8YQaGGVy/n9jIUzcOiaiJVm4t5+JMNiK/zOa0fWvlSld+FquXemEcwJxQ3x/Lr";

const bare = (url) => (typeof url === "string" ? url.split("?")[0] : url);

/** An event without what a person sent or typed. */
export function scrub(event) {
  delete event.user;
  if (event.request) {
    delete event.request.cookies;
    delete event.request.data;
    delete event.request.query_string;
    delete event.request.headers;
    event.request.url = bare(event.request.url);
  }
  event.breadcrumbs = (event.breadcrumbs ?? [])
    .filter((b) => b.category !== "console" && !b.category?.startsWith("ui."))
    .map((b) => (b.data?.url || b.data?.to || b.data?.from ? { ...b, data: { ...b.data, url: bare(b.data.url), to: bare(b.data.to), from: bare(b.data.from) } } : b));
  return event;
}

async function start() {
  const [health, config] = await Promise.all([
    fetch("/healthz").then((r) => r.json()),
    fetch("/sentry.json").then((r) => r.json()),
  ]);
  const dsn = config.projects?.web?.dsn;
  if (!health.sentry || !dsn) return;
  await new Promise((resolve, reject) => {
    const script = Object.assign(document.createElement("script"), { src: SDK, integrity: SDK_INTEGRITY, crossOrigin: "anonymous", onload: resolve, onerror: reject });
    document.head.append(script);
  });
  window.Sentry.init({
    dsn,
    release: `maple-server@${health.version}`,
    environment: health.signIn === "dev" ? "development" : "production",
    dataCollection: { userInfo: false, cookies: false, httpHeaders: false, httpBodies: [], urlQueryParams: false },
    tracesSampleRate: 0,
    initialScope: { tags: { org: health.org || "unset", component: "web" } },
    beforeSend: scrub,
  });
}

if (typeof document !== "undefined") start().catch(() => {});

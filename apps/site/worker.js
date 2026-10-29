// maplefactory.dev: the static site (Workers static assets), plus the release feed:
//
//   /releases/*  the signed release feed, from the maplefactory-releases bucket. Every org's factory
//                falls back to it (server/src/releases.ts), and `maple install` gets the server from it.
//                Layout: <product>/latest.json (stable) and beta.json, each with a .sig, and the
//                versioned files they point at, which never change once uploaded.
//
//   /download/mac  the Mac app's newest stable DMG: a redirect to it, from the appcast every install checks
//                  (apps/mac/scripts/release.mjs publishes both), so the link never needs changing.
//
// /deploy is a page (deploy.html): R2 has to be on in the account before the Deploy to Cloudflare
// button can provision the factory's bucket, so it asks for that first.

const SAFE_PATH = /^(?!.*\.\.)[\w.\-/]+$/;
const APPCAST = "https://updates.maplefactory.dev/appcast.xml";

/** The first item the appcast lists with no <sparkle:channel>, which is the newest stable release. */
async function latestMac() {
  const res = await fetch(APPCAST, { cf: { cacheTtl: 300 } });
  if (!res.ok) return null;
  const stable = (await res.text()).split("<item>").slice(1).find((item) => !item.includes("<sparkle:channel>"));
  return stable?.match(/<enclosure url="([^"]+)"/)?.[1]?.replace(/&amp;/g, "&") ?? null;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/download/mac") {
      const dmg = await latestMac();
      if (!dmg) return new Response("The Mac app's download isn't available right now; try again in a minute.", { status: 503 });
      return new Response(null, { status: 302, headers: { location: dmg, "cache-control": "public, max-age=300" } });
    }
    if (url.pathname.startsWith("/releases/")) {
      if (request.method !== "GET" && request.method !== "HEAD") return new Response("Method not allowed.", { status: 405 });
      const path = url.pathname.slice("/releases/".length);
      const object = SAFE_PATH.test(path) ? await env.FEED.get(path) : null;
      if (!object) return new Response("Not found.", { status: 404 });
      const manifest = /\.json(\.sig)?$/.test(path);
      return new Response(request.method === "HEAD" ? null : object.body, {
        headers: {
          "content-type": object.httpMetadata?.contentType ?? "application/octet-stream",
          "content-length": String(object.size),
          etag: object.httpEtag,
          "cache-control": manifest ? "public, max-age=300" : "public, max-age=31536000, immutable",
        },
      });
    }
    return env.ASSETS.fetch(request);
  },
};

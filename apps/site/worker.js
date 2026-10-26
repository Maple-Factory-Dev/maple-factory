// maplefactory.dev: the static site (Workers static assets), plus the release feed:
//
//   /releases/*  the signed release feed, from the maplefactory-releases bucket. Every org's factory
//                falls back to it (server/src/releases.ts), and `maple install` gets the server from it.
//                Layout: <product>/latest.json (stable) and beta.json, each with a .sig, and the
//                versioned files they point at, which never change once uploaded.
//
// /deploy is a page (deploy.html): R2 has to be on in the account before the Deploy to Cloudflare
// button can provision the factory's bucket, so it asks for that first.

const SAFE_PATH = /^(?!.*\.\.)[\w.\-/]+$/;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
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

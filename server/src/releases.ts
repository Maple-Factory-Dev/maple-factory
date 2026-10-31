// /releases/: where `/install.sh` and every runner's self-update get maple-runner. A factory serves
// the official builds from maplefactory.dev's signed feed, on its RELEASE_CHANNEL (stable, or beta for
// releases before they're stable). An org that builds its own runners (with its own release key)
// uploads them to the factory's bucket (RELEASES): anything there wins over the feed.
// RELEASE_FEED points the fallback elsewhere, or "off" serves only the bucket.
//
// Runners trust a manifest only when it's signed with the key built into them, so passing the feed's
// bytes through here gives the factory no way to push a runner of its own.

import type { Env } from "./env.ts";

export const DEFAULT_FEED = "https://maplefactory.dev/releases";

/** Paths under the feed: lowercase words, dots and slashes, never `..`. The bucket also keeps attachments
 *  and the icon, which only their own routes serve (members only, sandboxed), so those are never releases. */
const SAFE_PATH = /^(?!.*\.\.)(?!(attachments|icon)\/)[\w.\-/]+$/;

/** The channel's manifest in the feed: stable is `latest.json`, beta is `beta.json` (same signature scheme). */
function feedPath(path: string, channel: string | undefined): string {
  if (channel !== "beta") return path;
  const m = /^([\w-]+)\/latest\.json(\.sig)?$/.exec(path);
  return m ? `${m[1]}/beta.json${m[2] ?? ""}` : path;
}

export async function release(env: Env, path: string): Promise<Response | null> {
  if (!SAFE_PATH.test(path)) return null;
  const object = await env.RELEASES.get(path);
  if (object) {
    return new Response(object.body, {
      headers: { "content-type": object.httpMetadata?.contentType ?? "application/octet-stream", etag: object.httpEtag, "x-content-type-options": "nosniff" },
    });
  }
  const feed = (env.RELEASE_FEED || DEFAULT_FEED).replace(/\/+$/, "");
  if (feed === "off") return null;
  // Manifests change with each release; a version's binaries never do.
  const manifest = /\.json(\.sig)?$/.test(path);
  const res = await fetch(`${feed}/${feedPath(path, env.RELEASE_CHANNEL)}`, {
    cf: { cacheEverything: true, cacheTtl: manifest ? 300 : 86_400 },
  } as RequestInit);
  if (!res.ok) return null;
  const headers = new Headers({ "content-type": res.headers.get("content-type") ?? "application/octet-stream", "x-content-type-options": "nosniff" });
  const etag = res.headers.get("etag");
  if (etag) headers.set("etag", etag);
  return new Response(res.body, { headers });
}

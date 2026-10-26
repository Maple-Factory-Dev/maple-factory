// This factory's maple-server version, and whether the release feed has a newer one: admins see a
// notice (the home page, /setup, the apps' welcome) saying what's out and how this factory gets it.
// A factory from the Deploy to Cloudflare button updates from its own copy of the repo, where the
// Maple Factory update workflow opens a pull request; one from `maple install` (MAPLE_DEPLOY=installer)
// updates with `maple update`.

import pkg from "../package.json";
import type { Env } from "./env.ts";
import { release } from "./releases.ts";
import type { ServerUpdate } from "./wire.ts";

export const SERVER_VERSION: string = pkg.version;

/** a < b, by their numbers ("0.2.0" < "0.10.1"); a pre-release suffix is ignored. */
export function older(a: string, b: string): boolean {
  const parts = (v: string) => v.split("-")[0].split(".").map((n) => Number(n) || 0);
  const [x, y] = [parts(a), parts(b)];
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    if ((x[i] ?? 0) !== (y[i] ?? 0)) return (x[i] ?? 0) < (y[i] ?? 0);
  }
  return false;
}

let latest: { version: string | null; at: number } | null = null;

/** The newest maple-server on this factory's channel, read at most every ten minutes. */
async function serverLatest(env: Env): Promise<string | null> {
  if (latest && Date.now() - latest.at < 600_000) return latest.version;
  let version: string | null = null;
  try {
    const res = await release(env, "maple-server/latest.json");
    version = res ? ((await res.json()) as { version?: string }).version ?? null : null;
  } catch {}
  latest = { version, at: Date.now() };
  return version;
}

/** A newer maple-server than this one, and how to get it; null when this is the latest. */
export async function serverUpdate(env: Env): Promise<ServerUpdate | null> {
  const version = await serverLatest(env);
  if (!version || !older(SERVER_VERSION, version)) return null;
  const how = env.MAPLE_DEPLOY === "installer"
    ? "Run `maple update` on the machine it was installed from."
    : "Merge the update pull request in this factory's repo (the Maple Factory update workflow opens one; run it from the repo's Actions tab to check now).";
  return { version, how };
}

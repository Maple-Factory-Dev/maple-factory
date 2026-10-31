import type { Presence } from "./wire.ts";

/** One open app connection, as far as presence cares. */
export interface Connection {
  login: string;
  /** The task this connection's app is showing. */
  viewing?: string | null;
  since?: number;
  /** The iPhone or Android app (it sent `x-maple-client: mobile`). */
  mobile?: boolean;
}

/** The `x-maple-client` header's value says whether a connection is from a phone; anything else is desktop. */
export const isMobileClient = (header: string | null) => header?.trim().toLowerCase() === "mobile";

/**
 * One entry per person: the most recent of their connections' views, and `mobile: true` only when every
 * connection they have open is a phone (absent otherwise, so old clients see what they always did).
 */
export function aggregatePresence(connections: Iterable<Connection>): Presence[] {
  const people = new Map<string, Presence>();
  const desktop = new Set<string>();
  for (const c of connections) {
    if (!c.mobile) desktop.add(c.login);
    const seen = people.get(c.login);
    const since = c.since ?? 0;
    if (!seen || (c.viewing && (!seen.viewing || since > seen.since))) people.set(c.login, { login: c.login, viewing: c.viewing ?? null, since });
  }
  return [...people.values()].map((p) => (desktop.has(p.login) ? p : { ...p, mobile: true }));
}

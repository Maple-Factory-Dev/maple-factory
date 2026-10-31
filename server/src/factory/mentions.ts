// Who a comment @mentions: each `@login` that's an org member, matched case-insensitively and
// returned as the member's own login, once each, never the author. `a@b.com` isn't a mention.

/** A GitHub login after an `@` that doesn't follow a word character, dot or another `@`. */
const MENTION = /(?<![\w.@/-])@([A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38})(?![\w@-]|\.\w)/g;

export function mentionsIn(text: string, members: { login: string }[], author?: string): string[] {
  const byLower = new Map(members.map((m) => [m.login.toLowerCase(), m.login]));
  const self = author?.toLowerCase();
  const found: string[] = [];
  for (const [, name] of text.matchAll(MENTION)) {
    const login = byLower.get(name.toLowerCase());
    if (login && login.toLowerCase() !== self && !found.includes(login)) found.push(login);
  }
  return found;
}

/** The factory's agents a comment can talk to: `@planner`, `@builder`, `@reviewer`, matched
 *  case-insensitively, once each. Kept apart from members: an org member who happens to be
 *  called `builder` is still mentioned by `mentionsIn`; this only says which agents are addressed. */
export const AGENT_ROLES = ["planner", "builder", "reviewer"] as const;
export type AgentRole = (typeof AGENT_ROLES)[number];

export function agentsIn(text: string): AgentRole[] {
  const found: AgentRole[] = [];
  for (const [, name] of text.matchAll(MENTION)) {
    const role = AGENT_ROLES.find((r) => r === name.toLowerCase());
    if (role && !found.includes(role)) found.push(role);
  }
  return found;
}

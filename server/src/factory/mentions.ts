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

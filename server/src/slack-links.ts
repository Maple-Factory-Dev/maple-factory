// A Slack account linked to a factory member, so @Maple knows who's asking. `@Maple link` mints a one-time code
// (only its hash is kept, for 10 minutes) and sends it to that person alone as a /link/slack URL; opening it while
// signed in and confirming pairs their Slack user with their login (slack_links). Slack's signed event is the only
// source of the Slack identity, and the session the only source of the login.

import type { Env } from "./env.ts";

/** How long a link code works. */
export const LINK_MS = 10 * 60_000;

export interface SlackLink { user: string; team: string; linkedAt: number }

const tidy = (q: string) => q.replace(/[*_`~]/g, "").replace(/[’‘]/g, "'").replace(/[\s.!?:]+$/, "").replace(/\s+/g, " ").trim().toLowerCase();

/** `@Maple link` (or "link me", "link my account", "connect"). */
export function wantsLink(question: string): boolean {
  return /^(link|connect)( (me|my account|my slack|my slack account|account))?$/.test(tidy(question));
}

/** `@Maple unlink` (or "unlink me", "disconnect"). */
export function wantsUnlink(question: string): boolean {
  return /^(unlink|disconnect)( (me|my account|my slack|my slack account|account))?$/.test(tidy(question));
}

/** `@Maple mine` (or "my tasks", "what's waiting on me", "what's on my plate"). */
export function wantsMine(question: string): boolean {
  const said = tidy(question);
  if (/^(mine|my tasks|my work|my stuff|me)$/.test(said)) return true;
  if (/^(show( me)?|list) (my|mine)( tasks| work)?$/.test(said)) return true;
  return /^(what'?s|what is|whats|anything) (waiting (on|for) me|on my plate|assigned to me|mine)( (here|now|right now|today))?$/.test(said);
}

async function sha256(s: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** A fresh code for this Slack account, good for LINK_MS; only its hash is stored. */
export async function startLink(env: Env, team: string, user: string, now = Date.now()): Promise<string> {
  const bytes = crypto.getRandomValues(new Uint8Array(24));
  const code = btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  await env.DB.prepare("DELETE FROM slack_link_codes WHERE expires_at <= ?").bind(now).run();
  await env.DB.prepare("INSERT INTO slack_link_codes (hash, slack_user, slack_team, expires_at) VALUES (?, ?, ?, ?)").bind(await sha256(code), user, team, now + LINK_MS).run();
  return code;
}

/** The Slack account a code is for, if it's known and not expired; doesn't use it up (the confirm page). */
export async function peek(env: Env, code: string, now = Date.now()): Promise<{ user: string; team: string } | null> {
  if (!code) return null;
  const row = await env.DB.prepare("SELECT slack_user, slack_team, expires_at FROM slack_link_codes WHERE hash = ?").bind(await sha256(code)).first<{ slack_user: string; slack_team: string; expires_at: number }>();
  return row && row.expires_at > now ? { user: row.slack_user, team: row.slack_team } : null;
}

/** Uses a code up for `login`: the pair replaces any earlier link of that login or of that Slack account. Null when
 *  the code is unknown, used or expired. */
export async function redeem(env: Env, code: string, login: string, now = Date.now()): Promise<SlackLink | null> {
  if (!code) return null;
  const hash = await sha256(code);
  const row = await env.DB.prepare("DELETE FROM slack_link_codes WHERE hash = ? RETURNING slack_user, slack_team, expires_at").bind(hash).first<{ slack_user: string; slack_team: string; expires_at: number }>();
  if (!row || row.expires_at <= now) return null;
  await env.DB.prepare("DELETE FROM slack_links WHERE login = ? OR (slack_team = ? AND slack_user = ?)").bind(login, row.slack_team, row.slack_user).run();
  await env.DB.prepare("INSERT INTO slack_links (login, slack_user, slack_team, linked_at) VALUES (?, ?, ?, ?)").bind(login, row.slack_user, row.slack_team, now).run();
  return { user: row.slack_user, team: row.slack_team, linkedAt: now };
}

/** The member a Slack account is linked to, if any. */
export async function loginFor(env: Env, team: string, user: string): Promise<string | null> {
  if (!user) return null;
  const row = await env.DB.prepare("SELECT login FROM slack_links WHERE slack_team = ? AND slack_user = ?").bind(team, user).first<{ login: string }>();
  return row?.login ?? null;
}

/** A member's link, if they have one. */
export async function linkOf(env: Env, login: string): Promise<SlackLink | null> {
  const row = await env.DB.prepare("SELECT slack_user, slack_team, linked_at FROM slack_links WHERE login = ?").bind(login).first<{ slack_user: string; slack_team: string; linked_at: number }>();
  return row ? { user: row.slack_user, team: row.slack_team, linkedAt: row.linked_at } : null;
}

/** Drops a link, by member or by Slack account; the login that was linked, if one was. */
export async function unlink(env: Env, by: { login: string } | { team: string; user: string }): Promise<string | null> {
  const row = "login" in by
    ? await env.DB.prepare("DELETE FROM slack_links WHERE login = ? RETURNING login").bind(by.login).first<{ login: string }>()
    : await env.DB.prepare("DELETE FROM slack_links WHERE slack_team = ? AND slack_user = ? RETURNING login").bind(by.team, by.user).first<{ login: string }>();
  return row?.login ?? null;
}

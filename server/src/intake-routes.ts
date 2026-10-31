// Requests coming in from the API (a member's app token, or the org's intake key). They land in
// OrgHub's intake (factory/intake.ts); Slack's come in through slack.ts.

import type { Env } from "./env.ts";
import type { Member, TicketLink } from "./wire.ts";
import { orgHub, sameText, text } from "./util.ts";

/** The org's intake key, as `Authorization: Bearer mfi_…`. */
export function intakeKey(request: Request, env: Env) {
  const bearer = /^Bearer (mfi_[\w-]+)$/.exec(request.headers.get("authorization") ?? "")?.[1];
  return Boolean(env.INTAKE_KEY && bearer && sameText(bearer, env.INTAKE_KEY));
}

/** Where an API request's replies may go: the factory POSTs to its replyUrl (trackers.ts `deliver`), so
 *  only to Slack's incoming webhooks and the hosts INTAKE_REPLY_HOSTS names, never anywhere a caller says. */
function replyAllowed(env: Env, replyUrl: string): boolean {
  let url: URL;
  try {
    url = new URL(replyUrl);
  } catch {
    return false;
  }
  const hosts = new Set(["hooks.slack.com", ...(env.INTAKE_REPLY_HOSTS ?? "").split(/[\s,]+/).filter(Boolean).map((h) => h.toLowerCase())]);
  return url.protocol === "https:" && !url.username && !url.password && hosts.has(url.hostname);
}

/**
 * POST /api/intake {title, text, requester?, source?, channel?, tickets?, replyUrl?}
 * POST /api/intake/:id/messages {author, text}: the requester's side answering in the thread.
 */
export async function intakeApi(request: Request, env: Env, path: string, me: Member | null): Promise<Response | null> {
  if (request.method !== "POST" || !path.startsWith("/api/intake")) return null;
  if (!me && !intakeKey(request, env)) return text("Sign in, or send the org's intake key.", 401);
  const body = (await request.json().catch(() => null)) as Record<string, unknown> | null;
  if (!body) return text("Expected JSON.", 400);
  const str = (k: string) => (typeof body[k] === "string" ? (body[k] as string).trim() : "");

  const reply = /^\/api\/intake\/(REQ-\d+)\/messages$/.exec(path);
  if (reply) {
    if (!str("text")) return text("Say something.", 400);
    return orgHub(env).fetch("https://org/intake/reply", {
      method: "POST",
      body: JSON.stringify({ id: reply[1], author: me?.login ?? (str("author") || "requester"), text: str("text") }),
    });
  }
  if (path !== "/api/intake") return text("Not found.", 404);
  if (!str("title")) return text("A request needs a title.", 400);
  const replyUrl = str("replyUrl");
  if (replyUrl && !replyAllowed(env, replyUrl)) return text("replyUrl must be https on hooks.slack.com or a host in INTAKE_REPLY_HOSTS.", 400);
  return orgHub(env).fetch("https://org/intake", {
    method: "POST",
    body: JSON.stringify({
      source: ["slack", "linear", "jira"].includes(str("source")) ? str("source") : "api",
      channel: str("channel") || null,
      requester: me?.login ?? (str("requester") || "someone"),
      title: str("title"),
      text: str("text"),
      tickets: Array.isArray(body.tickets) ? (body.tickets as TicketLink[]).slice(0, 20) : [],
      replyUrl: replyUrl || null,
    }),
  });
}

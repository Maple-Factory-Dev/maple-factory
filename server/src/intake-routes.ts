// Requests coming in from outside: the API (a member's app token, or the org's intake key) and
// Slack's slash command. Both land in OrgHub's intake (factory/intake.ts).

import type { Env } from "./env.ts";
import { integrationConfig, integrationEvent } from "./integrations/registry.ts";
import type { Member, TicketLink } from "./wire.ts";
import { orgHub, sameText, text } from "./util.ts";

const enc = new TextEncoder();

async function hmacHex(secret: string, message: string) {
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return [...new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(message)))].map((b) => b.toString(16).padStart(2, "0")).join("");
}

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

/**
 * POST /integrations/slack/command: `/maple <what you need>`. Verified with the app's signing
 * secret; the bot's replies go back through the command's response_url.
 */
export async function slackCommand(request: Request, env: Env): Promise<Response> {
  const slack = await integrationConfig(env, "slack");
  if (!slack) return text("Slack isn't set up for this factory.", 404);
  const raw = await request.text();
  const stamp = request.headers.get("x-slack-request-timestamp") ?? "";
  const signature = request.headers.get("x-slack-signature") ?? "";
  if (Math.abs(Date.now() / 1000 - Number(stamp)) > 300) return text("Stale request.", 401);
  if (!sameText(signature, `v0=${await hmacHex(slack.signingSecret, `v0:${stamp}:${raw}`)}`)) {
    await integrationEvent(env, "slack", "A slash command came with a bad signature: check the signing secret.");
    return text("Bad signature.", 401);
  }
  await integrationEvent(env, "slack");

  const form = new URLSearchParams(raw);
  const said = (form.get("text") ?? "").trim();
  if (!said) return Response.json({ response_type: "ephemeral", text: "Say what you need: `/maple the export button times out on big workspaces`" });
  const [first, ...rest] = said.split("\n");
  const title = first.length > 90 ? `${first.slice(0, 87)}…` : first;
  const res = await orgHub(env).fetch("https://org/intake", {
    method: "POST",
    body: JSON.stringify({
      source: "slack",
      channel: form.get("channel_name") ? `#${form.get("channel_name")}` : null,
      requester: form.get("user_name") ?? "someone",
      title,
      text: said,
      tickets: [],
      replyUrl: form.get("response_url"),
    }),
  });
  const created = (await res.json()) as { id: string };
  return Response.json({ response_type: "in_channel", text: `Got it: ${created.id} is in the factory's requests. I'll post here when someone picks it up.` });
}

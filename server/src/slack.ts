// Slack: the /maple slash command, and @Maple. Every request is checked against the app's signing
// secret. A mention's thread (its messages, who wrote them and its files) is read here with the bot
// token and handed to OrgHub, which has a runner's read-only agent answer it (factory/slack-asks.ts);
// buttons and the channel's goal picker come back through the actions URL.

import type { Env } from "./env.ts";
import { integrationConfig, integrationEvent } from "./integrations/registry.ts";
import { MAX_ATTACHMENT, storedName } from "./attachments.ts";
import { orgHub, readCapped, sameText, text } from "./util.ts";

const enc = new TextEncoder();
const API = "https://slack.com/api";

/** Files read from one thread, at most. */
const MAX_FILES = 10;
/** Thread messages handed to the agent, at most (the latest). */
const MAX_MESSAGES = 50;

async function hmacHex(secret: string, message: string) {
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return [...new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(message)))].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** The request's body when its signature and timestamp check out against the signing secret, else the refusal. */
async function verified(request: Request, env: Env, what: string): Promise<{ raw: string; slack: Record<string, string> } | Response> {
  const slack = await integrationConfig(env, "slack");
  if (!slack) return text("Slack isn't set up for this factory.", 404);
  const raw = await request.text();
  const stamp = request.headers.get("x-slack-request-timestamp") ?? "";
  const signature = request.headers.get("x-slack-signature") ?? "";
  if (!stamp || Math.abs(Date.now() / 1000 - Number(stamp)) > 300) return text("Stale request.", 401);
  if (!sameText(signature, `v0=${await hmacHex(slack.signingSecret, `v0:${stamp}:${raw}`)}`)) {
    await integrationEvent(env, "slack", `${what} came with a bad signature: check the signing secret.`);
    return text("Bad signature.", 401);
  }
  return { raw, slack };
}

/**
 * POST /integrations/slack/command: `/maple <what you need>`. Verified with the app's signing
 * secret. With a bot token the ask is posted in the channel and the request's replies go in that
 * message's thread; without one, or when the bot can't post there (not in the channel, a DM), they
 * go back through the command's response_url.
 */
export async function slackCommand(request: Request, env: Env): Promise<Response> {
  const checked = await verified(request, env, "A slash command");
  if (checked instanceof Response) return checked;
  await integrationEvent(env, "slack");

  const form = new URLSearchParams(checked.raw);
  const said = (form.get("text") ?? "").trim();
  if (!said) return Response.json({ response_type: "ephemeral", text: "Say what you need: `/maple the export button times out on big workspaces`" });
  const [first, ...rest] = said.split("\n");
  const title = first.length > 90 ? `${first.slice(0, 87)}…` : first;
  const requester = form.get("user_name") ?? "someone";
  const channel = form.get("channel_id") ?? "";
  const token = checked.slack.botToken;
  let root: string | null = null;
  if (token && channel) {
    root = await postMessage(token, channel, null, `*${requester}* asked: ${said}`).catch(async (e) => {
      await integrationEvent(env, "slack", `Couldn't post a /maple ask in its channel, so its replies go back through Slack's response URL: ${(e as Error).message}`);
      return null;
    });
  }
  const res = await orgHub(env).fetch("https://org/intake", {
    method: "POST",
    body: JSON.stringify({
      source: "slack",
      channel: form.get("channel_name") ? `#${form.get("channel_name")}` : null,
      requester,
      title,
      text: said,
      tickets: [],
      replyUrl: root ? threadAddress(channel, root, "command") : form.get("response_url"),
    }),
  });
  const created = (await res.json()) as { id: string };
  if (token && root) {
    await postMessage(token, channel, root, `Got it: ${created.id} is in the factory's requests. I'll post updates in this thread.`).catch((e) =>
      integrationEvent(env, "slack", `Couldn't post in a thread: ${(e as Error).message}`),
    );
    return new Response(null, { status: 200 });
  }
  return Response.json({ response_type: "in_channel", text: `Got it: ${created.id} is in the factory's requests. I'll post here when someone picks it up.` });
}

// ---- Events ----

interface SlackFile { id: string; name?: string; title?: string; mimetype?: string; size?: number; url_private_download?: string; url_private?: string }
interface SlackMessage { user?: string; bot_id?: string; username?: string; text?: string; ts: string; thread_ts?: string; files?: SlackFile[] }
interface SlackEvent extends SlackMessage { type: string; channel: string; subtype?: string }

/** A thread message as the agent reads it. */
export interface ThreadLine { author: string; text: string; at: number }
/** A file from the thread, kept as an attachment. */
export interface SlackAttachment { name: string; path: string; mime: string; size: number }

/** What OrgHub gets for a mention (`/slack/ask`). */
export interface SlackAsk {
  channel: string;
  threadTs: string;
  user: string;
  requester: string;
  question: string;
  thread: ThreadLine[];
  attachments: SlackAttachment[];
}

/** A Slack mention, `<@U123>`, out of the text. */
const unmention = (s: string) => s.replace(/<@[A-Z0-9]+(\|[^>]*)?>/g, "").replace(/\s+/g, " ").trim();

/**
 * POST /integrations/slack/events: Slack's Events API. Answers within Slack's 3 seconds and does the
 * rest after (`waitUntil`); a retry of an event already taken (same event_id) is dropped.
 */
export async function slackEvents(request: Request, env: Env, ctx: { waitUntil(p: Promise<unknown>): void }): Promise<Response> {
  const checked = await verified(request, env, "An event");
  if (checked instanceof Response) return checked;
  const body = JSON.parse(checked.raw) as { type: string; challenge?: string; event_id?: string; event?: SlackEvent; authorizations?: { user_id?: string }[] };
  if (body.type === "url_verification") return Response.json({ challenge: body.challenge ?? "" });
  await integrationEvent(env, "slack");
  if (body.type !== "event_callback" || !body.event) return new Response(null, { status: 200 });
  if (body.event_id) {
    const res = await orgHub(env).fetch("https://org/slack/seen", { method: "POST", body: JSON.stringify({ id: body.event_id }) });
    if (((await res.json()) as { seen: boolean }).seen) return new Response(null, { status: 200 });
  }
  const event = body.event;
  const bot = body.authorizations?.[0]?.user_id ?? null;
  if (event.type === "app_mention" && !event.bot_id && event.user !== bot) {
    ctx.waitUntil(mentioned(env, checked.slack, event).catch((e) => integrationEvent(env, "slack", `Couldn't answer a mention: ${(e as Error).message}`)));
  }
  if (event.type === "member_joined_channel" && bot && event.user === bot) {
    ctx.waitUntil(orgHub(env).fetch("https://org/slack/joined", { method: "POST", body: JSON.stringify({ channel: event.channel }) }));
  }
  return new Response(null, { status: 200 });
}

/** Whether a mention asks for the goal picker: `goals`, `goals?`, `*goals*`, `change goals` and the like, not a question that names goals in passing. */
export function wantsGoals(question: string): boolean {
  const said = question.replace(/[*_`~]/g, "").replace(/[\s.!?:]+$/, "").trim().toLowerCase();
  return /^((pick|change|set|which) )?goals?$/.test(said);
}

/** A mention: its thread and files read and handed to OrgHub, or `@Maple goals` bringing the picker back. */
async function mentioned(env: Env, slack: Record<string, string>, event: SlackEvent) {
  const token = slack.botToken;
  if (!token) return integrationEvent(env, "slack", "Someone mentioned @Maple, but there's no bot token to answer with: add it in Settings › Integrations.");
  const question = unmention(event.text ?? "");
  if (wantsGoals(question)) {
    const asked = { channel: event.channel, ...(event.thread_ts ? { threadTs: event.thread_ts } : {}) };
    await orgHub(env).fetch("https://org/slack/joined", { method: "POST", body: JSON.stringify(asked) });
    return;
  }
  const threadTs = event.thread_ts ?? event.ts;
  let messages: SlackMessage[] = [event];
  if (event.thread_ts) {
    const replies = await slackApi(token, "conversations.replies", { channel: event.channel, ts: threadTs, limit: 200 }).catch(() => null);
    if (Array.isArray(replies?.messages)) messages = (replies.messages as SlackMessage[]).slice(-MAX_MESSAGES);
  }
  const names = new Map<string, string>();
  const nameOf = async (m: SlackMessage) => {
    if (m.bot_id) return m.username ?? "Maple";
    if (!m.user) return "someone";
    if (!names.has(m.user)) names.set(m.user, await userName(token, m.user));
    return names.get(m.user)!;
  };
  const thread: ThreadLine[] = [];
  for (const m of messages) thread.push({ author: await nameOf(m), text: unmention(m.text ?? ""), at: Math.round(Number(m.ts) * 1000) });
  const files = messages.flatMap((m) => m.files ?? []).filter((f, i, all) => all.findIndex((x) => x.id === f.id) === i).slice(0, MAX_FILES);
  const attachments: SlackAttachment[] = [];
  for (const f of files) {
    const kept = await keepFile(env, token, f).catch(() => null);
    if (kept) attachments.push(kept);
  }
  const ask: SlackAsk = { channel: event.channel, threadTs, user: event.user ?? "", requester: await nameOf(event), question, thread, attachments };
  await orgHub(env).fetch("https://org/slack/ask", { method: "POST", body: JSON.stringify(ask) });
}

/** A file from the thread, read with the bot token (up to MAX_ATTACHMENT) into the bucket as an attachment. */
export async function keepFile(env: Env, token: string, file: SlackFile): Promise<SlackAttachment | null> {
  const url = file.url_private_download ?? file.url_private;
  const name = storedName(file.name ?? file.title ?? "");
  if (!url || !name || (file.size ?? 0) > MAX_ATTACHMENT || !/^https:\/\/([\w-]+\.)*slack\.com\//.test(url)) return null;
  const res = await fetch(url, { headers: { authorization: `Bearer ${token}` } });
  if (!res.ok) return null;
  const body = await readCapped(res as unknown as Request, MAX_ATTACHMENT);
  if (!body?.byteLength) return null;
  const mime = (file.mimetype || res.headers.get("content-type") || "application/octet-stream").split(";")[0].trim().toLowerCase();
  const id = crypto.randomUUID();
  await env.RELEASES.put(`attachments/${id}/${name}`, body, { httpMetadata: { contentType: mime }, customMetadata: { by: "slack", file: file.id } });
  return { name, path: `/attachments/${id}/${name}`, mime, size: body.byteLength };
}

// ---- Actions ----

/** What OrgHub gets for a click (`/slack/action`). */
export interface SlackAction {
  action: string;
  value: string | null;
  selected: string[];
  user: { id: string; name: string };
  channel: { id: string; name: string | null };
  messageTs: string | null;
}

/** POST /integrations/slack/actions: a button or menu in one of @Maple's messages (Slack's block_actions). */
export async function slackActions(request: Request, env: Env, ctx: { waitUntil(p: Promise<unknown>): void }): Promise<Response> {
  const checked = await verified(request, env, "A button click");
  if (checked instanceof Response) return checked;
  await integrationEvent(env, "slack");
  const payload = JSON.parse(new URLSearchParams(checked.raw).get("payload") ?? "null") as {
    type?: string;
    user?: { id: string; name?: string; username?: string };
    channel?: { id: string; name?: string };
    message?: { ts: string };
    container?: { message_ts?: string };
    actions?: { action_id: string; value?: string; selected_options?: { value: string }[] }[];
  } | null;
  const a = payload?.actions?.[0];
  if (payload?.type !== "block_actions" || !a || !payload.channel) return new Response(null, { status: 200 });
  const action: SlackAction = {
    action: a.action_id,
    value: a.value ?? null,
    selected: (a.selected_options ?? []).map((o) => o.value),
    user: { id: payload.user?.id ?? "", name: payload.user?.name ?? payload.user?.username ?? "someone" },
    channel: { id: payload.channel.id, name: payload.channel.name ?? null },
    messageTs: payload.message?.ts ?? payload.container?.message_ts ?? null,
  };
  ctx.waitUntil(orgHub(env).fetch("https://org/slack/action", { method: "POST", body: JSON.stringify(action) }));
  return new Response(null, { status: 200 });
}

// ---- Web API ----

/** A Slack Web API call with the bot token; throws with Slack's error when it isn't ok. */
export async function slackApi(token: string, method: string, args: Record<string, unknown>): Promise<Record<string, any>> {
  const read = method === "conversations.replies" || method === "users.info";
  const res = read
    ? await fetch(`${API}/${method}?${new URLSearchParams(Object.entries(args).map(([k, v]) => [k, String(v)]))}`, { headers: { authorization: `Bearer ${token}` } })
    : await fetch(`${API}/${method}`, { method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json; charset=utf-8" }, body: JSON.stringify(args) });
  const body = (await res.json().catch(() => null)) as Record<string, any> | null;
  if (!body?.ok) throw new Error(`Slack's ${method} said ${body?.error ?? res.status}`);
  return body;
}

export type Blocks = Record<string, unknown>[];

/** Posts in a thread (or in the channel, with no `threadTs`); the message's ts. */
export async function postMessage(token: string, channel: string, threadTs: string | null, said: string, blocks?: Blocks): Promise<string> {
  return (await slackApi(token, "chat.postMessage", { channel, ...(threadTs ? { thread_ts: threadTs } : {}), text: said, ...(blocks ? { blocks } : {}), unfurl_links: false })).ts as string;
}

/** Replaces one of the bot's messages. */
export async function updateMessage(token: string, channel: string, ts: string, said: string, blocks?: Blocks): Promise<void> {
  await slackApi(token, "chat.update", { channel, ts, text: said, blocks: blocks ?? [] });
}

/** Someone's display name, else their real name, else their id. */
export async function userName(token: string, user: string): Promise<string> {
  const info = await slackApi(token, "users.info", { user }).catch(() => null);
  const p = info?.user?.profile ?? {};
  return p.display_name || p.real_name || info?.user?.name || user;
}

/** A request's reply address for a Slack thread: `slack:<channel>|<thread ts>|<what in it>`. */
export const threadAddress = (channel: string, threadTs: string, tag: string) => `slack:${channel}|${threadTs}|${tag}`;

/** Where a `slack:` reply address posts. */
export function parseThreadAddress(address: string): { channel: string; threadTs: string } | null {
  const [channel, threadTs] = address.slice("slack:".length).split("|");
  return address.startsWith("slack:") && channel && threadTs ? { channel, threadTs } : null;
}

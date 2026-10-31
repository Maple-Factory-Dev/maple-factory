// Requests from Linear and Jira: an issue labelled for the factory (`maple` unless set otherwise)
// becomes a request, comments on it join the request's thread, and the factory's bot answers there as
// a comment. A request's reply address names where it came from: `linear:<issue id>` or
// `jira:<site>|<issue key>`; Slack and webhooks use plain https URLs (see `deliver`).

import type { Env } from "./env.ts";
import type { TicketLink } from "./wire.ts";
import { orgHub, sameText, text } from "./util.ts";
import { verifyWebhook } from "./github.ts";
import { integrationAccess, integrationConfig, integrationEvent, type IntegrationAccess } from "./integrations/registry.ts";
import { parseThreadAddress, postMessage } from "./slack.ts";

/** Starts every comment the bot writes, so the webhook for it isn't taken as the requester talking. */
const BOT = "Maple · ";
const enc = new TextEncoder();

async function hmacHex(secret: string, message: string) {
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return [...new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(message)))].map((b) => b.toString(16).padStart(2, "0")).join("");
}

const newRequest = (env: Env, body: unknown) => orgHub(env).fetch("https://org/intake", { method: "POST", body: JSON.stringify(body) });
const replyTo = (env: Env, replyUrl: string, author: string, said: string) =>
  orgHub(env).fetch("https://org/intake/reply", { method: "POST", body: JSON.stringify({ replyUrl, author, text: said }) });

// ---- Linear ----

interface LinearIssue {
  id: string;
  identifier?: string;
  title?: string;
  description?: string | null;
  url?: string;
  labels?: { id: string; name: string }[];
  state?: { name?: string };
}

/** POST /integrations/linear: Linear's webhook, signed with its secret (`Linear-Signature`). */
export async function linearWebhook(request: Request, env: Env): Promise<Response> {
  const linear = await integrationConfig(env, "linear");
  if (!linear) return text("Linear isn't set up for this factory.", 404);
  const raw = await request.text();
  const signature = request.headers.get("linear-signature") ?? "";
  if (!sameText(signature, await hmacHex(linear.webhookSecret, raw))) {
    await integrationEvent(env, "linear", "A webhook came with a bad signature: check the signing secret.");
    return text("Bad signature.", 401);
  }
  const event = JSON.parse(raw) as {
    action: string;
    type: string;
    data: Record<string, unknown>;
    updatedFrom?: { labelIds?: string[] };
    actor?: { name?: string };
    webhookTimestamp?: number;
  };
  if (event.webhookTimestamp && Math.abs(Date.now() - event.webhookTimestamp) > 60_000) return text("Stale request.", 401);
  await integrationEvent(env, "linear");
  const label = (linear.label || "maple").toLowerCase();

  if (event.type === "Issue" && (event.action === "create" || event.action === "update")) {
    const issue = event.data as unknown as LinearIssue;
    const ours = issue.labels?.find((l) => l.name.toLowerCase() === label);
    // A new issue with the label, or the label just added to one.
    const added = event.action === "create" || (event.updatedFrom?.labelIds && ours && !event.updatedFrom.labelIds.includes(ours.id));
    if (!ours || !added) return new Response(null, { status: 204 });
    const ticket: TicketLink = { system: "linear", key: issue.identifier ?? issue.id, title: issue.title ?? "", status: issue.state?.name ?? "", url: issue.url ?? null, asContext: false };
    return newRequest(env, {
      source: "linear",
      channel: issue.identifier ?? null,
      requester: event.actor?.name ?? "someone",
      title: issue.title ?? ticket.key,
      text: issue.description ?? "",
      tickets: [ticket],
      replyUrl: `linear:${issue.id}`,
    });
  }
  if (event.type === "Comment" && event.action === "create") {
    const comment = event.data as { body?: string; issueId?: string; user?: { name?: string } };
    if (!comment.issueId || !comment.body || comment.body.startsWith(BOT)) return new Response(null, { status: 204 });
    const res = await replyTo(env, `linear:${comment.issueId}`, comment.user?.name ?? event.actor?.name ?? "someone", comment.body);
    return new Response(null, { status: res.ok ? 204 : 202 });
  }
  return new Response(null, { status: 204 });
}

// ---- Jira ----

/** POST /integrations/jira?secret=…: Jira's webhook (Jira Cloud doesn't sign them; the URL carries a secret). */
export async function jiraWebhook(request: Request, env: Env, url: URL): Promise<Response> {
  const jira = await integrationConfig(env, "jira");
  if (!jira) return text("Jira isn't set up for this factory.", 404);
  if (!sameText(url.searchParams.get("secret") ?? "", jira.webhookSecret)) {
    await integrationEvent(env, "jira", "A webhook came with the wrong ?secret= in its URL.");
    return text("Bad secret.", 401);
  }
  const event = (await request.json()) as {
    webhookEvent: string;
    issue?: { key: string; self: string; fields?: { summary?: string; description?: string | null; labels?: string[]; status?: { name?: string } } };
    comment?: { body?: string; author?: { displayName?: string } };
    changelog?: { items?: { field: string; fromString?: string | null; toString?: string | null }[] };
    user?: { displayName?: string };
  };
  const issue = event.issue;
  if (!issue) return new Response(null, { status: 204 });
  const site = new URL(issue.self).origin;
  if (jira.site && site !== new URL(jira.site).origin) {
    await integrationEvent(env, "jira", `A webhook came from ${site}, not ${jira.site}.`);
    return text(`Not from ${jira.site}.`, 400);
  }
  await integrationEvent(env, "jira");
  const replyUrl = `jira:${site}|${issue.key}`;
  const label = (jira.label || "maple").toLowerCase();
  const has = (labels: string | null | undefined) => (labels ?? "").toLowerCase().split(/\s+/).includes(label);

  if (event.webhookEvent === "jira:issue_created" || event.webhookEvent === "jira:issue_updated") {
    const labelled = (issue.fields?.labels ?? []).some((l) => l.toLowerCase() === label);
    const change = event.changelog?.items?.find((i) => i.field === "labels");
    const added = event.webhookEvent === "jira:issue_created" || (change && has(change.toString) && !has(change.fromString));
    if (!labelled || !added) return new Response(null, { status: 204 });
    const ticket: TicketLink = { system: "jira", key: issue.key, title: issue.fields?.summary ?? "", status: issue.fields?.status?.name ?? "", url: `${site}/browse/${issue.key}`, asContext: false };
    return newRequest(env, {
      source: "jira",
      channel: issue.key,
      requester: event.user?.displayName ?? "someone",
      title: issue.fields?.summary ?? issue.key,
      text: issue.fields?.description ?? "",
      tickets: [ticket],
      replyUrl,
    });
  }
  if (event.webhookEvent === "comment_created") {
    const body = event.comment?.body ?? "";
    if (!body || body.startsWith(BOT)) return new Response(null, { status: 204 });
    const res = await replyTo(env, replyUrl, event.comment?.author?.displayName ?? "someone", body);
    return new Response(null, { status: res.ok ? 204 : 202 });
  }
  return new Response(null, { status: 204 });
}

// ---- Replies ----

/** Says `said` where a request came from: a Slack thread @Maple was asked in, a Slack response URL or webhook, a Linear issue or a Jira issue. */
export async function deliver(env: Env, replyUrl: string, said: string, integrations: IntegrationAccess = integrationAccess(env)): Promise<void> {
  if (replyUrl.startsWith("slack:")) {
    const slack = await integrations.config("slack");
    const thread = parseThreadAddress(replyUrl);
    if (!slack?.botToken || !thread) return;
    await postMessage(slack.botToken, thread.channel, thread.threadTs, said).catch((e) => integrations.event("slack", `Couldn't post in a thread: ${(e as Error).message}`));
    return;
  }
  if (replyUrl.startsWith("linear:")) {
    const linear = await integrations.config("linear");
    if (!linear?.apiKey) return;
    const res = await fetch(env.LINEAR_API_URL || "https://api.linear.app/graphql", {
      method: "POST",
      headers: { "content-type": "application/json", authorization: linear.apiKey },
      body: JSON.stringify({
        query: "mutation($input: CommentCreateInput!) { commentCreate(input: $input) { success } }",
        variables: { input: { issueId: replyUrl.slice("linear:".length), body: BOT + said } },
      }),
    });
    if (!res.ok) await integrations.event("linear", `Linear refused the bot's comment (${res.status}): check the API key.`);
    return;
  }
  if (replyUrl.startsWith("jira:")) {
    const jira = await integrations.config("jira");
    if (!jira?.email || !jira.apiToken || !jira.site) return;
    const [site, key] = replyUrl.slice("jira:".length).split("|");
    if (site !== new URL(jira.site).origin) return; // the token only goes to the configured site
    const res = await fetch(`${site}/rest/api/2/issue/${encodeURIComponent(key)}/comment`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Basic ${btoa(`${jira.email}:${jira.apiToken}`)}` },
      body: JSON.stringify({ body: BOT + said }),
    });
    if (!res.ok) await integrations.event("jira", `Jira refused the bot's comment (${res.status}): check the email and API token.`);
    return;
  }
  await fetch(replyUrl, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ text: said, response_type: "in_channel" }) });
}

// ---- GitHub ----

/** POST /integrations/github: the GitHub App's webhook (signed with GITHUB_WEBHOOK_SECRET). */
export async function githubWebhook(request: Request, env: Env): Promise<Response> {
  if (!env.GITHUB_WEBHOOK_SECRET) return text("GitHub webhooks aren't set up for this factory.", 404);
  const raw = await request.arrayBuffer();
  if (!(await verifyWebhook(env.GITHUB_WEBHOOK_SECRET, raw, request.headers.get("x-hub-signature-256")))) return text("Bad signature.", 401);
  const kind = request.headers.get("x-github-event") ?? "";
  const e = JSON.parse(new TextDecoder().decode(raw)) as any;
  // The app was installed, removed, or given or denied repos: the org's repo list changed.
  if (kind === "installation" || kind === "installation_repositories") {
    await orgHub(env).fetch("https://org/github/repos", { method: "POST" });
    return new Response(null, { status: 204 });
  }
  const owner = e.repository?.owner?.login;
  const repo = e.repository?.name;
  if (typeof owner !== "string" || typeof repo !== "string") return new Response(null, { status: 204 });
  const event =
    kind === "check_run" ? { sha: e.check_run?.head_sha }
    : kind === "check_suite" ? { sha: e.check_suite?.head_sha }
    : kind === "status" ? { sha: e.sha }
    : kind === "pull_request" ? { number: e.number, sha: e.pull_request?.head?.sha, closed: e.action === "closed", merged: e.pull_request?.merged === true }
    : null;
  if (!event) return new Response(null, { status: 204 });
  await orgHub(env).fetch("https://org/github", { method: "POST", body: JSON.stringify({ owner, repo, ...event }) });
  return new Response(null, { status: 204 });
}

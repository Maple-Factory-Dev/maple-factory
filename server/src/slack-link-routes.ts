// Linking a Slack account to the signed-in member (slack-links.ts): GET /link/slack is the confirm page the
// ephemeral `@Maple link` button opens, POST /api/slack/link redeems its code for the session's member, and
// DELETE /api/slack/link unlinks. Every link and unlink is audited.

import type { Env } from "./env.ts";
import type { Member } from "./wire.ts";
import { escape, page } from "./page.ts";
import { linkOf, peek, redeem, unlink, type SlackAccount } from "./slack-links.ts";
import { audit, text } from "./util.ts";

const who = (a: SlackAccount) => `@${a.name ?? a.user}${a.teamName ? ` in ${a.teamName}` : ""}`;

/** The confirm page; signed out, it goes through sign-in and comes back. */
export async function linkPage(env: Env, url: URL, me: Member | null): Promise<Response> {
  const code = url.searchParams.get("code") ?? "";
  if (!me) return Response.redirect(`${url.origin}/auth/login?next=${encodeURIComponent(`/link/slack?code=${code}`)}`, 302);
  const slack = await peek(env, code);
  if (!slack) {
    return page("Link Slack", `<p><a class="button" href="/app/settings">Open Settings</a></p>`, {
      card: true, eyebrow: "Slack", heading: "That link has expired",
      lede: "Link codes work once, for 10 minutes. Mention <b>@Maple</b> with <code>link</code> in Slack for a fresh one.",
    });
  }
  const body = `<div class="link-confirm">
    <div class="link-pair"><span class="chip">Slack ${escape(who(slack))}</span><span class="arrow" aria-hidden="true">→</span><span class="chip">GitHub @${escape(me.login)}</span></div>
    <p><button class="primary" id="confirm" type="button">Link my account</button> <a class="button" href="/app">Not now</a></p>
    <p class="note" id="status" role="status"></p>
  </div>
  <style>
    .link-pair { display: flex; flex-wrap: wrap; align-items: center; justify-content: center; gap: 10px; margin: 0 0 22px; }
    .link-pair .chip { font: 500 14px/1 var(--mono); padding: 9px 12px; border-radius: 999px; background: var(--fill); border: 1px solid var(--stroke); overflow-wrap: anywhere; }
    .link-pair .arrow { color: var(--accent); font-size: 18px; }
  </style>
  <script>
    document.getElementById("confirm").addEventListener("click", async (e) => {
      e.target.disabled = true;
      const status = document.getElementById("status");
      const res = await fetch("/api/slack/link", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ code: ${JSON.stringify(code).replace(/</g, "\\u003c")} }) });
      if (res.ok) { status.textContent = "Linked. @Maple knows it's you now: try @Maple mine in Slack."; e.target.textContent = "Linked"; }
      else { status.textContent = await res.text(); e.target.disabled = false; }
    });
  </script>`;
  return page("Link Slack", body, {
    card: true, eyebrow: "Slack",
    heading: `Link Slack ${escape(who(slack))} to @${escape(me.login)}?`,
    lede: "Then @Maple knows it's you asking: it can list your work, see your tasks when you ask about them, and credit you for tasks you create from Slack.",
  });
}

/** POST and DELETE /api/slack/link. */
export async function linkApi(request: Request, env: Env, me: Member): Promise<Response | null> {
  if (request.method === "POST") {
    const { code } = (await request.json().catch(() => ({}))) as { code?: unknown };
    const linked = typeof code === "string" ? await redeem(env, code, me.login) : null;
    if (!linked) return text("That link has expired or was used. Mention @Maple with `link` in Slack for a fresh one.", 400);
    await audit(env, me.login, "slack.linked", me.login, { team: linked.team, user: linked.user });
    return Response.json({ slack: linked });
  }
  if (request.method === "DELETE") {
    const was = await linkOf(env, me.login);
    if (await unlink(env, { login: me.login })) await audit(env, me.login, "slack.unlinked", me.login, was ? { team: was.team, user: was.user } : null);
    return Response.json({ slack: null });
  }
  return null;
}

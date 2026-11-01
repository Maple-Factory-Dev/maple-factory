// GET /link/slack: the confirm page the ephemeral `@Maple link` button opens (slack-links.ts); its button POSTs
// the code to /api/slack/link (linkApi there).

import type { Env } from "./env.ts";
import type { Member } from "./wire.ts";
import { escape, page } from "./page.ts";
import { peek, type SlackAccount } from "./slack-links.ts";

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

// A plain page at `/` until the web companion exists: who you are, and a way to add a machine.

import type { Env } from "./env.ts";
import type { Member } from "./wire.ts";
import { authConfigured } from "./auth.ts";

export const escape = (s: string) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]!);

export function home(request: Request, env: Env, me: Member | null): Response {
  const org = escape(env.GITHUB_ORG || "this factory");
  const body = me
    ? `<p>Signed in as <b>${escape(me.login)}</b> (${escape(me.role)}) in ${org}.</p>
       <p><a href="/app">Open the factory</a>: your inbox, plans to approve and changes to review.</p>
       <p><button id="add">Add a machine</button></p><pre id="out"></pre>
       <script>
         document.getElementById("add").onclick = async () => {
           const res = await fetch("/api/machines/enroll", { method: "POST" });
           const out = document.getElementById("out");
           if (!res.ok) { out.textContent = await res.text(); return; }
           const { commands } = await res.json();
           out.textContent = "On the machine (the code works once, for 15 minutes):\\n\\n" + commands.join("\\n");
         };
       </script>`
    : authConfigured(env)
      ? `<p>${env.GITHUB_OWNER_TYPE === "User" ? `${org} signs` : `Members of ${org} sign`} in with GitHub.</p><p><a href="/auth/login">Sign in with GitHub</a></p>`
      : `<p>GitHub sign-in isn't set up yet.</p><p><a href="/setup">Finish setting up this factory</a> (as ${org}, or an owner of it, on GitHub).</p>`;
  return page("Maple Factory", body);
}

/** Where a task link (`/t/<id>`) lands: it opens the task in the app. Says nothing about the task,
 *  so a link that travels further than the team gives nothing away. */
export function taskLink(id: string): Response {
  const app = `maplefactory://task/${encodeURIComponent(id)}`;
  return page(`${id} · Maple Factory`, `<p>Opening <b>${escape(id)}</b> in Maple Factory…</p>
    <p><a href="${escape(app)}">Open it in the app</a> · <a href="/app#/t/${escape(encodeURIComponent(id))}">or in the browser</a></p>
    <p style="opacity:.7;font-size:13px">No app on this machine? Install it from your factory's admin.</p>
    <script>
      // Try the app; if nothing takes the link (no app here, or a phone), go to the web app.
      location.href = ${JSON.stringify(app)};
      setTimeout(() => { if (!document.hidden) location.replace(${JSON.stringify(`/app#/t/${id}`)}); }, 1500);
    </script>`);
}

export function page(title: string, body: string): Response {
  const html = `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>${escape(title)}</title>
<style>
  :root { color-scheme: light dark; --bg: #fbf9f8; --text: #24202a; --accent: #d24e26; }
  @media (prefers-color-scheme: dark) { :root { --bg: #18161c; --text: #e6e2ea; --accent: #ff7a48; } }
  body { font: 15px/1.5 system-ui, sans-serif; background: var(--bg); color: var(--text); margin: 0; display: grid; place-items: center; min-height: 100vh; }
  main { max-width: 34rem; padding: 24px 16px; }
  a, button { color: var(--accent); font: inherit; }
  button { background: none; border: 1px solid currentColor; border-radius: 8px; padding: 6px 12px; cursor: pointer; }
  pre { white-space: pre-wrap; font-size: 13px; }
</style>
<main><h1>Maple Factory</h1>${body}</main>`;
  return new Response(html, { headers: { "content-type": "text/html; charset=utf-8" } });
}

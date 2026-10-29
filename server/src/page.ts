// The factory's own pages outside the web app: the welcome at `/` (who you are, a way into the app and
// a way to add a machine), task links, and /setup (setup.ts). They share one shell, in the Atlas fonts
// the marketing site uses (served from web/fonts) and the app's colors (web/app/app.css).

import type { Env } from "./env.ts";
import type { Member } from "./wire.ts";
import { authConfigured } from "./auth.ts";
import { SERVER_VERSION } from "./version.ts";
import type { ServerUpdate } from "./wire.ts";

export const escape = (s: string) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]!);

const GITHUB_MARK = `<svg class="gh" viewBox="0 0 16 16" aria-hidden="true"><path fill="currentColor" d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0 0 16 8c0-4.42-3.58-8-8-8z"/></svg>`;

export const githubButton = (href: string, label: string) => `<a class="button primary" href="${escape(href)}">${GITHUB_MARK}${label}</a>`;

export function home(request: Request, env: Env, me: Member | null, update: ServerUpdate | null = null): Response {
  const org = escape(env.GITHUB_ORG || "this factory");
  if (!me) {
    return authConfigured(env)
      ? page("Maple Factory", `<p>${githubButton("/auth/login", "Sign in with GitHub")}</p>`, {
          card: true, eyebrow: org, heading: "Sign in to your factory",
          lede: `${env.GITHUB_OWNER_TYPE === "User" ? `${org} signs` : `Members of ${org} sign`} in with GitHub.`,
        })
      : page("Maple Factory", `<p><a class="button primary" href="/setup">Finish setup</a></p>
          <p class="note">As ${org}, or an owner of it, on GitHub.</p>`, {
          card: true, eyebrow: "Almost there", heading: "Finish setting up this factory",
          lede: "GitHub sign-in isn't set up yet. It takes a couple of minutes.",
        });
  }
  const body = `${updateNotice(update)}
    <div class="cards">
      <a class="card action" href="/app">
        <span class="icon accent" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M4 6.5h16M4 12h16M4 17.5h9"/></svg></span>
        <span class="grow"><b class="title">Open the factory</b><span class="sub">Your inbox, plans to approve and changes to review.</span></span>
        <span class="go" aria-hidden="true">→</span>
      </a>
      <section class="card">
        <div class="head">
          <span class="icon" aria-hidden="true"><svg viewBox="0 0 24 24"><rect x="3.5" y="4.5" width="17" height="12" rx="2.5"/><path d="M8.5 20h7M12 16.5V20"/></svg></span>
          <span class="grow"><b class="title">Add a machine</b><span class="sub">Run one command on a Mac or Linux machine and it starts taking tasks.</span></span>
        </div>
        <button id="add" class="button">Add a machine</button>
        <div id="out" hidden>
          <div class="term">
            <div class="term-bar"><span class="dots"><i></i><i></i><i></i></span><span>On the machine</span><button id="copy" type="button">Copy</button></div>
            <pre id="cmd"></pre>
          </div>
          <p class="note" id="expiry"></p>
        </div>
        <p id="err" class="notice" hidden></p>
      </section>
    </div>
    <script>
      const $ = (id) => document.getElementById(id);
      let commands = [], timer;
      $("add").onclick = async () => {
        $("add").disabled = true;
        $("err").hidden = true;
        try {
          const res = await fetch("/api/machines/enroll", { method: "POST" });
          if (!res.ok) throw new Error(await res.text() || res.statusText);
          const made = await res.json();
          commands = made.commands;
          $("cmd").innerHTML = commands.map((c) => '<span class="prompt">$ </span>' + c.replace(/[&<>]/g, (x) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" })[x])).join("\\n");
          $("out").hidden = false;
          $("add").textContent = "Make a new code";
          clearInterval(timer);
          const tick = () => {
            const min = Math.ceil((made.expiresAt - Date.now()) / 60000);
            $("expiry").textContent = min > 0 ? "Works once · expires in " + min + " min" : "This code expired. Make a new one.";
            if (min <= 0) clearInterval(timer);
          };
          tick(); timer = setInterval(tick, 15000);
        } catch (e) {
          $("err").textContent = "Couldn't make a code: " + e.message;
          $("err").hidden = false;
        } finally { $("add").disabled = false; }
      };
      $("copy").onclick = async () => {
        try { await navigator.clipboard.writeText(commands.join("\\n")); }
        catch { getSelection().selectAllChildren($("cmd")); document.execCommand("copy"); }
        $("copy").textContent = "Copied";
        setTimeout(() => ($("copy").textContent = "Copy"), 1600);
      };
    </script>`;
  return page("Maple Factory", body, {
    eyebrow: org,
    heading: `Welcome back, ${escape(me.login)}`,
    lede: `Signed in as <b>${escape(me.login)}</b> <span class="badge">${escape(me.role)}</span> in ${org}.`,
  });
}

/** Where a task link (`/t/<id>`) lands: it opens the task in the app. Says nothing about the task,
 *  so a link that travels further than the team gives nothing away. */
export function taskLink(id: string): Response {
  const app = `maplefactory://task/${encodeURIComponent(id)}`;
  return page(`${id} · Maple Factory`, `<p class="opening"><span class="spinner" aria-hidden="true"></span>Opening <b>${escape(id)}</b> in Maple Factory…</p>
    <p class="row"><a class="button primary" href="${escape(app)}">Open it in the app</a><a class="button" href="/app#/t/${escape(encodeURIComponent(id))}">Open in the browser</a></p>
    <p class="note">No app on this machine? Install it from your factory's admin.</p>
    <script>
      // Try the app; if nothing takes the link (no app here, or a phone), go to the web app.
      location.href = ${JSON.stringify(app)};
      setTimeout(() => { if (!document.hidden) location.replace(${JSON.stringify(`/app#/t/${id}`)}); }, 1500);
    </script>`, { card: true, eyebrow: "Task link", heading: escape(id) });
}

/** For admins: a newer maple-server is out, and how this factory gets it. */
export function updateNotice(update: ServerUpdate | null): string {
  if (!update) return "";
  const how = escape(update.how).replace(/`([^`]+)`/g, "<code>$1</code>");
  return `<p class="notice"><b>maple-server ${escape(update.version)} is out</b> (this factory runs ${escape(SERVER_VERSION)}). ${how}</p>`;
}

export interface PageOptions {
  /** The page's h1, as HTML; the title by default. */
  heading?: string;
  /** A short line above the heading. */
  eyebrow?: string;
  /** A sentence under the heading, as HTML. */
  lede?: string;
  /** Put the heading and body in one card (a page with one thing to do). */
  card?: boolean;
}

export function page(title: string, body: string, opts: PageOptions = {}): Response {
  const hero = `${opts.eyebrow ? `<p class="eyebrow">${opts.eyebrow}</p>` : ""}<h1>${opts.heading ?? escape(title)}</h1>${opts.lede ? `<p class="lede">${opts.lede}</p>` : ""}`;
  const html = `<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escape(title)}</title>
<link rel="icon" href="/img/favicon.png">
<link rel="preload" href="/fonts/AtlasSans-VF.woff2" as="font" type="font/woff2" crossorigin>
<link rel="preload" href="/fonts/AtlasSerif-VF.woff2" as="font" type="font/woff2" crossorigin>
<style>
  @font-face { font-family: "Atlas Serif"; src: url("/fonts/AtlasSerif-VF.woff2") format("woff2"); font-weight: 100 900; font-display: swap; }
  @font-face { font-family: "Atlas Sans"; src: url("/fonts/AtlasSans-VF.woff2") format("woff2"); font-weight: 100 900; font-display: swap; }
  @font-face { font-family: "Atlas Mono"; src: url("/fonts/AtlasMono-VF.woff2") format("woff2"); font-weight: 100 900; font-display: swap; }
  :root {
    color-scheme: light dark;
    --serif: "Atlas Serif", ui-serif, Georgia, serif;
    --sans: "Atlas Sans", ui-sans-serif, system-ui, -apple-system, sans-serif;
    --mono: "Atlas Mono", ui-monospace, "SF Mono", Menlo, monospace;
    --bg: #fbf9f8; --card: #ffffff; --text: #1d2025; --muted: #6a707a; --faint: #a9aeb6;
    --stroke: rgba(0, 0, 0, 0.08); --fill: rgba(0, 0, 0, 0.045); --accent: #d24e26; --on-accent: #fff;
    --ok: #1f883d; --glow: rgba(238, 122, 60, 0.22); --term: #15131a; --term-text: #d5d8dd; --term-dim: #7d808a;
    --shadow: 0 1px 0 rgba(255, 255, 255, 0.7) inset, 0 24px 60px -28px rgba(60, 20, 40, 0.25), 0 4px 14px -8px rgba(60, 20, 40, 0.12);
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #18161c; --card: #201d25; --text: #e4e6ea; --muted: #9096a0; --faint: #5d626c;
      --stroke: rgba(255, 255, 255, 0.08); --fill: rgba(255, 255, 255, 0.06); --accent: #ff7a48; --on-accent: #2a0f12;
      --ok: #3dd68c; --glow: rgba(255, 122, 72, 0.16); --term: #0f0d13;
      --shadow: 0 1px 0 rgba(255, 255, 255, 0.04) inset, 0 30px 70px -28px rgba(0, 0, 0, 0.7), 0 4px 14px -8px rgba(0, 0, 0, 0.4);
    }
  }
  * { box-sizing: border-box; }
  [hidden] { display: none !important; }
  html { background: var(--bg); }
  body { margin: 0; min-height: 100vh; display: flex; flex-direction: column; background: var(--bg); color: var(--text);
    font: 15.5px/1.55 var(--sans); -webkit-font-smoothing: antialiased; position: relative; }
  body::before { content: ""; position: absolute; z-index: -1; inset: -120px 0 auto; height: 560px; pointer-events: none;
    background: radial-gradient(40rem 22rem at 50% 30%, var(--glow), transparent 70%); }
  .shell { width: 100%; max-width: 40rem; margin: 0 auto; padding: 28px 16px 40px; flex: 1; }
  header.top { display: flex; align-items: center; justify-content: space-between; margin-bottom: 40px; }
  .brand { display: inline-flex; align-items: center; gap: 10px; text-decoration: none; color: var(--text); font: 650 18px/1 var(--serif); letter-spacing: -0.015em; }
  .brand img { width: 30px; height: 30px; border-radius: 8px; box-shadow: 0 2px 8px -2px rgba(42, 21, 48, .4); }
  .eyebrow { margin: 0 0 8px; font: 500 12px/1.2 var(--mono); letter-spacing: .08em; text-transform: uppercase; color: var(--accent); }
  h1 { font: 600 clamp(30px, 6vw, 40px)/1.1 var(--serif); letter-spacing: -0.02em; margin: 0 0 10px; overflow-wrap: anywhere; }
  .lede { margin: 0 0 28px; font-size: 17px; color: var(--muted); }
  .lede b { color: var(--text); font-weight: 600; }
  h2 { font: 600 19px/1.25 var(--serif); letter-spacing: -0.01em; margin: 0 0 6px; display: flex; align-items: center; gap: 10px; }
  p { margin: 0 0 12px; }
  a { color: var(--accent); text-underline-offset: 2px; }
  b { font-weight: 600; }

  .card { display: block; background: var(--card); border: 1px solid var(--stroke); border-radius: 18px; padding: 22px; box-shadow: var(--shadow); }
  .card > :last-child { margin-bottom: 0; }
  .card.solo { padding: 32px 28px; text-align: center; }
  .card.solo .lede { margin-bottom: 22px; }
  .cards { display: grid; gap: 14px; }
  .head, .action { display: flex; gap: 14px; align-items: flex-start; }
  .head { margin-bottom: 16px; }
  .grow { flex: 1; min-width: 0; display: grid; gap: 2px; }
  .title { font: 600 19px/1.3 var(--serif); letter-spacing: -0.01em; color: var(--text); }
  .sub { color: var(--muted); font-size: 14.5px; }
  .icon { flex: none; display: grid; place-items: center; width: 42px; height: 42px; border-radius: 12px; background: var(--fill); color: var(--text); }
  .icon.accent { background: var(--accent); color: var(--on-accent); }
  .icon svg { width: 22px; height: 22px; fill: none; stroke: currentColor; stroke-width: 1.8; stroke-linecap: round; stroke-linejoin: round; }
  a.action { text-decoration: none; transition: transform .15s ease, border-color .15s ease; }
  a.action:hover { transform: translateY(-1px); border-color: color-mix(in srgb, var(--accent) 45%, transparent); }
  .go { align-self: center; font-size: 20px; color: var(--accent); transition: transform .15s ease; }
  a.action:hover .go { transform: translateX(3px); }

  .button, button { display: inline-flex; align-items: center; justify-content: center; gap: 8px; font: 600 14.5px/1 var(--sans); color: var(--text);
    background: var(--card); border: 1px solid var(--stroke); border-radius: 10px; padding: 11px 16px; cursor: pointer; text-decoration: none;
    box-shadow: 0 1px 2px rgba(0, 0, 0, .06); transition: background .15s ease, border-color .15s ease, transform .1s ease; }
  .button:hover, button:hover { border-color: color-mix(in srgb, var(--text) 25%, transparent); }
  .button:active, button:active { transform: translateY(1px); }
  button:disabled { opacity: .6; cursor: progress; }
  .button.primary, button.primary { background: var(--accent); border-color: var(--accent); color: var(--on-accent);
    box-shadow: 0 6px 18px -8px var(--accent); padding: 13px 20px; font-size: 15px; }
  .button.primary:hover, button.primary:hover { background: color-mix(in srgb, var(--accent) 88%, #000); }
  .gh { width: 18px; height: 18px; }
  .row { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; }
  .badge { display: inline-block; padding: 1px 9px; border-radius: 99px; font: 500 12px/1.6 var(--mono); vertical-align: 2px;
    background: color-mix(in srgb, var(--accent) 14%, transparent); color: var(--accent); }

  form { margin: 14px 0; }
  input { flex: 1; min-width: 0; font: 15px/1.2 var(--sans); color: inherit; background: var(--bg); border: 1px solid var(--stroke); border-radius: 10px; padding: 11px 12px; }
  input:focus { outline: 2px solid var(--accent); outline-offset: -1px; }
  .note { color: var(--muted); font-size: 13.5px; }
  .notice { border: 1px solid color-mix(in srgb, var(--accent) 50%, transparent); background: color-mix(in srgb, var(--accent) 8%, transparent);
    border-radius: 12px; padding: 12px 14px; font-size: 14px; margin: 14px 0; }
  code { font: 13px/1.4 var(--mono); background: var(--fill); padding: 1px 5px; border-radius: 5px; overflow-wrap: anywhere; }
  pre { font: 13px/1.6 var(--mono); white-space: pre-wrap; overflow-wrap: anywhere; margin: 0; }

  .term { margin-top: 16px; border-radius: 12px; background: var(--term); color: var(--term-text); overflow: hidden; border: 1px solid rgba(255, 255, 255, .06); }
  .term-bar { display: flex; align-items: center; gap: 10px; padding: 8px 8px 8px 12px; font: 12px/1 var(--mono); color: var(--term-dim); border-bottom: 1px solid rgba(255, 255, 255, .06); }
  .term-bar span:nth-child(2) { flex: 1; }
  .dots { display: inline-flex; gap: 5px; } .dots i { width: 9px; height: 9px; border-radius: 50%; background: rgba(255, 255, 255, .16); }
  .term-bar button { padding: 6px 10px; font: 500 12px/1 var(--mono); background: rgba(255, 255, 255, .08); color: var(--term-text); border-color: rgba(255, 255, 255, .1); box-shadow: none; }
  .term-bar button:hover { background: rgba(255, 255, 255, .14); }
  .term pre { padding: 14px 16px; }
  .term .prompt { color: var(--accent); user-select: none; }
  #out .note { margin: 10px 0 0; }
  #out .note::before { content: ""; display: inline-block; width: 7px; height: 7px; border-radius: 50%; background: var(--ok); margin-right: 8px; vertical-align: 1px; }

  .opening { display: flex; align-items: center; justify-content: center; gap: 10px; color: var(--muted); }
  .spinner { width: 16px; height: 16px; border-radius: 50%; border: 2px solid var(--fill); border-top-color: var(--accent); animation: spin .8s linear infinite; }
  .card.solo .row { justify-content: center; }
  @keyframes spin { to { transform: rotate(360deg); } }
  @media (prefers-reduced-motion: reduce) { * { transition: none !important; animation: none !important; } }

  /* /setup: a progress rail and a card per step. */
  .rail { list-style: none; display: flex; gap: 6px; padding: 0; margin: 0 0 22px; counter-reset: step; }
  .rail li { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 8px; font-size: 13px; color: var(--muted); }
  .rail li::before { content: ""; height: 4px; border-radius: 4px; background: var(--fill); }
  .rail li.done::before, .rail li.now::before { background: var(--accent); }
  .rail li.now { color: var(--text); font-weight: 600; }
  .rail li span { font: 500 11px/1 var(--mono); color: var(--faint); display: block; margin-bottom: 3px; }
  .rail li.done span, .rail li.now span { color: var(--accent); }
  .steps { display: grid; gap: 14px; }
  .step.later { box-shadow: none; background: transparent; border-style: dashed; }
  .step.later h2, .step.later p { color: var(--muted); }
  .n { flex: none; display: inline-grid; place-items: center; width: 26px; height: 26px; border-radius: 50%; background: var(--accent); color: var(--on-accent); font: 600 13px/1 var(--mono); }
  .n.ok { background: var(--ok); color: #fff; }
  .later .n { background: var(--fill); color: var(--muted); }
  .inline { display: flex; gap: 8px; }
  .inline input { min-width: 0; }
  @media (max-width: 420px) { .inline { flex-direction: column; } }
  .status { display: inline-flex; align-items: flex-start; gap: 8px; padding: 8px 12px; border-radius: 12px; font-size: 13.5px; background: var(--fill); color: var(--text); }
  .status::before { content: ""; flex: none; width: 7px; height: 7px; margin-top: 6px; border-radius: 50%; background: var(--faint); }
  .status[data-state="busy"]::before { background: var(--accent); animation: pulse 1s ease-in-out infinite; }
  .status[data-state="ok"]::before { background: var(--ok); }
  .status[data-state="bad"]::before { background: #d9534f; }
  @keyframes pulse { 50% { opacity: .3; } }
  .choices { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 10px; margin: 14px 0; }
  .choices form { margin: 0; }
  .choices button { width: 100%; height: 100%; text-align: left; padding: 16px; display: grid; justify-content: start; gap: 6px; line-height: 1.35; border-radius: 14px; }
  .choices button:hover { border-color: var(--accent); background: color-mix(in srgb, var(--accent) 6%, var(--card)); }
  .choices button b { font: 600 16px/1.2 var(--serif); }
  .choices button span { color: var(--muted); font-weight: 400; font-size: 13.5px; }
  .checklist { list-style: none; padding: 0; margin: 0; display: grid; gap: 10px; counter-reset: item; }
  .checklist li { display: flex; gap: 14px; align-items: flex-start; padding: 16px; border: 1px solid var(--stroke); border-radius: 14px; background: var(--bg); }
  .checklist li .grow { gap: 4px; }
  .checklist li .button { margin-top: 8px; justify-self: start; }

  footer { text-align: center; padding: 20px 16px 28px; font: 12px/1.4 var(--mono); color: var(--faint); }
  footer a { color: inherit; }
</style>
<body>
<div class="shell">
  <header class="top"><a class="brand" href="/"><img src="/img/icon-512.webp" alt="" width="30" height="30"><span>Maple Factory</span></a></header>
  <main>${opts.card ? `<div class="card solo">${hero}${body}</div>` : `${hero}${body}`}</main>
</div>
<footer>maple-server ${escape(SERVER_VERSION)} · <a href="https://maplefactory.dev">maplefactory.dev</a></footer>
</body></html>`;
  return new Response(html, { headers: { "content-type": "text/html; charset=utf-8" } });
}

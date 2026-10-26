// /setup: a new factory makes its own GitHub App. A factory from the Deploy to Cloudflare button (or
// `maple install`) knows its org (GITHUB_ORG) and nothing else, so an owner of that org opens /setup,
// GitHub creates the app from our manifest, and the app's credentials come back here and are stored
// in D1 (settings.ts). The app is both the sign-in (its OAuth client) and the bot that pushes
// branches and opens pull requests.
//
// GITHUB_ORG can also be someone's personal account: then the app is theirs, and only they (and the
// logins in GITHUB_ALLOWED_LOGINS) sign in. /setup asks GitHub which it is, and keeps the answer (GITHUB_OWNER_TYPE).
//
// Its address comes first: GitHub keeps the app's URLs, so a factory still on workers.dev offers to move
// to a domain of the person's own before the app is made. They add the domain to the Worker in Cloudflare,
// the page checks (from the browser) that the domain reaches this same factory (/setup/id), and setup
// carries on there. The address the app was made at becomes PUBLIC_URL, and pages opened at the other
// one are sent to it (index.ts).
//
// Anyone can open /setup before it's done, but only someone who may create apps on GITHUB_ORG can
// finish it: the app GitHub hands back must be owned by that account, or it's refused. Once sign-in is
// configured, /setup only says so.

import type { Env } from "./env.ts";
import { authConfigured, cookie, readCookie } from "./auth.ts";
import { apiBase } from "./github.ts";
import { escape, page } from "./page.ts";
import { saveSettings } from "./settings.ts";
import { audit, isLocal, publicOrigin, randomToken, sha256, sign, text, verify } from "./util.ts";

const STATE_TTL = 3600; // GitHub's manifest codes last an hour

/** What the app may do: push task branches, open, check and merge their PRs, and see who's in the org. */
function manifest(origin: string, org: string, personal: boolean) {
  return {
    // GitHub app names are unique and at most 34 characters; the owner can change it on the next page.
    name: `Maple Factory ${org}`.slice(0, 34),
    url: origin,
    description: `Maple Factory for ${org}: sign-in, task branches and pull requests.`,
    public: false,
    hook_attributes: { url: `${origin}/integrations/github`, active: true },
    redirect_url: `${origin}/setup/github`,
    callback_urls: [`${origin}/auth/callback`],
    setup_url: `${origin}/setup/done`,
    request_oauth_on_install: false,
    default_permissions: {
      contents: "write",
      pull_requests: "write",
      checks: "write",
      actions: "write",
      statuses: "read",
      // A personal account has no members; its owner is the only one who signs in.
      ...(personal ? {} : { members: "read" }),
      metadata: "read",
    },
    default_events: ["check_run", "check_suite", "status", "pull_request"],
  };
}

type Owner = "User" | "Organization";

/** Whether `login` is an organization or someone's personal account; null if GitHub didn't say. */
async function ownerType(env: Env, login: string): Promise<Owner | null> {
  const res = await fetch(`${apiBase(env.GITHUB_API_URL)}/users/${encodeURIComponent(login)}`, {
    headers: { accept: "application/vnd.github+json", "user-agent": "maple-factory" },
  }).catch(() => null);
  const type = res?.ok ? ((await res.json().catch(() => null)) as { type?: string } | null)?.type : undefined;
  return type === "User" || type === "Organization" ? type : null;
}

/** Where GitHub makes a new app for `org` from a manifest. */
function newAppPage(org: string, owner: Owner): string {
  return owner === "User" ? "https://github.com/settings/apps/new" : `https://github.com/organizations/${encodeURIComponent(org)}/settings/apps/new`;
}

/** Names this factory without giving anything away, so the browser can tell a domain reaches it. */
async function factoryId(secret: string): Promise<string> {
  return (await sha256(`maple-factory-id:${secret}`)).slice(0, 16);
}

/** The secret /setup signs its state with; a new factory makes one and keeps it as SESSION_SECRET. */
async function sessionSecret(env: Env): Promise<string> {
  if (!env.SESSION_SECRET) await saveSettings(env, { SESSION_SECRET: randomToken("mfs") });
  return env.SESSION_SECRET!;
}

export async function handleSetup(request: Request, env: Env): Promise<Response | null> {
  const url = new URL(request.url);
  if (url.pathname !== "/setup" && !url.pathname.startsWith("/setup/")) return null;
  const origin = publicOrigin(request, env);
  const org = env.GITHUB_ORG?.trim();

  if (url.pathname === "/setup/done") return done(env, org);
  if (url.pathname === "/setup/id") {
    return Response.json({ id: await factoryId(await sessionSecret(env)) }, { headers: { "access-control-allow-origin": "*", "cache-control": "no-store" } });
  }
  if (authConfigured(env)) {
    const who = env.GITHUB_OWNER_TYPE === "User" ? `<b>${escape(org!)}</b> signs` : `members of <b>${escape(org!)}</b> sign`;
    return page("Maple Factory", `<p>This factory is set up: ${who} in with GitHub.</p><p><a href="/auth/login">Sign in</a></p>`);
  }
  if (!org) {
    return page("Set up Maple Factory", `<p>This factory doesn't know its GitHub organization yet.</p>
      <p>In the Cloudflare dashboard, open this Worker → Settings → Variables and Secrets, set <code>GITHUB_ORG</code>
      to the organization's login (the <code>acme</code> in github.com/acme), or your own username for a factory just
      for you, deploy, and come back here.</p>`);
  }

  if (url.pathname === "/setup") {
    const secret = await sessionSecret(env);
    const state = await sign({ nonce: crypto.randomUUID(), exp: Math.floor(Date.now() / 1000) + STATE_TTL }, secret);
    const form = (owner: Owner, button: string) => `<form method="post" action="${escape(`${newAppPage(org, owner)}?state=${encodeURIComponent(state)}`)}">
        <input type="hidden" name="manifest" value="${escape(JSON.stringify(manifest(origin, org, owner === "User")))}">
        ${button}
      </form>`;
    const create = (owner: Owner) => form(owner, `<button class="primary" type="submit">Create the GitHub App</button>`);
    const who = escape(org);
    const personal = `<p>It goes on your account, <b>${who}</b>: sign in to GitHub as ${who}. Nobody else can sign in to this
        factory unless you list them in <code>GITHUB_ALLOWED_LOGINS</code>.</p>${create("User")}`;
    const team = `<p>It goes on <b>${who}</b>, and signs your team in. You need to be an owner of ${who} on GitHub (or one of its
        GitHub App managers).</p>${create("Organization")}`;
    // GitHub limits lookups without a token, and a Worker shares its address with many others, so the
    // server may get no answer; then the browser asks, and failing that, the person says which it is.
    const owner = await ownerType(env, org);
    const app = owner === "User" ? personal : owner === "Organization" ? team : `
      <div data-owner="User" hidden>${personal}</div>
      <div data-owner="Organization" hidden>${team}</div>
      <div data-owner="ask" hidden>
        <p>Is <b>${who}</b> an organization or your own account?</p>
        <div class="choices">
          ${form("Organization", `<button type="submit"><b>An organization</b><span>Its owners make the app; its members sign in</span></button>`)}
          ${form("User", `<button type="submit"><b>My personal account</b><span>Signed in to GitHub as ${who}</span></button>`)}
        </div>
      </div>
      <noscript><style>[data-owner="ask"] { display: block !important; }</style></noscript>
      <script>
        (async () => {
          const show = (o) => document.querySelector(\`[data-owner="\${o}"]\`).hidden = false;
          try {
            const res = await fetch(${JSON.stringify(`${apiBase(env.GITHUB_API_URL)}/users/${encodeURIComponent(org)}`)});
            const { type } = await res.json();
            show(type === "User" || type === "Organization" ? type : "ask");
          } catch { show("ask"); }
        })();
      </script>`;

    // Still on workers.dev: the address GitHub will keep for the app can be a domain of their own.
    const host = url.hostname;
    const onWorkersDev = host.endsWith(".workers.dev");
    const worker = host.split(".")[0];
    const where = !onWorkersDev ? "" : `
      <h2><span class="n">1</span> Where it lives</h2>
      <p>It's at <code>${escape(host)}</code>. To use a domain of your own instead, pick it now: the GitHub App keeps the address it was made at.</p>
      <form id="domain" class="row">
        <input name="domain" placeholder="factory.example.com" autocomplete="off" spellcheck="false" aria-label="Domain">
        <button type="submit">Use this domain</button>
      </form>
      <p id="domain-status" class="note" hidden></p>
      <p class="note">Or skip this and keep ${escape(host)}.</p>
      <script>
        const id = ${JSON.stringify(await factoryId(secret))};
        const dash = ${JSON.stringify(`https://dash.cloudflare.com/?to=/:account/workers/services/view/${encodeURIComponent(worker)}/production/settings`)};
        const status = document.getElementById("domain-status");
        const say = (html) => { status.innerHTML = html; status.hidden = false; };
        document.getElementById("domain").onsubmit = async (e) => {
          e.preventDefault();
          const domain = e.target.domain.value.trim().toLowerCase().replace(/^https?:\\/\\//, "").replace(/\\/.*$/, "");
          if (!/^[a-z0-9-]+(\\.[a-z0-9-]+)+$/.test(domain)) return say("That isn't a domain name.");
          say(\`Looking for this factory at \${domain}…\`);
          let found = null;
          try { found = (await (await fetch(\`https://\${domain}/setup/id\`, { cache: "no-store" })).json()).id; } catch {}
          if (found === id) { say(\`Found it. Carrying on at \${domain}…\`); location.href = \`https://\${domain}/setup\`; return; }
          say(found
            ? \`\${domain} reaches a different Maple Factory.\`
            : \`\${domain} doesn't reach this factory yet. In Cloudflare, open <a href="\${dash}" target="_blank" rel="noopener">this Worker's settings</a>,
               then <b>Domains &amp; Routes → Add → Custom domain</b>, and enter \${domain} (its zone has to be on Cloudflare, in this account).
               Give the certificate a minute, then try again.\`);
        };
      </script>`;

    const html = page("Set up Maple Factory", `<p>Two steps and it's yours.</p>${where}
      ${onWorkersDev ? `<h2><span class="n">2</span> Its GitHub App</h2>` : `<h2>Its GitHub App</h2>`}
      <p>The app signs people in, and pushes, checks and merges tasks' pull requests. GitHub shows what it can do before you create it.</p>
      ${app}
      <p class="note">It points at ${escape(origin)}.</p>`);
    html.headers.append("set-cookie", cookie(url, "setup", state, STATE_TTL));
    return html;
  }

  if (url.pathname === "/setup/github") {
    const state = url.searchParams.get("state") ?? "";
    const code = url.searchParams.get("code") ?? "";
    const secret = await sessionSecret(env);
    if (!code || state !== readCookie(request, "setup") || !(await verify<{ exp: number }>(state, secret))) {
      return text("That setup link expired or didn't start in this browser. Open /setup again.", 400);
    }
    const res = await fetch(`${apiBase(env.GITHUB_API_URL)}/app-manifests/${encodeURIComponent(code)}/conversions`, {
      method: "POST",
      headers: { accept: "application/vnd.github+json", "user-agent": "maple-factory" },
    });
    const app = (await res.json().catch(() => null)) as {
      id?: number; slug?: string; client_id?: string; client_secret?: string; webhook_secret?: string | null; pem?: string; owner?: { login?: string; type?: string };
    } | null;
    if (!res.ok || !app?.id || !app.client_id || !app.client_secret || !app.pem || !app.slug) {
      return text(`GitHub didn't hand over the new app (${res.status}). Open /setup to try again.`, 502);
    }
    if (app.owner?.login?.toLowerCase() !== org.toLowerCase()) {
      await audit(env, `github:${app.owner?.login ?? "?"}`, "setup.refused", null, { org, app: app.slug });
      return text(`That app belongs to ${app.owner?.login ?? "someone else"}, not ${org}. Create it under ${org} (and delete the other one on GitHub).`, 403);
    }
    await saveSettings(env, {
      GITHUB_APP_ID: String(app.id),
      GITHUB_APP_SLUG: app.slug,
      GITHUB_CLIENT_ID: app.client_id,
      GITHUB_CLIENT_SECRET: app.client_secret,
      GITHUB_APP_PRIVATE_KEY: app.pem,
      GITHUB_OWNER_TYPE: app.owner.type === "User" ? "User" : "Organization",
      // The address the app knows; other ones send pages here (index.ts).
      ...(isLocal(request) ? {} : { PUBLIC_URL: origin }),
      ...(app.webhook_secret ? { GITHUB_WEBHOOK_SECRET: app.webhook_secret } : {}),
    });
    await audit(env, `github:${org}`, "setup.github_app", null, { app: app.slug, id: app.id });
    // Next, install it on the account; GitHub sends them back to /setup/done.
    const headers = new Headers({ location: `https://github.com/apps/${encodeURIComponent(app.slug)}/installations/new` });
    headers.append("set-cookie", cookie(url, "setup", "", 0));
    return new Response(null, { status: 302, headers });
  }

  return text("Not found.", 404);
}

/** After installing: device flow, which the Mac app signs in with, can only be switched on by hand. */
function done(env: Env, org: string | undefined): Response {
  const slug = env.GITHUB_APP_SLUG;
  if (!org || !slug) return page("Set up Maple Factory", `<p><a href="/setup">Start setting up this factory</a>.</p>`);
  const settings = env.GITHUB_OWNER_TYPE === "User"
    ? `https://github.com/settings/apps/${encodeURIComponent(slug)}`
    : `https://github.com/organizations/${encodeURIComponent(org)}/settings/apps/${encodeURIComponent(slug)}`;
  return page("Maple Factory is ready", `<p>The GitHub App <b>${escape(slug)}</b> is set up for ${escape(org)}.</p>
    <ol>
      <li>Install it on the repositories you work in, if you haven't: <a href="https://github.com/apps/${escape(encodeURIComponent(slug))}/installations/new">install</a>.</li>
      <li>For the Mac app's sign-in, open <a href="${escape(settings)}">the app's settings</a>, tick <b>Enable Device Flow</b> and save. (GitHub can't do this one from a manifest.)</li>
      <li><a href="/auth/login">Sign in</a>, then add your machines from Machines → Add machine.</li>
    </ol>`);
}

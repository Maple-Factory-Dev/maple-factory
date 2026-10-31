# Security audit: maple-server (Cloudflare Worker)

MF-89, October 2026. Scope: everything under `server/src` — the Worker's router (`index.ts`), sign-in
(`auth.ts`), `/setup`, runners and machines, attachments, proofs and the icon, the intake API and the
Slack/Linear/Jira/GitHub webhooks, the two Durable Objects, and repo secrets at rest.

Checklist: authn/authz, CSRF/origin, token handling, input validation, SSRF, XSS and headers, secrets at
rest, dev-only escape hatches.

## Routes and their guards

Guards, in the order `index.ts` applies them:

- **public**: no credential.
- **runner token**: `Authorization: Bearer mfr_…` whose SHA-256 matches the machine's row in D1
  (`machines.ts` `authenticateRunner`), for the machine named by `?runner=`.
- **intake key**: `Authorization: Bearer mfi_…` equal to `INTAKE_KEY` (constant time).
- **signature**: the provider's HMAC (Slack, Linear, GitHub) or, for Jira, a shared secret in the URL.
- **member**: a signed session cookie or an app token (`mft_…`) of a row in `members`
  (`auth.ts` `currentMember`), plus `sameOrigin` (no `Origin`, or this origin) for everything after
  `/`.
- **admin**: member with `role = "admin"`, checked in the handler.
- **local dev**: `DEV_LOGIN` set *and* the request's hostname is `localhost`/`127.0.0.1`.

### Worker (`src/index.ts`)

| Path | Method | Guard | Handler |
| --- | --- | --- | --- |
| any page in `PAGES` at a non-`PUBLIC_URL` host | GET | public (302 to `PUBLIC_URL`) | `index.ts` |
| `/healthz` | any | public | `index.ts` |
| `/runner/enroll` | POST | public + one-time enrollment code (15 min, claimed atomically) | `machines.ts` `enroll` |
| `/runner/connect?runner=` | WebSocket | runner token | → `MachineHub /runner` |
| `/runner/attachments/<uuid>/<name>?runner=` | GET | runner token | `attachments.ts` `serveRunner` |
| `/runner/proof/<task>?runner=&name=` | PUT | runner token | `attachments.ts` `uploadProof` |
| `/install.sh` | any | public | `install.ts` |
| `/icon/<uuid>` | GET | public (a logo) | `icon.ts` `serve` |
| `/releases/<path>` | any | public (runner binaries, signed manifests) | `releases.ts` |
| `/t/<TASK-ID>` | any | public (says nothing about the task) | `page.ts` `taskLink` |
| `/integrations/slack/command` | POST | signature (Slack v0 HMAC, 5 min window) | `intake-routes.ts` `slackCommand` |
| `/integrations/linear` | POST | signature (Linear HMAC, 60 s window when stamped) | `trackers.ts` `linearWebhook` |
| `/integrations/github` | POST | signature (`X-Hub-Signature-256`) | `trackers.ts` `githubWebhook` |
| `/integrations/jira?secret=` | POST | shared secret in the query string | `trackers.ts` `jiraWebhook` |
| `/api/intake…` | POST | intake key (checked here, before any member check) | `intake-routes.ts` `intakeApi` |
| `/setup` | any | public until sign-in is configured; then a static "all set" page | `setup.ts` |
| `/setup/id` | any | public, CORS `*` (a 16-hex hash of `SESSION_SECRET`) | `setup.ts` |
| `/setup/github?code=&state=` | GET | signed state equal to the `setup` cookie; app owner must be `GITHUB_ORG` | `setup.ts` |
| `/setup/done` | any | public | `setup.ts` |
| `/auth/logout` | POST | `sameOrigin` | `auth.ts` |
| `/auth/login` | any | public (503 until configured) | `auth.ts` |
| `/auth/callback?code=&state=` | any | signed state equal to the `oauth` cookie, then GitHub org membership | `auth.ts` |
| `/auth/device/start` | POST | public | `auth.ts` |
| `/auth/device/poll` | POST | GitHub device code, then org membership | `auth.ts` |
| `/dev/token` | POST | local dev (404 otherwise) | `auth.ts` `devToken` |
| `/dev/releases/<path>` | PUT | local dev | `index.ts` |
| `/dev/alarm` | POST | local dev | → `OrgHub /dev/alarm` |
| `/` | any | public; shows more when signed in | `page.ts` `home` |
| *everything below* | | member + `sameOrigin`, else 401/403 | |
| `/client/connect` | WebSocket | member | → `OrgHub /connect` |
| `/client/terminal?machine=&session=` | WebSocket | member (any member, any machine — see F-02) | → `MachineHub /view` |
| `/api/attachments?name=` | POST | member | `attachments.ts` `upload` |
| `/attachments/<uuid>/<name>` | GET | member | `attachments.ts` `serve` |
| `/api/icon` | PUT, DELETE | admin | `icon.ts` |
| `/api/intake`, `/api/intake/REQ-n/messages` | POST | member | `intake-routes.ts` `intakeApi` |
| `/api/me` | any | member | `index.ts` |
| `/api/machines` | GET | member | → `OrgHub /machines` |
| `/api/usage/goals` | GET | member | → `OrgHub /usage/goals` |
| `/api/stats` | GET | admin | → `OrgHub /stats` |
| `/api/tasks/<id>/diff` | GET | member | → `OrgHub /diff` |
| `/api/machines/enroll` | POST | member | `machines.ts` `createEnrollment` |
| `/api/machines/<id>` | DELETE | machine owner or admin | `machines.ts` `removeMachine` |
| anything else | | member | 404 |

Static files in `web/` (`/app/…`, `/fonts/…`, `/img/…`) are served by Workers Static Assets before the
Worker runs, so they have no guard; the web app holds no data of its own and reads everything over
`/client/connect`.

### Durable Objects

Both classes are bound only as `ORG` and `MACHINE` in `wrangler.jsonc` and have no route, custom domain
or `workers.dev` address of their own: a Durable Object can only be reached through a stub the Worker
gets from its namespace binding. Their `fetch` handlers trust the caller completely (they read
`x-member`, `x-machine-id` and `login` from the Worker), so every guard lives in the Worker. Confirmed:
every `orgHub(env).fetch` / `machineHub(env, id).fetch` call is behind the guard listed for its route
above, and none forwards a client-supplied header or path segment unchecked (`x-member` is set from
`currentMember`, `x-machine-id` after `authenticateRunner`, terminal `login` from the member, `session`
and `machine` against fixed patterns).

| DO endpoint | Called from | Guard upstream |
| --- | --- | --- |
| `OrgHub /connect` | `/client/connect` | member |
| `OrgHub /machine`, `/ended`, `/runner`, `/notice` | `MachineHub` (runner socket messages) | runner token |
| `OrgHub /removed` | `removeMachine` | machine owner or admin |
| `OrgHub /machines`, `/usage/goals` | `/api/machines`, `/api/usage/goals` | member |
| `OrgHub /stats` | `/api/stats` | admin |
| `OrgHub /diff` | `/api/tasks/<id>/diff` (`[\w-]+`) | member |
| `OrgHub /icon` | `icon.ts` | admin |
| `OrgHub /dev/alarm` | `/dev/alarm` | local dev |
| `OrgHub /intake`, `/intake/reply` | intake API, Slack, Linear, Jira | intake key / member / signature |
| `OrgHub /github`, `/github/repos` | `/integrations/github` | signature |
| `MachineHub /runner` | `/runner/connect` | runner token |
| `MachineHub /view` | `/client/terminal` | member |
| `MachineHub /disconnect` | `enroll` (re-enroll), `removeMachine` | enrollment code / owner or admin |
| `MachineHub /command`, `/state`, `/rename`, `/activity`, `/input` | `OrgHub` (engine, client socket messages) | member, with owner/admin checks in `org-hub.ts`/`engine.ts` |

## Findings

Severity: **critical** (anyone on the internet, full compromise), **high** (an outsider or a single
member gets more than they should, with real impact), **medium** (needs a member, a leaked secret or an
unusual setup, or the impact is limited), **low** (defence in depth, hard to exploit), **info** (checked
and fine, or a design choice worth writing down).

Line numbers are after this task's changes.

| # | Severity | Where | Status |
| --- | --- | --- | --- |
| F-01 | high | `src/releases.ts:16`, `src/index.ts:60` | fixed |
| F-02 | high | `src/index.ts:98`, `src/machine-hub.ts:110`, `src/machine-hub.ts:152` | follow-up |
| F-03 | medium | `src/auth.ts:64`, `src/auth.ts:11-12` | follow-up |
| F-04 | medium | `src/auth.ts:12`, `src/auth.ts:176` | follow-up |
| F-05 | medium | `src/intake-routes.ts:23`, `src/trackers.ts:152` | fixed |
| F-06 | medium | `src/trackers.ts:84` | follow-up |
| F-07 | low | `src/attachments.ts:32`, `src/attachments.ts:103`, `src/icon.ts:32` | fixed |
| F-08 | low | `src/util.ts:93`, `src/page.ts:278`, `web/_headers` | fixed |
| F-09 | low | `src/machines.ts:99` | fixed |
| F-10 | low | `src/intake-routes.ts:50`, `src/intake-routes.ts:62` | follow-up (documented) |
| F-11 | low | `src/trackers.ts:50`, `src/trackers.ts:161` | follow-up |
| F-12 | low | `src/setup.ts:81`, `src/settings.ts:56` | follow-up |
| F-13 | low | `src/index.ts:46`, `src/util.ts:28` | follow-up |
| F-14 | low | `src/secrets.ts:24`, `src/settings.ts:12` | follow-up (documented) |
| F-15 | info | `src/util.ts:124`, `src/index.ts:75`, `src/auth.ts:91` | no change |
| F-16 | info | `src/auth.ts:186`, `src/auth.ts:33`, `src/auth.ts:52` | no change |
| F-17 | info | `src/page.ts:12`, `src/setup.ts` | no change |
| F-18 | info | `src/setup.ts:224`, `src/setup.ts:101` | no change |
| F-19 | info | `src/secrets.ts:37`, `src/secrets.ts:86` | no change |
| F-20 | info | `src/attachments.ts:17`, `src/attachments.ts:45` | no change |
| F-21 | info | `src/trackers.ts:94`, `src/trackers.ts:144` | no change |

### F-01 · high · `/releases/` served attachments without sign-in, as live HTML — fixed

**Where:** `src/releases.ts:16` (`SAFE_PATH`), reached from `src/index.ts:60` before any member check.

Attachments, proofs and the icon live in the same R2 bucket as runner releases (`attachments/<uuid>/<name>`,
`icon/<uuid>`). `release()` served any key that matched `SAFE_PATH`, including those, with the content
type the uploader chose and none of the sandbox headers `attachments.ts` adds.

**Impact:** anyone with an attachment's link could fetch it without signing in, from public
`/releases/attachments/…`. Worse, a member could upload `x.html` as `text/html` and send a teammate
`https://<factory>/releases/attachments/<id>/x.html`. It ran as script on the factory's own origin, where
`sameOrigin` passes and the session cookie goes along, so it could act as whoever opened it (an admin:
repo secrets, the risk policy, removing machines). Confirmed against `wrangler dev` before the fix: the
GET returned `200 Content-Type: text/html` and the `<script>` body, with no CSP.

**Fix:** `SAFE_PATH` refuses keys under `attachments/` and `icon/`; those are served only by their own
routes. Release responses also send `x-content-type-options: nosniff`. Tests:
`test/security.test.ts` ("/releases/ serves release files from the bucket, never attachments or the
icon"), and `test/e2e-attachments.mjs` checks `/releases/attachments/…` is 404 on `wrangler dev`.

### F-02 · high · Any member can watch and type into any machine's terminal — follow-up

**Where:** `src/index.ts:98` (`/client/terminal` checks only that the caller is a member),
`src/machine-hub.ts:110` (`acceptViewer` takes any viewer), `src/machine-hub.ts:152` (a viewer's
binary frames go to the runner as keystrokes).

The org hub limits starting and killing sessions to the machine's owner or an admin
(`src/org-hub.ts:418`). The terminal socket has no such check: any member who knows a machine id and a
live session id (both in the feed every member gets) can attach, read the scrollback, and type.

**Impact:** a member can run commands on a teammate's own computer, as that teammate, through an agent's
shell. The machine's owner may not intend that, even inside one org.

**Follow-up:** decide who may attach. Probably the machine's owner, admins, and the members whose task
the session belongs to (a team slot), with read-only for anyone else. Then check it in `index.ts`
before forwarding, or pass the member's role to `MachineHub /view` and drop input frames from read-only
viewers. Not changed here: it's a product decision (team slots, pairing on a task), and it touches the
web app and the Mac app.

> **Since merging main (2026-10-30):** main now gates the terminal socket and keeps per-session shares (commits 71fbf3f, 3331c64): watch-only viewers' input is dropped and resizing needs the owner or an admin. This audit hasn't re-reviewed that gate, so F-02 stays a follow-up to verify.

### F-03 · medium · Removed org members keep access until their session or token expires — follow-up

**Where:** `src/auth.ts:64` (`stillAllowed` re-checks only personal factories), `src/auth.ts:11-12`
(sessions 7 days, app tokens 30 days).

Org membership and role are checked with GitHub only at sign-in. Afterwards `currentMember` trusts the
`members` row.

**Impact:** someone removed from the org, or demoted from admin, keeps their access (and admin powers)
for up to 7 days on the web and 30 days in the apps.

**Follow-up:** re-check membership periodically, for example a scheduled job (the org hub's alarm) that
lists the org's members with the app's installation token and deletes the rows and app tokens of anyone
gone. Then `currentMember`'s join fails at once. The GitHub App could also subscribe to `organization`
`member_removed` events at `/integrations/github`. Sessions should carry something revocable, such as a
per-member generation number in `members`, so deleting or bumping it signs every browser out.

> **Since merging main (2026-10-30):** main now re-checks membership every 10 minutes, and `members.revoke` / `revoked_at` cut off sessions, app tokens and runner tokens issued before a revocation (commits 273afc3, df6dcb2, 3331c64). `authenticateRunner` now combines that check with this task's constant-time compare (F-09). This audit hasn't re-reviewed the change, so F-03 stays a follow-up to verify.

### F-04 · medium · App tokens can't be revoked, and signing out doesn't revoke them — follow-up

**Where:** `src/auth.ts:12` (30-day lifetime), `src/auth.ts:176` (`/auth/logout` only clears the
cookie). No route deletes from `app_tokens`.

**Impact:** a leaked `mft_…` token (a copied config, a lost laptop) works for 30 days and nobody can
stop it, short of editing D1 by hand. Web sessions are the same for 7 days (stateless HMAC cookies).

**Follow-up:** `DELETE /api/tokens/current` for the apps' sign-out, a list of a member's tokens with
"revoke" in the web app (`label` and `last_used` are already stored), and admin revocation of another
member's tokens (pairs with F-03). Consider a sliding expiry on `last_used` instead of a fixed 30 days.

### F-05 · medium · Intake `replyUrl` let callers make the Worker POST anywhere — fixed

**Where:** `src/intake-routes.ts:23` (`replyAllowed`, new), used at `src/intake-routes.ts:56`. The POST
itself is `src/trackers.ts:152` (`deliver`).

`/api/intake` took any `https://` `replyUrl` from an intake-key holder or any member. The factory then
POSTs every bot reply about that request there.

**Impact:** SSRF-lite. The factory could be pointed at any HTTPS endpoint (an internal service behind
Cloudflare Access that trusts this Worker, or someone else's webhook) and made to send JSON to it
repeatedly, with the request's thread as content.

**Fix:** an API request's `replyUrl` must be `https:`, have no credentials, and name `hooks.slack.com`
or a host in the new `INTAKE_REPLY_HOSTS` variable (comma or space separated). Slack's own slash
command still uses its signed `response_url`; Linear and Jira replies use `linear:`/`jira:` addresses,
not URLs. Tests: `test/security.test.ts` (two intake tests: refused hosts including
`hooks.slack.com.evil.example` and `http://`, and allowed ones), and `test/e2e-intake.mjs`.

### F-06 · medium · The Jira webhook secret travels in the query string — follow-up

**Where:** `src/trackers.ts:84`.

Jira Cloud's legacy webhooks can't sign, so the secret is `?secret=` in the URL.

**Impact:** URLs end up in Cloudflare's request logs, Workers Logs/Logpush, any proxy's logs, and Jira's
admin UI. Anyone who can read those can forge Jira events: made-up requests and comments in request
threads. The bot's replies still go only to `JIRA_SITE` (checked in `deliver`), so the API token doesn't
leak.

**Follow-up:** support Jira's signed webhooks (the admin-registered webhook's secret, sent as
`X-Hub-Signature: sha256=…`) and prefer them when configured. Until then, document that the URL is a
secret and that Logpush shouldn't capture query strings for this path.

### F-07 · low · Uploads without content-length were read in full before the size check — fixed

**Where:** `src/attachments.ts:32` (attachments), `src/attachments.ts:103` (proofs), `src/icon.ts:32`
(icon).

Each handler compared `content-length` with its limit, then `await request.arrayBuffer()`. A chunked
upload has no `content-length`, so the whole body was buffered first: up to the Worker's request limit
(100 MB+) into a 128 MB isolate.

**Impact:** a member (or a runner) could crash isolates with oversized uploads; memory pressure for
other requests on the same isolate.

**Fix:** `readCapped` (`src/util.ts`) reads the stream and cancels it as soon as it passes the limit
(null → 413). The icon's "too big" is now 413 instead of 400, like the others (`test/e2e-icon.mjs`
updated). Tests: `test/security.test.ts` (one per upload, each streaming 30–60 MB without
content-length and checking 413 after reading no more than the limit plus a chunk), and
`test/e2e-attachments.mjs` (a chunked 30 MB upload gets 413 on `wrangler dev`).

### F-08 · low · No clickjacking or referrer protection on HTML pages — fixed

**Where:** `src/util.ts:93` (`PAGE_HEADERS`, `html()`), used by `src/page.ts:278` for `/`, `/setup`,
`/setup/done` and `/t/<id>`. The web app's static files get the same headers from `web/_headers`.

**Impact:** any site could frame the factory's pages. The home page's "Add a machine" and setup's
"Create the GitHub App" could be clickjacked. The impact is small: an enrollment code made this way
isn't shown to the attacker.

**Fix:** every page sends `Content-Security-Policy: frame-ancestors 'none'`, `X-Frame-Options: DENY`,
`X-Content-Type-Options: nosniff` and `Referrer-Policy: same-origin`. Tests: `test/security.test.ts`
("HTML pages can't be framed…"), `test/e2e-setup.mjs` checks them on `/setup`, and `curl -I` on
`wrangler dev` shows them on `/`, `/setup` and `/app/`. A full script CSP for the pages and the web app
is a reasonable next step, but the pages use inline scripts, so it needs nonces or hashes (follow-up).

### F-09 · low · Runner tokens compared with `===` — fixed

**Where:** `src/machines.ts:99`.

The stored SHA-256 hex was compared with `===`. Timing on a comparison of hashes isn't practically
exploitable (an attacker would need preimages to steer the hash), but every other secret here is
compared in constant time.

**Fix:** `sameText` moved to `src/util.ts` and is used for runner tokens. `trackers.ts` and
`intake-routes.ts` drop their copies of it. Test: `test/security.test.ts` (right/wrong/missing tokens,
and `sameText` reads every character whether the first difference is at the start or the end).

### F-10 · low · Intake-key callers name the requester and author themselves — follow-up (documented)

**Where:** `src/intake-routes.ts:62` (`requester`), `src/intake-routes.ts:50` (a message's `author`).

With the intake key, `requester` and `author` are whatever the caller says; with a member's token
they're the member's login. This is by design: a support tool posts on behalf of customers. But anyone
with the key can put words in any name, and the app shows them like a person's.

**Follow-up:** show API-sourced names as "via API" in the app, and/or let one key per integration be
issued with a fixed source name, so a leaked key is attributable and revocable on its own.

### F-11 · low · Replay windows for Linear and GitHub webhooks — follow-up

**Where:** `src/trackers.ts:50` (Linear: the 60 s window applies only when `webhookTimestamp` is
present), `src/trackers.ts:161` (GitHub: signature only, no delivery-id dedupe).

**Impact:** a captured, validly signed delivery can be replayed. For Linear only if it lacks a
timestamp, which current Linear deliveries always carry. GitHub events only trigger re-checks and repo
refreshes, which are idempotent. Slack's 5-minute window (`src/intake-routes.ts`) is Slack's own
recommendation.

**Follow-up:** require `webhookTimestamp` for Linear, and remember recent `X-GitHub-Delivery` ids for a
few minutes.

### F-12 · low · The first `/setup` visits race on `SESSION_SECRET` — follow-up

**Where:** `src/setup.ts:81` (`sessionSecret`), `src/settings.ts:56` (`ON CONFLICT … DO UPDATE`).

Two first visits at once each generate a secret, and the second write replaces the first. Unlike
`secretsKey`, which uses `DO NOTHING`, this one overwrites.

**Impact:** the first visitor's setup state stops verifying ("That setup link expired…"). It's a
nuisance, not a takeover: finishing setup still needs an app owned by `GITHUB_ORG` (F-18).

**Follow-up:** insert `SESSION_SECRET` with `ON CONFLICT DO NOTHING` and re-read, as `secretsKey` does.

### F-13 · low · `/runner/enroll` has no rate limit — follow-up

**Where:** `src/index.ts:46`, codes from `src/util.ts:28`.

Codes have 8 characters from a 31-letter alphabet (about 2^39.6, with a slight modulo bias), last 15
minutes, and work once. Guessing one online is impractical, but nothing slows a guesser down.

**Follow-up:** a Workers rate-limiting binding (per IP) on `/runner/enroll`, and also on `/auth/device/poll`.

### F-14 · low · Secrets at rest sit in D1 in plain text — follow-up (documented)

**Where:** `src/settings.ts:12` (`GITHUB_CLIENT_SECRET`, `GITHUB_APP_PRIVATE_KEY`,
`GITHUB_WEBHOOK_SECRET`, `SESSION_SECRET`), `src/secrets.ts:24` (a generated `SECRETS_KEY` in the same
table).

A factory made with the Deploy button can't set Worker secrets on itself, so `/setup` keeps them in D1.
Repo secrets are encrypted in the org hub's storage, but under a key that, unless it's a Worker secret,
sits in D1 too.

**Impact:** anyone who can read this D1 database (account members with D1 access, a leaked API token
with D1 read) gets the GitHub App's private key and can mint session cookies.

**Follow-up:** after setup, offer a one-time "move these to Worker secrets" step (`maple install` can
do it), and say in the README that D1 access equals factory admin.

### F-15 · info · DEV_LOGIN and the `/dev/*` routes — no change

**Where:** `src/util.ts:124` (`isLocal`), `src/index.ts:75`, `src/auth.ts:91`.

These are gated on `DEV_LOGIN` and on `request.url`'s hostname being `localhost`/`127.0.0.1`. On
Cloudflare, `request.url`'s host is the hostname the request was routed for. A `Host: localhost`
header sent to `*.workers.dev` or a custom domain doesn't reach this Worker, so it can't be spoofed
there. The remaining risk is someone setting `DEV_LOGIN` on a deployed factory. It only appears in
`.dev.vars`, and `keep_vars` wouldn't add it. Optionally, refuse to honor it when `PUBLIC_URL` is
`https:`.

### F-16 · info · OAuth state, `next`, cookies and origin checks — no change

**Where:** `src/auth.ts:186`, `src/auth.ts:33`, `src/auth.ts:52`.

The OAuth state is HMAC-signed with a 10-minute expiry, tied to an `HttpOnly` cookie and cleared after
use. `next` must start with exactly one `/` and contain only `[\w\-./#?=&%]`: no `//`, no `\`, no
scheme. So it can't leave the site. Cookies are `HttpOnly; SameSite=Lax`, plus `Secure` and the
`__Host-` prefix on https. `verify` uses `crypto.subtle.verify` (constant time). `sameOrigin` lets
requests without `Origin` through. That's safe, because browsers send `Origin` on cross-site POSTs and
on every WebSocket, and `SameSite=Lax` keeps the cookie off cross-site subrequests.

### F-17 · info · HTML escaping — no change

**Where:** `src/page.ts:12` (`escape`), `src/setup.ts`.

Every value interpolated into pages is escaped, or fixed by a pattern (task ids, the org, the member's
login and role, the app slug, the host). Attributes are all double-quoted, so not escaping `'` is fine.
The values put into inline `<script>` with `JSON.stringify` are server-made (a hex id, URLs built with
`encodeURIComponent`), never request input. No XSS found.

### F-18 · info · No first-come takeover of `/setup` — no change

**Where:** `src/setup.ts:224`, `src/setup.ts:101`.

Anyone can open `/setup` before it's done, but the app GitHub hands back must be owned by `GITHUB_ORG`,
and only that org's owners or app managers can create one there. The manifest code is single-use, and
the state is signed and tied to a cookie. `/setup/id` is public with CORS `*` by design: it's 64 bits
of a hash of `SESSION_SECRET`, which shows nothing about it.

### F-19 · info · Repo secrets' encryption — no change

**Where:** `src/secrets.ts:37`, `src/secrets.ts:86`.

HKDF-SHA256 from `SECRETS_KEY` (fixed salt and info, which is fine for a high-entropy input key), then
AES-256-GCM with a fresh random 96-bit IV per write and `repo\nname` as additional data. IVs aren't
reused in practice (random, and well under 2^32 writes per key). Values never go to the apps.

### F-20 · info · Serving attachments — no change

**Where:** `src/attachments.ts:17`, `src/attachments.ts:45`.

Files are sent with `Content-Security-Policy: sandbox; default-src 'none'`, `nosniff`, and `inline`
only for an image/text/PDF/video allowlist (anything else downloads). Filenames in
`Content-Disposition` are limited to `[\w.\-]`. R2 keys are `attachments/<uuid>/<storedName>`;
`storedName` refuses `/`, `\`, NUL and `..`. The release path (`SAFE_PATH`) and `/dev/releases` refuse
`..`, and the icon id must be a UUID. The one hole was F-01.

### F-21 · info · Jira replies only go to the configured site — no change

**Where:** `src/trackers.ts:94`, `src/trackers.ts:144`.

`deliver` sends the Jira API token only when the reply's site equals `JIRA_SITE`'s origin, and the
webhook refuses issues from other sites when `JIRA_SITE` is set. Linear replies go to the fixed Linear
API. A malformed `issue.self` throws, and the request gets a 500, not a crash of anything shared.

## Verification

- `npm run typecheck` and `npm test` (55 tests, including `test/security.test.ts`) pass.
- Against `wrangler dev`: `e2e-local` (a real runner), `e2e-setup` (fake GitHub, fresh D1),
  `e2e-attachments` (with the `factory.test` upstream for anonymous checks), `e2e-intake`,
  `e2e-trackers` and `e2e-icon` pass.
- `curl -I` shows the new headers on `/`, `/setup` and `/app/`; unauthenticated `/api/*` is still 401.

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
| `/client/terminal?machine=&session=` | WebSocket | member (any member, any machine — see F-03) | → `MachineHub /view` |
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

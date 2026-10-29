# Maple Factory server

One org's factory, in that org's own Cloudflare account: a Worker with two Durable Objects (OrgHub,
MachineHub), a D1 database, an R2 bucket and the web companion's static files. Runners on the
team's machines dial out to it; the Mac app and the web companion sign in to it with GitHub.

**Before the button, switch R2 on** in the account ([R2 in the dashboard](https://dash.cloudflare.com/?to=/:account/r2/overview)):
it's off until someone does, Cloudflare asks for a payment method even for the free tier, and the
deploy fails without it. (`maple install` checks and waits for you.)

[![Deploy to Cloudflare](https://deploy.workers.cloudflare.com/button)](https://deploy.workers.cloudflare.com/?url=https://github.com/Maple-Factory-Dev/maple-factory/tree/main/server)

## Deploy

Either way, you end up with the factory at a URL in your account and finish at its `/setup`.

- **The button** (above, or maplefactory.dev/deploy, which asks for R2 first) copies this folder into a
  repo of yours, creates the D1 database, R2 bucket and Durable Objects, asks for `GITHUB_ORG`, and
  deploys with Workers Builds (`npm run deploy` applies the D1 migrations first). Your copy has nothing
  tying it back here, so its **Maple Factory update** workflow (`.github/workflows/maple-update.yml`) checks
  maplefactory.dev's feed once a day and, when there's a newer maple-server, opens a pull request that
  brings in that release (`scripts/update.mjs`, keeping your wrangler.jsonc values); merging it redeploys.
  If GitHub won't let Actions open pull requests in your repo, it opens an issue with the link instead.
- **`npx maple-factory install`** deploys the signed release from maplefactory.dev instead, with a
  custom domain if you give it one, and `maple update` moves it to the next stable or beta release.
  See [installer/](../installer).

Then an owner of the GitHub org opens `https://<factory>/setup`. (`GITHUB_ORG` can also be your own
username: the app is then yours, and you're its admin.)

`GITHUB_ALLOWED_LOGINS` lets other GitHub logins in as members, comma separated (`octocat, hubot`): collaborators
on your own account's factory, or people outside the org. With the button, add it in the Cloudflare dashboard
(the Worker → Settings → Variables and Secrets; it stays across pushes); with `maple install`, pass `--allow` (and `maple update --allow` to change it). On a personal account's factory,
taking someone off signs them out at once; on an org's, it takes effect when they next sign in, like leaving the org. GitHub creates the factory's GitHub App
from a manifest (sign-in, task branches and pull requests) and hands its credentials back. They're
kept in D1, since a Worker can't set its own secrets. After installing the app, tick **Enable Device
Flow** in its settings for the Mac app's sign-in; GitHub doesn't allow that from a manifest. Only an
app owned by `GITHUB_ORG` is accepted, and once sign-in works, `/setup` changes nothing.

Worker secrets of the same names (`GITHUB_APP_ID`, `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`,
`GITHUB_APP_PRIVATE_KEY`, `GITHUB_WEBHOOK_SECRET`, `SESSION_SECRET`, `SECRETS_KEY`) take precedence over what `/setup` stored.

### Repo secrets and SECRETS_KEY

Admins keep per-repo secrets in Settings → Secrets (names, who changed them and when; values are never
shown again). They live in OrgHub's SQLite, each value sealed with AES-GCM (a fresh IV, the repo and name
as additional data) under a key derived with HKDF from `SECRETS_KEY`. A runner gets a repo's values only
for a planning, building or reviewing task assigned to it, as environment variables in the task's sessions, or with
`maple-runner secrets pull` in its owner's checkout (into a gitignored `.env.local`, mode 0600). Every
change and every release is in the D1 `audit` table (`secret.set`, `secret.deleted`, `secret.pulled`),
by name only.

What that does and doesn't guard on a runner's machine:

- A task's agent has its own repo's values in its environment, so it can read them; scrubbing only keeps
  them out of what the runner sends the factory (logs, proofs, last output).
- `secrets pull` asks the runner over its local socket, which every session can reach. The runner refuses
  a request from a process inside one of its sessions (it walks up from the asking process to the
  session's pane), so an agent can't pull another repo's values. Run `secrets pull` from your own
  terminal. A process that detaches itself from its session can get past that check: the socket is as
  private as the user account the runner runs as, and anything running as that user can read the values.
- The tmux command that starts a session with secrets goes on tmux's stdin, not its arguments, so other
  users on the machine can't see the values with `ps`.

`SECRETS_KEY` is a Worker secret when you set one; otherwise `/setup` (or the first secret saved) generates
one into D1's `settings` table and never replaces it. **Back it up**: without it no stored value can be
read. Read it with
`npx wrangler d1 execute maple --remote --command "SELECT value FROM settings WHERE key = 'SECRETS_KEY'"`
and keep it in your password manager (or set the same value as a Worker secret with
`npx wrangler secret put SECRETS_KEY`). Restoring a factory means restoring that value with its data.

**Rotating** it re-encrypts nothing on its own: a different key makes every stored value unreadable (a
runner's pull then says the factory couldn't decrypt them). To rotate, note the names in Settings →
Secrets, set the new key (`npx wrangler secret put SECRETS_KEY`, or replace the `settings` row), then
Replace each secret with its value, which seals it under the new key. Rotate when someone who could read
the key (a Cloudflare account admin) leaves, and rotate the secrets themselves at their source, since
anyone who pulled them keeps a copy.

Admins see when a newer maple-server is out, and how this factory gets it, on the home page, `/setup` and
the Mac app's Account settings. `/healthz` says which version is running.

## Runners

`/install.sh` and every runner's self-update get maple-runner from `/releases/`, which serves
maplefactory.dev's signed builds for macOS and Linux on `RELEASE_CHANNEL` (`stable` or `beta`).
Runners only install a release signed with the key built into them, so the feed passing through the
factory can't be used to push anything else.

To run your own runner builds, build them with your own release key (`RELEASE_PUBLIC_KEY` in
runner/src/update.rs) and upload them to the factory's bucket (`RELEASES`) with
`node scripts/release-runner.mjs --to factory`. What's in the bucket wins over the feed.
`RELEASE_FEED=off` serves only the bucket.

## Develop

```sh
npm run dev          # migrations on the local D1, then wrangler dev on :8788
npm run typecheck
```

`.dev.vars` holds local settings: `DEV_LOGIN=<your GitHub login>` signs localhost in without GitHub,
`GITHUB_ORG`, `PUBLIC_URL=http://localhost:8788`, and optionally the GitHub App and the tracker secrets
(`INTAKE_KEY`, `SLACK_SIGNING_SECRET`, `LINEAR_*`, `JIRA_*`). `INTAKE_KEY` (`mfi_…`) is the Bearer key for posting
requests to /api/intake; `SLACK_SIGNING_SECRET` verifies Slack's /maple. `scripts/dev-stack.sh up` writes a
starter `.dev.vars`. There's deliberately no `.dev.vars.example`: the Deploy to Cloudflare button would ask for
everything in it. End-to-end tests are in test/; each says what it needs at the top.

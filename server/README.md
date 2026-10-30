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
for a planning, building or reviewing task assigned to it, as environment variables in the task's sessions, or,
when its owner is an org admin, with `maple-runner secrets pull` in their checkout (into a gitignored `.env.local`,
mode 0600). A member's machine can't pull: ask an admin, or let a task use them. Every
change and every release is in the D1 `audit` table (`secret.set`, `secret.deleted`, `secret.pulled`),
by name only.

What that does and doesn't guard on a runner's machine:

- A task's agent has its own repo's values in its environment, so it can read them; scrubbing only keeps
  them out of what the runner sends the factory (logs, proofs, last output, the terminal stream and its
  replays).
- Scrubbing replaces a value only as it is: values shorter than 6 characters aren't scrubbed at all, and
  neither is an encoded form of one (base64, URL-encoded, quoted with escapes, or split up by the agent).
- The values reach a session through a one-shot file (mode 0600, in `~/.config/maple/secrets/`, never the
  worktree) that the pane's shell reads and deletes before it starts the agent. They're in the pane's
  processes only, not tmux's session environment, which any client of the runner's tmux server could read.
  Anything running as the same user account can still read a process's environment.
- The factory hands values to a task-less request (`secrets pull`) only when the machine's owner is an org
  admin. The runner also refuses a pull from a process inside one of its sessions (it walks up from the
  asking process to the session's pane), but a process that detaches itself, or reads the runner's token,
  gets past that; the admin check on the factory is what stops an agent on a member's machine.

`SECRETS_KEY` is a Worker secret when you set one; otherwise `/setup` (or the first secret saved) generates
one into D1's `settings` table and never replaces it. **Back it up**: without it no stored value can be
read. Read it with
`npx wrangler d1 execute maple --remote --command "SELECT value FROM settings WHERE key = 'SECRETS_KEY'"`
and keep it in your password manager (or set the same value as a Worker secret with
`npx wrangler secret put SECRETS_KEY`). Restoring a factory means restoring that value with its data.

**Changing or losing it loses every stored value**: nothing re-encrypts them, so a different key makes all
of them unreadable (a runner's pull then says the factory couldn't decrypt them) and each has to be set
again. To rotate, note the names in Settings →
Secrets, set the new key (`npx wrangler secret put SECRETS_KEY`, or replace the `settings` row), then
Replace each secret with its value, which seals it under the new key. Rotate when someone who could read
the key (a Cloudflare account admin) leaves, and rotate the secrets themselves at their source, since
anyone who pulled them keeps a copy.

### Worktree scripts

Teams with their own scripts for making and cleaning up worktrees set them per repo in Settings →
Repositories (click a repo). There are four, each optional, each a shell command of at most 4 KB:

- **create** makes the task's worktree instead of the runner's `git worktree add`. It must leave a git
  worktree on `$MAPLE_BRANCH` at `$MAPLE_WORKTREE`, or the task fails to start.
- **setup** runs once the worktree exists (whichever made it), before the agent starts.
- **teardown** runs before a finished task's worktree is removed (merged, or cancelled with "clean up").
- **archive** runs instead of the runner's removal: the script owns the folder and the branch.

The runner runs each with `sh -c` in the repo's main checkout, with the login shell's PATH, the repo's
secrets and `MAPLE_REPO`, `MAPLE_REPO_ROOT`, `MAPLE_WORKTREE`, `MAPLE_BRANCH`, `MAPLE_BASE`,
`MAPLE_TASK_ID` and `MAPLE_PHASE` (create, setup, teardown or archive). Each may run for the repo's
timeout (10 minutes unless set), in a process group that's killed when it ends. A script that fails stops
what it was part of: a failed create or setup removes the half-made worktree (and the branch, if it made
one) and the task's session doesn't start, with the end of the script's output (secret values scrubbed)
as the reason; a failed teardown leaves the worktree as it is. Each run is a line on the task's timeline.
Only admins change them (`repo.scripts` in the audit, naming which ones changed); everyone sees them.

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
requests to /api/intake; a request's `replyUrl` must be on hooks.slack.com or a host in `INTAKE_REPLY_HOSTS`. `SLACK_SIGNING_SECRET` verifies Slack's /maple. `scripts/dev-stack.sh up` writes a
starter `.dev.vars`. There's deliberately no `.dev.vars.example`: the Deploy to Cloudflare button would ask for
everything in it. End-to-end tests are in test/; each says what it needs at the top.

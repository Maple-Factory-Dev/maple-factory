# maple-factory

A software factory for teams: agents plan, build, review and prove work on the team's own machines,
and people approve, steer and merge from a native macOS app (web companion, iOS later).

Successor to `~/Projects/agent-orchestrator`, keeping what worked (easy runners, the task process,
web and phone access, Tailscale) and fixing what didn't (sessions dying for no clear reason, no multiplayer).

```
apps/mac/     SwiftUI app: the factory (goals, tasks, review, machines, requests, usage), live against a server; the design mockup when signed out
runner/       maple-runner (Rust): sessions in tmux, dials out to the server. From ao-runner 0.23.0
server/       Cloudflare Worker: OrgHub + MachineHub Durable Objects, D1, R2; the factory each org deploys
installer/    `maple` (npm: maple-factory): install and update a factory in an org's Cloudflare account
apps/site/    maplefactory.dev: the site, the signed release feed (/releases/) and /deploy
protocol/     schema.ts → generated Rust, TypeScript and Swift types (npm run gen)
assets/       app icon source
```

Planned: `apps/web/` (companion).
scripts/dev-stack.sh runs a local factory to click around in.

## Develop

```sh
npm install
npm run gen                 # after editing protocol/schema.ts (gen:check fails when stale)
scripts/dev-stack.sh up     # server on :8788 (signed in as DEV_LOGIN) + a throwaway runner `dev-mac` in /tmp/mfh
cd apps/mac && swift run    # then Connect to Another Factory… → localhost:8788 → Continue as @you
apps/mac/scripts/bundle.sh  # → apps/mac/build/Maple Factory.app (registers maplefactory:// task links; SIGN_IDENTITY to sign)
scripts/dev-stack.sh down
```

Signed in, the Mac app is the live factory: tasks run through planning, approval, building, review and
merge on enrolled machines, with terminals through the relay. Signed out, it's the design mockup.
On a phone or any browser, `/app` is the web companion: the inbox and task pages (plan, mockups,
diff, review, checks, proofs) with approve, request changes, merge and answers to agents; no terminals
or machine settings. Task links (`/t/<ID>`) open the Mac app and fall back to it.
End-to-end tests for each piece are in server/test (each says what it needs at the top). Launch flags for screenshots: `-onboardingURL localhost:8788
-onboardingContinue YES` plays the real sign-in; `-destination machines -liveSession first` opens a terminal.

Server tests: `node server/test/e2e-local.mjs http://localhost:8788 dev-mac` (relay, Kill, exit causes).
Runner tests: `cd runner && cargo test`.

## Deploying a factory

Each org runs its own factory in its own Cloudflare account, one of two ways:

- the **Deploy to Cloudflare** button (maplefactory.dev/deploy, or server/README.md), which builds `server/`
  from the public repo into a copy of the org's own. R2 has to be switched on in the account first, and
  the button can't check, so /deploy asks before it sends anyone on; or
- **`npx maple-factory install`**, which deploys the signed server release from the feed and updates it
  with `maple update` on the stable or beta channel. When R2 is off (Cloudflare's error 10042) it links
  to the dashboard and waits.

Both finish at the factory's `/setup`, where an owner of the GitHub org (or the person, when `GITHUB_ORG` is
a personal account and the factory is just theirs) creates the factory's GitHub App
from a manifest; its credentials are kept in D1 (server/src/settings.ts). See server/README.md.

## Releases

maplefactory.dev serves one signed feed at `/releases/` (apps/site/worker.js, from the
`maplefactory-releases` bucket): `maple-runner/` and `maple-server/`, each with `latest.json` (stable)
and `beta.json`, signed with the release key. Factories pass the runner feed through at their own
`/releases/` (server/src/releases.ts), so runners need nothing from maplefactory.dev directly; an org's
own runner builds in the factory's bucket take precedence.

```sh
node scripts/release-runner.mjs --new-key                    # once; the key lives in ~/.config/maple-factory/, back it up
SIGN_IDENTITY=… node scripts/release-runner.mjs --to feed [--channel beta]   # every target (Linux needs Docker)
node scripts/release-server.mjs --to feed [--channel beta]   # the server bundle `maple install` deploys; tags server-v<version>,
                                                            # which button factories' update workflow pulls
node scripts/release-runner.mjs --to dir:/tmp/feed           # or a local folder laid out like the feed
```

`--to factory` uploads to one factory's own bucket instead, and `--local` to `wrangler dev`'s. The site deploys with `cd apps/site && npx wrangler deploy`.

## Runner install

Adding a machine is one line from Machines → Add machine: `curl -fsSL https://<factory>/install.sh | sh -s -- CODE`.
The script picks the build for the machine (macOS or Linux, arm64 or x86_64), checks it against the
release manifest's sha256, enrolls the machine and starts the runner at login (launchd or systemd).
Runners then update themselves, trusting only manifests signed with the release key.

On a Mac it's one click instead: Add machine → Add this Mac runs the same steps with the runner and
tmux the app carries (`Contents/Helpers`, universal; tmux is built without Homebrew by
`apps/mac/scripts/build-tmux.sh`). `apps/mac/scripts/dmg.sh` makes the download, signed and notarized
when `SIGN_IDENTITY` and `NOTARY_PROFILE` are set.

Set `PUBLIC_URL=http://localhost:8788` in `.dev.vars` locally: `wrangler dev` hides the port from the Worker.

## GitHub App

With an app, runners fetch and push tasks' branches with short-lived, single-repo installation tokens,
and the factory opens each task's pull request, waits for its CI (failed checks can be run again from
the app), squash-merges it, and closes it if the task is cancelled. Without one, tasks push with the
machine's own credentials and merge locally. Set on the server:

```sh
GITHUB_APP_ID=…              # or the app's Client ID
GITHUB_APP_PRIVATE_KEY=…     # the PEM GitHub gives you (literal \n is fine)
GITHUB_WEBHOOK_SECRET=…      # webhook URL: https://<factory>/integrations/github
```

The app needs Contents, Pull requests, Checks and Actions (read & write) and Commit statuses (read), and
webhook events Check run, Check suite, Status and Pull request. `server/test/e2e-github.mjs` runs the
whole path against `server/test/fake-github.mjs`.

## How sessions end

Every end carries a cause (`EndCause` in protocol/schema.ts) and the last 30 lines of screen, stored in
`session_ends`. The runner (runner/src/ends.rs) only ends a session on what tmux reports: an unreachable
server is never "no sessions", a missing session must be missing for 3 polls, and a deleted socket is
recreated (SIGUSR1). The socket lives in `~/.config/maple/tmux/`, not `/tmp`.

## Decisions

- **Domain:** `maplefactory.dev` is the project's own: site, docs, the installer download and the signed release feed for
  servers and runners. Each org's factory runs on a domain in its own Cloudflare account.
- **Hosting:** each org deploys into its own Cloudflare account, one deploy per org, with teams inside it.
- **Installer:** takes a scoped Cloudflare API token, provisions everything, runs migrations, and ships
  signed server and runner updates on a stable or beta channel.
- **Identity:** a GitHub App on the org; org membership and teams decide access and roles.
- **Tailscale:** strongly integrated for previews, port sharing and share links.
- **Relay:** terminal and session bytes always go through the org's Cloudflare relay.
- **Clients:** native macOS first, with a web/PWA companion (inbox, answers, approvals, review, live terminal).
- **Model accounts:** each person's own Claude Code or Codex login on their machine. Team slots spend the
  machine owner's plan, within their usage caps.
- **Planner and reviewer:** run as sessions on runners, so they follow the org's model and provider choices.
- **Durability:** the task is the durable record and sessions are disposable. Every session end is recorded
  with a cause. Transient causes (sleep, runner update, network) resume from the last checkpoint; anything
  else raises a hand.

## First milestone

Both of Andrea's machines working end to end:

1. `maple install` sets up the org's Cloudflare, then GitHub org sign-in, then the machines enroll and a
   live session opens in the Mac app.
2. One task goes plan, approve, build, review and merge, with recovery that depends on the cause.

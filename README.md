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
-onboardingContinue YES` plays the real sign-in (`-devAs <login>` as a member); `-destination machines -liveSession first` opens a terminal.

### Testing without taking over the screen

Someone is usually working on the Mac the factory builds on, so agents check the app headless instead of
launching it in the foreground or using `screencapture`. `scripts/headless.sh` runs the app as a background
app: no Dock icon, never activated, its window off screen, rendered to PNGs once the launch flags and
`-actions` script have played. It keeps its own defaults (and its tokens out of the keychain), so it can't
sign the real app out or move its sidebar.

```sh
scripts/headless.sh shot /tmp/out -destination inbox -actions 'approve:ATL-147; shot:approved'  # inbox.png, approved.png
scripts/headless.sh shot /tmp/out -destination "Auth overhaul" -layout list -task ATL-147 -appearance both
scripts/headless.sh video /tmp/approve.mp4 -actions 'approve:ATL-147; wait:2'   # -frames/-fps; needs ffmpeg
scripts/headless.sh stack up        # an isolated dev stack: MAPLE_DEV_INSTANCE=agent, its own port, home and runner
scripts/headless.sh live /tmp/out -destination machines   # signed in to that stack
scripts/headless.sh stack down      # stops only that stack, never `dev` or a real maple-runner
```

`shot:<name>` in a script takes a frame between actions, once anything still in flight (a demo approve
holds its button busy for a moment) has landed; `-settle`, `-timeout` (60s; a timeout writes
timeout.png and exits 1), `-width`/`-height` and `-name` tune a run. Every result is listed in `<out>/done.json`.
Any `MAPLE_DEV_INSTANCE` other than `dev` gives `scripts/dev-stack.sh` a separate stack in the same way.
`down` stops what `up` recorded in its pid files; a stack started before those existed is found by its
port and runner home instead, so a real maple-runner is never matched.

Server tests: `node server/test/e2e-local.mjs http://localhost:8788 dev-mac` (relay, Kill, exit causes).
Runner tests: `cd runner && cargo test`.

### Codex factory approvals

In Settings → Factory, **project** unattended mode launches Codex planners, builders and reviewers
with **Approve for me** on every invocation, including new and retried sessions and resume launches:

```sh
--ask-for-approval on-request -c 'approvals_reviewer="auto_review"' \
  --sandbox workspace-write -c sandbox_workspace_write.network_access=true
```

`on-request` lets Codex request approval, and `auto_review` routes eligible requests, including Maple
reporting tools, to an automatic reviewer. `never` cannot do that: it refuses requests that need
approval. The workspace-write sandbox and existing network access stay in place; automatic review
can approve or deny an escalation. Factory plan approval remains a separate human decision.
These flags follow ordinary `agents.toml` arguments, overriding an earlier `-c` reviewer setting for
that invocation without editing personal Codex configuration. Explicit **ask** and **skip** modes,
personal sessions and other agents keep their existing behavior. Draft with AI uses a separate
read-only execution path and is outside this change.

Checked with Codex CLI 0.164.0. Automatic review must be supported by the installed Codex version and
available to the account; managed organization requirements take precedence over these local
settings. If the mode is unavailable, policy rejects it or review denies a request, inspect the
terminal and resolve that constraint; the runner does not fall back to full access.
See [OpenAI's auto-review documentation](https://learn.chatgpt.com/docs/sandboxing/auto-review).

To smoke-test planning without changing personal Codex settings, use a disposable factory and repo
(requires installed npm dependencies, Rust, tmux and Codex):

1. From this checkout, create the disposable repo and an isolated Codex home, then authenticate that
   home with an account supporting automatic review:

   ```sh
   smoke=$(mktemp -d /tmp/maple-approval-smoke.XXXXXX)
   export CODEX_HOME="$smoke/codex"
   mkdir -p "$CODEX_HOME"
   codex login
   git init -b main "$smoke/repo"
   printf '# Planning smoke check\nOriginal greeting: hello\n' > "$smoke/repo/README.md"
   git -C "$smoke/repo" add README.md
   git -C "$smoke/repo" -c user.name=Smoke -c user.email=smoke@example.test commit -m 'Seed planning fixture'
   git clone --bare "$smoke/repo" "$smoke/origin.git"
   git -C "$smoke/repo" remote add origin "$smoke/origin.git"
   git -C "$smoke/repo" rev-parse HEAD > "$smoke/before-head"
   git -C "$smoke/repo" ls-tree -r HEAD > "$smoke/before-tree"
   export MAPLE_DEV_INSTANCE="approval-smoke-$$"
   scripts/dev-stack.sh up
   scripts/dev-stack.sh port
   ```

2. Connect the Mac app to `localhost:<printed port>` using Continue as the dev user. Add a goal
   pointing at `$smoke/repo` (run `echo "$smoke/repo"` for its full path), base `main`. Leave factory
   unattended mode at **project**. Create a Codex task with planning enabled: “Read README.md and plan changing the
   greeting from hello to welcome; submit the plan without changing files.” Open its terminal and
   capture the repository read and successful `submit_plan`. Check the effective permissions with
   `/status` or `/permissions` if needed: **Approve for me**, `on-request` / `auto_review`, with
   workspace-write. Do not switch permissions manually. Record the task ID, session ID and
   `awaitingApproval` state; leave the plan unapproved so no builder starts.
3. Create a second task with the same brief to check a new planner session. For explicit retry
   coverage, use Retry while that planner is running (after its worktree appears), then capture the
   replacement session ID, effective permissions, repository read, successful plan submission and
   `awaitingApproval`. Each launch must receive the settings automatically. Check both planner
   worktrees with `git -C <worktree> status --porcelain` and `git -C <worktree> diff HEAD --exit-code`;
   both should be empty/clean. Confirm the fixture's HEAD and tree are unchanged:

   ```sh
   test "$(git -C "$smoke/repo" rev-parse HEAD)" = "$(cat "$smoke/before-head")"
   git -C "$smoke/repo" ls-tree -r HEAD > "$smoke/after-tree"
   diff -u "$smoke/before-tree" "$smoke/after-tree"
   git -C "$smoke/repo" status --porcelain
   ```

4. Save task-state and terminal evidence, cancel the disposable tasks and stop only this stack with
   `scripts/dev-stack.sh down`. Unset `CODEX_HOME` and `MAPLE_DEV_INSTANCE` when done. Keep or remove the
   disposable folders as needed; personal `~/.codex/config.toml` is never edited by this check.

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

## Repo secrets

Admins keep per-repo secrets in Settings → Secrets. A task's sessions get their repo's values through a
one-shot file their shell reads and deletes, so they're only in the pane's processes (not tmux's
environment, not the worktree), and `maple-runner secrets pull` works only on an admin's machine. The runner
scrubs values from everything it sends the factory, terminal output included, but not values under 6
characters or encoded ones. Changing or losing `SECRETS_KEY` makes every stored value unreadable, so they'd
all need setting again. See server/README.md.

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

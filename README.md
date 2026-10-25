# maple-factory

A software factory for teams: agents plan, build, review and prove work on the team's own machines,
and people approve, steer and merge from a native macOS app (web companion, iOS later).

Successor to `~/Projects/agent-orchestrator`, keeping what worked (easy runners, the task process,
web and phone access, Tailscale) and fixing what didn't (sessions dying for no clear reason, no multiplayer).

```
apps/mac/     SwiftUI app: the factory (goals, tasks, review, machines, requests, usage), live against a server; the design mockup when signed out
runner/       maple-runner (Rust): sessions in tmux, dials out to the server. From ao-runner 0.23.0
server/       Cloudflare Worker: OrgHub + MachineHub Durable Objects, D1, R2
protocol/     schema.ts → generated Rust, TypeScript and Swift types (npm run gen)
assets/       app icon source
```

Planned: `apps/web/` (companion), `installer/` (`maple install`).
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
End-to-end tests for each piece are in server/test (each says what it needs at the top). Launch flags for screenshots: `-onboardingURL localhost:8788
-onboardingContinue YES` plays the real sign-in; `-destination machines -liveSession first` opens a terminal.

Server tests: `node server/test/e2e-local.mjs http://localhost:8788 dev-mac` (relay, Kill, exit causes).
Runner tests: `cd runner && cargo test`.

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

# maple-runner changelog

Newest first. A release adds its `## <version> — <date>` section here before running
`scripts/release-runner.mjs`, which takes that section as the manifest's notes (unless `--notes` is given) and
publishes it, with the sections of earlier releases, to the feed's `maple-runner/changes.json`: the Mac app's
"What's new" for runners.

## 0.104.0 — 2026-11-02

A check this machine can't run (one marked `[macos]` on Linux, say) is reported as not run, with the reason, instead of failing the task.

## 0.103.0 — 2026-11-02

Understands the year-long merges calendar in the factory's statistics; nothing changes in how tasks run.

## 0.102.0 — 2026-11-01

Runners now report what they can do (macOS, Xcode, iOS simulators, Playwright, Docker, Node) so Apple work only lands on machines that can build it, and `maple-runner doctor` checks a headless Linux server is set up to run tasks.

## 0.101.0 — 2026-11-01

Programs a task's agent leaves running in its worktree (dev servers, watchers) are stopped when its last
session there ends, and again before task cleanup removes the worktree; the cleanup message names them.

Shared resource locks: `maple-runner lock <name> -- <command>` waits its turn for a resource that sessions on this machine compete for (an iOS simulator, a test database), then runs the command, and lets go when it ends or is killed. A session that's waiting shows "Waiting for ios-simulator · 1 ahead (MF-327 has it)" on its task. `maple-runner locks` lists who holds and waits for each, and `~/.config/maple/locks.toml` sets how many slots a lock has on this machine. Sessions get `MAPLE_RUNNER`, the runner's path, for scripts to call it. See docs/resource-locks.md.

## 0.100.0 — 2026-11-01

The runner understands one-off scheduled tasks, which run once at a set time.

## 0.99.0 — 2026-11-01

The runner understands research tasks, which finish with a written answer instead of a pull request.

## 0.98.0 — 2026-11-01

The runner understands the new Statistics fields that split idle time (drafting and backlog) from active cycle time.

## 0.97.0 — 2026-11-01

Weekly dependency refresh: the runner moves to reqwest 0.13, so it and Sentry share one HTTP stack (rustls with ring, system roots) instead of building two, and aws-lc is no longer compiled in.

## 0.96.0 — 2026-11-01

The runner keeps up with the factory's protocol for merge timing statistics.

## 0.95.0 — 2026-11-01

The runner keeps up with the factory's protocol for holding merges on a repo.

## 0.94.0 — 2026-11-01

The runner keeps up with the factory's protocol for the Hand off setting on tasks that go over budget.

## 0.93.0 — 2026-11-01

The runner keeps up with the factory's protocol for pausing new work on a machine and for merge statistics.

## 0.92.0 — 2026-11-01

The runner keeps up with the factory's protocol for review requests and task time breakdowns, and shows the answer you sent instead of a `<pasted_content …>` tag.

## 0.91.0 — 2026-11-01

The runner streams each session's Claude transcript or Codex rollout as native session events: messages, tool calls with their diffs and output, thinking, turns with what they used, and permission prompts (read off the pane when the agent's hook says one is showing). It tails the file from a byte cursor, follows Claude to a new transcript after `/clear` or `/compact`, waits for a Codex rollout that appears late, and passes records it doesn't know through as `other` events instead of breaking the stream. `session.events.subscribe` gets a backfill tagged with its nonce, then live events. It also takes `session.input` from the native composer: text is pasted and submitted, slash commands such as `/rc` are typed as a person would type them, and a prompt answer presses that option's key only while that prompt is still showing.

## 0.90.0 — 2026-11-01

`maple-runner uninstall` now removes the installed binary (~/.local/share/maple/bin/maple-runner and its ~/.local/bin link) along with the service, and says what's next. The new `maple-runner unenroll` takes the machine out of the factory with its own token, revokes that token and deletes ~/.config/maple/runner.json (`--local-only` skips the server for a machine that's offline for good); `uninstall --unenroll` does both. Repos and worktrees under ~/.local/share/maple/repos are always kept. Needs a factory that has `POST /runner/unenroll`.

## 0.89.0 — 2026-11-01

The runner keeps up with the factory's protocol for the optional risk classifier.

## 0.88.0 — 2026-11-01

The runner's libraries are brought up to date (uuid 1.29, rustls-native-certs, ureq and others); nothing changes in how it works.

## 0.87.0 — 2026-11-01

Proof screenshots and recordings upload at full size (up to 20 MB and 95 MB) instead of being shrunk first, and the runner keeps up with the factory's protocol for recurring tasks.

## 0.86.0 — 2026-11-01

The runner keeps up with the factory's protocol for day reports and phone push notifications.

## 0.85.0 — 2026-11-01

The runner keeps up with the factory's protocol for rechecking a task's pull request on GitHub, and uses a newer sysinfo for its health readings.

## 0.84.0 — 2026-10-31

Newer versions of the runner's libraries, including the one that checks release signatures; nothing changes in how it works.

## 0.83.0 — 2026-10-31

The runner keeps up with the factory's protocol for task budgets, quiet hours and mobile presence.

## 0.82.0 — 2026-10-31

When GitHub refuses a push that changes workflow files, the runner says the GitHub App needs Workflows: write and links to its permissions page.

## 0.81.0 — 2026-10-31

The runner speaks protocol 2: the factory's snapshot carries open and recently finished tasks, and older ones load on demand.

## 0.80.0 — 2026-10-31

The runner keeps up with the factory's protocol for threaded comments: replies carry the comment they answer.

## 0.79.0 — 2026-10-31

Agents can share charts, images, PDFs and HTML pages on a task with the share_artifact tool; the runner uploads the file to the factory.

## 0.78.0 — 2026-10-31

Update installs only the runner version you were shown; if a newer one came out meanwhile, nothing is installed until you press Update again.

## 0.77.0 — 2026-10-31

The runner keeps up with the factory's protocol for task dependencies: a task can wait on several others before it builds.

## 0.76.0 — 2026-10-31

Understands the new closed task state, for tasks that finish without code to merge, and closed-task counts in statistics.

## 0.75.0 — 2026-10-31

The runner keeps up with the factory's protocol for moving a task to another goal.

## 0.74.0 — 2026-10-31

The runner keeps up with the factory's protocol for review requests: a teammate can ask for one more review round with their own focus.

## 0.73.0 — 2026-10-30

The runner keeps up with the factory's protocol for GitHub's status: the factory now tells apps when githubstatus.com reports an incident.

## 0.72.0 — 2026-10-30

The runner keeps up with the factory's protocol for @Maple in Slack: integrations now carry a setup link and a status line.

## 0.71.0 — 2026-10-31

Agents can give a proposed task a priority (P0 to P3), and the runner keeps up with the factory's protocol for task priority and follow-ups.

## 0.70.0 — 2026-10-31

Keeps up with the factory's latest protocol, which now carries the reasons behind a change's risk level and plain-language risk checks; nothing changes in how the runner works.

## 0.69.0 — 2026-10-31

A task's diff now lists each commit on its branch with its own patch, for the Changes tab's commit picker; agents propose found work with `propose_tasks` (the old `create_task` and `propose_cards` tools are gone). `maple-runner stop` stops the installed service so launchd or systemd can't start it again (a runner stuck crashing and restarting stays down) until `maple-runner start`, which starts it in the background and waits for it to connect, or your next login. Both take `--dry-run`.

## 0.68.0 — 2026-10-31

Fixes 0.67.0 crashing as it connects to the factory (two TLS crypto providers were built in): the runner now picks one at startup. A machine stuck on 0.67.0 needs `maple-runner update` run by hand, then its service restarted.

## 0.67.0 — 2026-10-30

Reports panics and errors to Maple Factory's Sentry project, without the machine's name and with ~ for your home folder; MAPLE_TELEMETRY=off turns it off. Checks that a builder's branch merges into its base (origin/<base>, fetched fresh) before its finish is pushed: on a conflict nothing is pushed, and the conflicting files go back to the builder to merge the base in, resolve and finish again. A base that can't be fetched doesn't hold the push up.

## 0.66.0 — 2026-10-30

Runs a repo's checks (linters, formatters, lefthook) in the worktree before a builder's finish is committed; a failing check, or a failing pre-commit hook, stops the push and is reported back.

## 0.65.0 — 2026-10-30

Runs a repo's preflight script (runtimes, brew, services) in a new worktree before its setup script: the first time a machine's checkout of the repo is used, and again when the command or a watched file such as .tool-versions or Brewfile changes.

## 0.64.0 — 2026-10-30

Keeps up with the factory's latest protocol, which now carries each repository's description and owner avatar; nothing changes in how the runner works.

## 0.63.0 — 2026-10-30

Keeps up with the factory's latest protocol, which now tells apps about a Scout run still going when they reconnect; nothing changes in how the runner works.

## 0.62.0 — 2026-10-30

Scout and Draft with AI can read a goal whose code is a local folder, in place and read-only, even when it has no git origin.

## 0.61.0 — 2026-10-30

The runner is built with the latest protocol, which adds sharing a live session with teammates; nothing else changes on the runner.

## 0.60.0 — 2026-10-30

The runner is built with the latest protocol, which adds Set up with AI for repos; it runs through the same read-only draft sessions as before.

## 0.59.0 — 2026-10-30

The runner is built with the latest protocol, which adds revoking a member's access; nothing else changes on the runner.

## 0.58.0 — 2026-10-30

After the factory merges a task, the runner deletes its leftover branch on origin when nothing unmerged would be lost, and says what became of it.

## 0.57.0 — 2026-10-29

The runner can dry-run merge a task's branch into its base, so the factory finds a conflict before it merges instead of after.

## 0.56.0 — 2026-10-29

The protocol carries a plan's suggested title for its task.

## 0.55.0 — 2026-10-29

The protocol carries each check's link, its log and re-running one check.

## 0.54.0 — 2026-10-29

MCP connectors: sessions get the factory's connectors (Claude through a per-session 0600 config, Codex through -c overrides, with secrets in the pane's one-shot env file, never argv), and only the runner's own Maple server is pre-allowed.

## 0.53.0 — 2026-10-29

Sign a machine's Codex in from the app: the runner runs `codex login --device-auth` and reports its link and one-time code to the machine's owner, then checks its agents again as soon as it's signed in. From this release there's no Intel Mac build.

## 0.52.0 — 2026-10-29

The protocol carries code review notes and GitHub review threads.

## 0.51.0 — 2026-10-29

The protocol carries factory-granted admins.

## 0.50.0 — 2026-10-29

The protocol carries the GitHub accounts an admin approved for repos.

## 0.49.0 — 2026-10-29

The protocol carries a task's chosen model and the factory's display name.

## 0.48.0 — 2026-10-29

The protocol carries each draft's place in its goal's order.

## 0.47.0 — 2026-10-29

Codex sessions get their whole prompt, trailing newlines and all, so they start without someone pressing Enter. The protocol carries the factory's icon.

## 0.46.0 — 2026-10-29

Codex sessions in project mode route approval prompts to Codex's automatic review ("Approve for me") instead of never asking. Per-repo worktree scripts: a repo's create, setup, teardown and archive commands run around a task's worktree, with MAPLE_* variables, its secrets and a timeout, and report on the timeline.

## 0.45.0 — 2026-10-29

Secrets hardening: a task's values live only in its pane (not tmux's environment, where other sessions could read them), terminal output and replays are scrubbed, and multi-line values survive a restart. Checking for a runner update only looks; it never installs. Auto-merges count down and can be held.

## 0.44.0 — 2026-10-29

Repo secrets: a task's sessions get its repo's secrets in their environment, scrubbed from what the runner sends, and `maple-runner secrets pull|list` for your own checkout.

## 0.43.0 — 2026-10-29

The runner checks for its own updates hourly instead of every six hours.

## 0.42.0 — 2026-10-29

Statistics break down code review findings by kind, severity, area, outcome and agent.

## 0.41.0 — 2026-10-29

A backlog state: park a draft or a plan for later, and pick it up when it's time.

## 0.40.0 — 2026-10-29

Runner updates report Installing before they download, so the app shows what's coming; the release notes and date now reach the Mac app's What's new.

## 0.39.0 — 2026-10-29

Turn off auto-merges, and goal due dates.

## 0.38.0 — 2026-10-29

Take over or reassign a task.

## 0.37.0 — 2026-10-29

Each session's cost, by role and by agent and model.

## 0.36.0 — 2026-10-29

@mention teammates in comments.

## 0.35.0 — 2026-10-29

Efforts link tasks into a bigger piece of work; admins add to agents' prompts for the org or a goal.

## 0.34.0 — 2026-10-29

Factory statistics for admins, and a new /setup and welcome page.

## 0.33.0 — 2026-10-29

A session's permission prompt shows on its task, with Yes and No.

## 0.32.0 — 2026-10-29

Screenshot and video proofs, uploaded by the runner and shown to members.

## 0.31.0 — 2026-10-28

Run now starts a queued task without waiting for a free slot.

## 0.30.0 — 2026-10-28

Attest to a Done when item yourself, with an optional reason.

## 0.29.0 — 2026-10-28

Bare maple-runner prints a colorized command list and the runner is `maple-runner run` (services installed before still run).

## 0.28.0 — 2026-10-28

A task queue with order and schedules; the web app loads again (0.6.0 and 0.7.0 declared cancelling twice).

## 0.27.0 — 2026-10-28

A merged task's branch is deleted on GitHub, and its stale tracking ref dropped.

## 0.26.0 — 2026-10-28

Tolerates enum values a newer server adds; Retry puts a detached worktree back on its branch.

## 0.25.0 — 2026-10-28

A merge that fails raises a Didn't merge hand to send back, retry or cancel.

## 0.24.0 — 2026-10-28

Attachments, Draft with AI transcripts, approval waiting on the automatic review.

# maple-runner changelog

Newest first. A release adds its `## <version> — <date>` section here before running
`scripts/release-runner.mjs`, which takes that section as the manifest's notes (unless `--notes` is given) and
publishes it, with the sections of earlier releases, to the feed's `maple-runner/changes.json`: the Mac app's
"What's new" for runners.

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

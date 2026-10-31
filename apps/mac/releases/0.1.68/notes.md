---
version: 0.1.68
build: 69
channel: stable
date: 2026-10-31
minimumSystemVersion: 15.0
---

### Added

- **Settings › Integrations**: admins connect Slack, Linear and Jira from the app, with each one's status, its webhook URL and an on/off switch. Secrets are stored encrypted and never sent back to the app.
- **Checks** in **Settings › Worktree scripts**: commands such as linters, formatters or lefthook that must pass in a task's worktree before a builder's work is committed and pushed. A failing check goes back to the builder to fix, and a person is asked after three in a row.

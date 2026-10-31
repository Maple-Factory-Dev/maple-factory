---
version: 0.1.66
build: 67
channel: stable
date: 2026-10-30
minimumSystemVersion: 15.0
---

### Added

- **Preflight** in **Settings › Worktree scripts**: a command that sets a machine up for a repo, like installing its runtimes, running `brew bundle` or starting services. It runs in a new worktree before **Setup**, the first time a machine's checkout of the repo is used, and again when the command or a watched file changes.
- **Watch** lists the files that re-run **Preflight** when they change, one per line. Leave it empty to watch the usual version files, such as `.tool-versions`, `.nvmrc` and `Brewfile`.

---
version: 0.1.41
build: 42
channel: stable
date: 2026-10-29
minimumSystemVersion: 15.0
---

### Added

- **Worktree scripts:** Settings › Repositories opens a repo's worktree scripts: commands that create, set up, tear down and archive a task's worktree. Admins edit them and members can read them. Repos with scripts show a badge in the list.
- A task's timeline says how its worktree was made and cleaned up.

### Fixed

- Codex sessions no longer stall on approval prompts: the bundled runner sends them to Codex's automatic review.

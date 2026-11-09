---
version: 0.3.21
build: 127
channel: stable
date: 2026-11-09
minimumSystemVersion: 15.0
---

### Added

- **Comments in Docs**: select text in a doc to start a thread, reply, **@mention** teammates, and resolve threads when they're done. The doc list shows how many open threads each doc has.
- Tables in Markdown artifacts and notes now show as real tables.

### Changed

- When tmux or a machine dies mid-task, the restarted session picks up the agent's own conversation where it left off instead of starting over (with runner 0.109.0).

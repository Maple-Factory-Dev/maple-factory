---
version: 0.1.5
build: 6
channel: stable
date: 2026-10-28
minimumSystemVersion: 15.0
---

### Fixed

- A factory that's newer than the app no longer breaks it. The app reads states it doesn't know yet as a general one and keeps working. If a message still can't be read, it says **This factory is newer than this app**, with Check for Updates, instead of "The data couldn't be read".
- Retrying a task whose worktree had come off its branch puts it back on the branch first, when nothing would be lost.

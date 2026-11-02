---
version: 0.3.14
build: 120
channel: stable
date: 2026-11-02
minimumSystemVersion: 15.0
---

### Added

- When a task was built on a machine that couldn't run some checks (say, Xcode checks on Linux), a Mac with the right tags now runs them on the task's latest commit. The pull request shows them under **Apple checks**: waiting, running, passed or failed. Merging waits for them to pass, and a new push runs them again.

### Changed

- Bundles maple-runner 0.105.0.

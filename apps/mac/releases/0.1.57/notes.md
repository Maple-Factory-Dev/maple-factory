---
version: 0.1.57
build: 58
channel: stable
date: 2026-10-30
minimumSystemVersion: 15.0
---

### Added

- **Scout** on a goal's header: an agent looks over the goal's leftovers (backlog tasks, and review findings its merged tasks left open) and drafts plans for the ones still worth doing, ready for your approval.
- **Items per Scout run** in Settings → **Scout**: how many leftovers one run turns into plans (1 to 10, 3 by default).
- **Scouted from** on board cards and in a task's details, showing the task or review finding Scout picked it up from.
- **24 hours** and **3 days** ranges on **Statistics**, with bars by the hour in your local time.
- Zoom and pan a screenshot in the proof lightbox.

### Changed

- When the factory merges a task, its branch is deleted on GitHub too (unless it has work that didn't merge), and the task's timeline says so.

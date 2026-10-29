---
version: 0.1.3
build: 4
channel: stable
date: 2026-10-28
minimumSystemVersion: 15.0
---

### Added

- When a merge fails, the task shows **Didn't merge** instead of getting stuck: send it back to fix, try the merge again, or cancel it from the Ready to merge card.

### Changed

- Requesting changes on a task that didn't merge clears the hand, and Try the merge again keeps it until the merge starts.

---
version: 0.3.9
build: 115
channel: stable
date: 2026-11-01
minimumSystemVersion: 15.0
---

### Added

- A goal's header has a **Scheduled** button showing how many recurring and scheduled tasks it has. It opens the sheet where you manage them.
- Schedule a task to run once at a set time: in that sheet, choose **Repeats: Once**. It runs at that time and is then removed.

### Changed

- The app now bundles maple-runner 0.101.0. Programs an agent leaves running (dev servers, watchers) are stopped when its session ends. Tasks can now take turns on shared resources like the iOS simulator, and show "Waiting for…" while they're in line.

---
version: 0.1.40
build: 41
channel: stable
date: 2026-10-29
minimumSystemVersion: 15.0
---

### Added

- **Auto-merge countdown:** an approved change counts down on its merge card before it merges on its own, with **Hold** to stop it and **Merge now** to skip the wait.
- **Settings cog** in the sidebar footer: jump straight to Settings, or right-click it for a menu of its panes.

### Changed

- **Check for runner update** on a machine only looks for a newer release; it no longer installs one. Use Update for that.
- The factory's toasts now show in the app; they were received but never shown.
- Pulling secrets without a task needs an admin's machine.

---
version: 0.1.60
build: 61
channel: stable
date: 2026-10-30
minimumSystemVersion: 15.0
---

### Added

- **Revoke access** in Settings → **Factory admins**: cut someone off at once. Their apps and terminals close and their tokens stop working until they sign in again.

### Changed

- Terminals on a machine open only for its owner and admins. If you can't open one, the app says why instead of trying again.
- **Merge**, **Hold** and **Merge now** lock as soon as the countdown reaches zero or a merge starts, so a task can't be merged twice.

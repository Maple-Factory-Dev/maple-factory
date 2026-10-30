---
version: 0.1.38
build: 39
channel: stable
date: 2026-10-29
minimumSystemVersion: 15.0
---

### Added

- **Settings › Secrets:** admins add, replace and delete a repo's secrets (API keys, database URLs and the like). The factory encrypts them, and the app only ever shows their names, who last updated each and when.
- A task's agent sessions get their repo's secrets as environment variables, and the runner scrubs the values from what it sends back.

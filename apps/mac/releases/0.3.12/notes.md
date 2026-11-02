---
version: 0.3.12
build: 118
channel: stable
date: 2026-11-02
minimumSystemVersion: 15.0
---

### Added

- If a task's machine can't run one of the repo's checks (an Xcode check on a Linux machine, say), the task shows it as **Not run here** with the reason instead of failing. Click **Waive…** and add a note saying why it's fine to merge without it. Auto-merge waits until every check that wasn't run is waived.

### Changed

- Bundles maple-runner 0.104.0.

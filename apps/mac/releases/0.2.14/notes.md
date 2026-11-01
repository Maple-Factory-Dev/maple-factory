---
version: 0.2.14
build: 85
channel: stable
date: 2026-10-31
minimumSystemVersion: 15.0
---

### Added

- **Requests** can be filtered to **Unanswered**, **Waiting**, **In flight** or **Done**, and accepted requests show their task's state as it changes.

### Changed

- **Machines** shows each session's task title, and hovering its task ID shows the task.
- **How requests come in** moved out of the top of **Requests** into the ⓘ button next to the title.

### Fixed

- A factory with a long history no longer fails to connect with "Message too long".

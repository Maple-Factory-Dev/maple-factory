---
version: 0.2.11
build: 82
channel: stable
date: 2026-10-31
minimumSystemVersion: 15.0
---

### Added

- A goal's views can show **Everyone**'s tasks or just **You**rs. The choice is remembered, and if none of a goal's tasks are yours, **Show everyone's** brings the rest back.
- A new **Closed** state for tasks that finish with nothing to merge, like a scan that proposed tasks instead of a plan. **Statistics** counts them as **Closed with nothing to merge**.

### Fixed

- A goal with many tasks no longer makes the board and overview stall when tasks update live.

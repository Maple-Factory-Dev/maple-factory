---
version: 0.2.12
build: 83
channel: stable
date: 2026-10-31
minimumSystemVersion: 15.0
---

### Added

- A task can wait on one or more other tasks to merge before it builds. In a task's details, **Builds on** lists them: **Add…** picks another open task in the goal, and removing one stops the wait.
- A task that's waiting says so (**Waiting for MF-201 and MF-202 to merge**), and a task others wait on shows them under **Blocks**.

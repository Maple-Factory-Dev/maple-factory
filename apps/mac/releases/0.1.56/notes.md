---
version: 0.1.56
build: 57
channel: stable
date: 2026-10-30
minimumSystemVersion: 15.0
---

### Added

- **Merge** row in the review panel: shows whether a task merges cleanly into its base, which files conflict (and which merge caused it), or which other tasks in flight touch the same files, each a link to that task.
- **Agent instructions** for a goal: add your own instructions for its planners, builders and reviewers on top of the built-in and organization ones.
- Sixteen goal colors plus **Custom**, for any color you like.

### Changed

- Goals are made and edited on a full page instead of a sheet, with sections for **Basics**, **Code**, **Team & due date**, **Look** and **Agent instructions**.
- **All goals** with no goals yet offers to start your first one.
- A new goal's ring shows its color straight away, even before any task is done.

### Fixed

- When a goal can't be saved, the reason now shows under the editor's header.

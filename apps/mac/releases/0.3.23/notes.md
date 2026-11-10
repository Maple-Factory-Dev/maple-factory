---
version: 0.3.23
build: 129
channel: stable
date: 2026-11-10
minimumSystemVersion: 15.0
---

### Added

- **Stop the line**: hold merges from the top bar, for every goal repo or just one, with a reason. While merges are held, everyone sees a **Line stopped** banner, and you can **Lift** the hold from there.
- **Decisions**: propose one in a doc with **/decision**, then accept or reject it and give a reason why. A **Decisions** view lists the ones waiting for a person, filtered by goal, person and status, and each keeps a history that can't be edited.
- Ask an agent about a selection in a doc: it answers in the doc's thread as a side conversation, and you can stop it there.
- Task lists show each PR's CI checks GitHub-style, and a task only shows **Ready to merge** once CI has passed.
- Stats: the year's merge grid can show the last 30, 60, 90 or 365 days.

### Fixed

- Mermaid diagram previews in the doc editor no longer render as a blank white frame.

---
version: 0.3.24
build: 130
channel: stable
date: 2026-11-10
minimumSystemVersion: 15.0
---

### Added

- Keyboard navigation for task lists, the board and the Inbox: move with the arrow keys (or **J**/**K** and **H**/**L**), **Return** to **Open Task**, **Space** to **Peek in Panel**, and **A** to **Do Primary Action**.
- A Dock badge counts what's waiting on you. Turn it off with **Show count on the Dock icon** in Settings.
- Make tasks from a doc: turn a section, a selection or an accepted decision into draft tasks. Each one links back to the doc, and the doc shows the tasks live where they came from.
- **Move to goal** moves a doc to another goal, or out of any goal.
- Diagram blocks in docs have a **Preview** / **Split** / **Code** toggle.

### Fixed

- Actions taken while you're disconnected are no longer silently dropped: they're refused with a message, New Task keeps your draft, and the window shows **Offline · Reconnecting…** until you're back.
- Typing in a doc no longer gets lost when the same doc is open in two windows.

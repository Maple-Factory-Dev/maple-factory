---
version: 0.1.11
build: 12
channel: stable
date: 2026-10-29
minimumSystemVersion: 15.0
---

### Fixed

- Request changes on a plan works even after the planner's session has ended, and gets you a revised plan. Retry does the same when a task has no session running.
- The composer switches to steering as soon as a task can take it. On a waiting plan it reads as revising the plan, and its Comment tab says a comment won't send the plan back.

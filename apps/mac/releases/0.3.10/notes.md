---
version: 0.3.10
build: 116
channel: stable
date: 2026-11-02
minimumSystemVersion: 15.0
---

### Added

- Each machine's settings have a **Tags** section showing what its runner can do (macOS, Xcode, iOS simulators, Playwright, Docker, Node). Click a detected tag to hide it, or add your own, like `gpu` or `big-disk`.
- In a repo's scripts, **Needs tags** sends work to the right machines: a rule like `apps/mac/** macos` means a task that touches those files only runs on a machine tagged `macos`.
- In **Checks**, start a line with `[macos]` (or `[xcode,macos]`) so only machines with those tags run it. Elsewhere the builder is told the check was skipped.
- A task shows the machine tags it **Needs**, and while it waits it says which tags none of your machines has.

### Changed

- Bundles maple-runner 0.102.0, which reports what each machine can do and adds `maple-runner doctor` for checking a headless Linux server.

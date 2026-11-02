---
version: 0.3.15
build: 121
channel: stable
date: 2026-11-02
minimumSystemVersion: 15.0
---

### Added

- **Add machine** has a **Linux server (cloud-init)** option. Paste the snippet as user-data when you create a droplet or VM, and the box sets itself up and joins your factory. The enrollment code is filled in, with a countdown and a **New code** button.
- A check that a GitHub Actions run covers now shows **Proved by GitHub Actions** with a link once that run passes, instead of waiting for a Mac or a waiver. If the run fails, the check shows as failed and merging waits.

### Changed

- Bundles maple-runner 0.106.0.

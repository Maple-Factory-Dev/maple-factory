---
version: 0.2.2
build: 73
channel: stable
date: 2026-10-31
minimumSystemVersion: 15.0
---

### Fixed

- **Add this Mac** installed runner 0.67.0 from 0.2.0 and 0.2.1, which crashed as soon as it connected to your factory. This release bundles runner 0.68.0, which fixes it. If this Mac's machine is already offline with 0.67.0, run `~/.local/share/maple/bin/maple-runner update` in Terminal, then `launchctl kickstart -k gui/$(id -u)/dev.maplefactory.runner`.

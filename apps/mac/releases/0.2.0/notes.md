---
version: 0.2.0
build: 71
channel: stable
date: 2026-10-31
minimumSystemVersion: 15.0
---

### Added

- The app sends crash and error reports to Maple Factory, so problems can be found and fixed sooner. Reports carry the app's version and your factory's organization, but nothing you type: no user, screenshots, window contents or network activity. To turn them off, run `defaults write dev.maplefactory.app MapleTelemetry off` in Terminal, or set `MAPLE_TELEMETRY=off`.

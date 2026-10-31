---
version: 0.1.62
build: 63
channel: stable
date: 2026-10-30
minimumSystemVersion: 15.0
---

### Changed

- The app uses much less CPU and memory: board cards only redraw when they change, screenshots are decoded at the size they're shown, and the auto-merge countdown animates smoothly without redrawing every frame.

### Fixed

- Screenshots opened large in the lightbox, and videos in proofs, are released when you close them instead of staying in memory.

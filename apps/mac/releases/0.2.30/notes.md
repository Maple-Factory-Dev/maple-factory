---
version: 0.2.30
build: 101
channel: stable
date: 2026-11-01
minimumSystemVersion: 15.0
---

### Added

- **Risk classifier**: in the risk policy, turn on **Grade each built change** and write a prompt. The reviewer grades every built change against it, can raise its risk and ask for a person's review, and never lowers what the policy asks for.

### Changed

- Plan approvals and final reviews can be set to 0 at any risk level. A plan that needs no approval starts building right away, and a change that needs no review merges without one.

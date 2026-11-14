# Changelog

All notable changes are listed here. Versions follow [Semantic Versioning](https://semver.org).

## 0.1.1 — 2026-11-14

- Builds with Xcode 26 (Swift 6.2): works around a compiler crash and an expression it could not
  type-check in time. No change in behaviour; CI builds and tests on GitHub's macOS runners.

## 0.1.0 — 2026-11-14

First public release.

- Menu bar item with a memory graph, memory in use and free disk; popover with Free memory.
- Storage analyzers, a treemap of the whole disk, build generations with retention and budgets.
- Memory: pressure, compression and swap; owners of memory; idle browser tabs; unused open apps;
  processes in swap; Docker VM memory; a memory journal every five minutes.
- Agent sessions (Claude Code, Codex, OpenCode, Hermes): protection of their projects, pausing idle
  sessions and waking them, leases through a local API.
- Optional daily disk rules (Docker, caches, logs, temp, Android emulators and images, tool
  backups, Downloads and screenshots) with three rule sets, a 24-hour plan with *Leave alone*,
  and a restore center for everything moved to the Trash.
- Apps: usage statistics and removal suggestions for apps unused for 30 days.
- Startup: launch agents, daemons and login helpers, switching agents off and on, notice of new ones.
- Notifications about what PEPEL did on its own, and a weekly summary.
- English and Russian, following macOS; the `pepel` command line with the same features.

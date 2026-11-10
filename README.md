# PEPEL

**Clean the waste. Preserve the work.**

PEPEL is a native macOS menu bar app that watches what a developer workstation generates — build
output, caches, dependency trees, forgotten test processes — and helps reclaim it without
disrupting work in progress. It is built for machines that run several AI coding agents, IDEs,
local services and builds at once.

It is not a general Mac cleaner. Before it proposes anything it works out which project an
artifact belongs to, whether a build or an agent session is using it, and how sure it is. Every
association carries a confidence level (verified, probable, unknown) and guesses are labelled as
guesses.

- Swift 6, SwiftUI + AppKit, Swift Concurrency, system SQLite. No third-party dependencies.
- macOS 14 or later. Developed and verified on Apple Silicon.
- Runs with ordinary user rights. No Full Disk Access, no administrator rights, no helper.

## What it does

| Area | What PEPEL does |
|---|---|
| **Menu bar** | Shows health and verified reclaimable storage (`● 42 GB`). The popover has disk, reclaimable space, memory pressure, swap, active builds, abandoned-process candidates and 24-hour growth. |
| **Projects** | Finds repositories, worktrees and manifest-only projects under your project roots; groups worktrees by repository. |
| **Storage** | Eleven analyzers measure build output, caches, dependencies, simulators, containers and AI-tool data. Allocated blocks, hard links counted once. |
| **Builds** | Groups artifacts into build generations per repository, applies a retention policy, tracks per-project and global budgets, explains each verdict. |
| **Memory** | Reads the kernel's own pressure level, compression and swap. Recovers memory only by stopping processes that are verifiably abandoned. |
| **Processes** | Classifies developer processes as active, deliberately running, or left behind, using PID + start time, process trees and observed CPU activity. |
| **Agents** | Detects Claude Code, Codex, OpenCode and Hermes sessions from their processes; protects the projects they work in; offers leases through a local API. |
| **Cleanup** | One policy engine decides. Dry run, exact preview, revalidation at the moment of removal, audit log, undo for trashed items. |

## Build and run

```bash
Scripts/build-app.sh release
```

```bash
open dist/PEPEL.app
```

The bundle contains the app and the `pepel` command-line tool
(`dist/PEPEL.app/Contents/Helpers/pepel`). To have it on your `PATH`:

```bash
ln -s "$PWD/dist/PEPEL.app/Contents/Helpers/pepel" /usr/local/bin/pepel
```

For development:

```bash
swift build
```

```bash
swift test
```

```bash
swift run pepel status
```

`swift run PEPELApp` starts the menu bar app without a bundle; notifications, the login item and
the bundled icons need the real bundle.

The app icon and menu bar glyph are generated from `Resources/AppIcon.png` and
`Resources/Glyph-source.png` by `Scripts/make-icon.sh` and `Scripts/make-glyphs.swift`.

## Command line

```
pepel status                     Disk, memory, builds and reclaimable storage at a glance
pepel scan                       Scan developer storage now (nothing is removed)
pepel projects                   Discovered projects and their artifact usage
pepel builds                     Build generations, retention verdicts and budgets
pepel memory                     Memory pressure, swap and the largest consumers
pepel processes [--all]          Developer processes and whether they look abandoned
pepel cleanup [--dry-run]        Preview what cleanup would do (default)
pepel cleanup --safe [--yes]     Remove items classified safe
pepel cleanup --review           Decide interactively on items that need review
pepel terminate <pid> [--force]  Safely terminate a developer process (asks first)
pepel protect <path>             Never clean this path
pepel pin <path>                 Keep a build generation regardless of retention
pepel history                    Audit log and storage growth
pepel run -- <build command>     Run a build under PEPEL so its lifetime and outcome are known
pepel agent <op> [key=value …]   Agent API
pepel config [set <key> <json>]  Show or change settings
```

Every read command accepts `--json`. The CLI and the app share one database and one policy
engine. There is no command that deletes an arbitrary path.

## Safety model

| Class | Meaning | What can happen |
|---|---|---|
| **Safe** | Verified disposable, no active dependency found | Removed when you ask; removed automatically only if you enable automatic safe cleanup |
| **Review** | Reproducible or recoverable, but removal costs a rebuild, download or restart | Only with your explicit confirmation per item |
| **Protected** | Possibly important, or ownership unclear | Never removed |

Never removed, whatever an analyzer reports: source code and git working trees, git metadata,
`~/.ssh` and other credential stores, agent state and history, model weights, container volumes,
application data, simulator devices, Xcode archives, anything in use by a running process,
anything leased, anything written within the last ten minutes.

Details: [docs/SECURITY.md](docs/SECURITY.md), [docs/ANALYZERS.md](docs/ANALYZERS.md).

## Defaults

- Monitoring mode: notify only. Nothing is removed without you.
- Removal: safe items permanently (they are reproducible, and the Trash frees no space); review
  items to the Trash.
- Build retention per project: keep the last 2 builds and the last failed one, never propose
  anything newer than 48 hours, 40 GB budget; 200 GB global budget.
- A process counts as idle after 30 minutes of observed inactivity. Automatic termination is off.
- Project roots: whichever of `~/projects`, `~/Developer`, `~/src`, `~/code`, `~/work`, `~/dev`,
  `~/git`, `~/repos`, `~/workspace` exist. `~/Documents`, `~/Desktop` and `~/Downloads` are not
  examined unless you add them.

## Documentation

- [Architecture](docs/ARCHITECTURE.md)
- [Security and permissions](docs/SECURITY.md)
- [Analyzers and cleanup policies](docs/ANALYZERS.md)
- [Known limitations](docs/LIMITATIONS.md)

Screenshots are rendered from the live state of your own machine with `Scripts/screenshots.sh`
(they contain your project names, so they are not committed).

## License

MIT. See [LICENSE](LICENSE).

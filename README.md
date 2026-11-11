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
Scripts/install.sh
```

This builds `dist/PEPEL.app`, installs it to `/Applications/PEPEL.app` and starts it. Run it from
`/Applications`, not from the build folder: on macOS 27 a menu bar manager such as Hidden Bar
hides the icon of an app that runs from elsewhere (see [Known limitations](docs/LIMITATIONS.md)),
and the login item needs it there too. To build without installing: `Scripts/build-app.sh release`.

The bundle is signed with the first code-signing identity in your keychain, or ad hoc when there
is none (`PEPEL_SIGN_IDENTITY` overrides this).

The bundle contains the app and the `pepel` command-line tool
(`/Applications/PEPEL.app/Contents/Helpers/pepel`). To have it on your `PATH`:

```bash
ln -s /Applications/PEPEL.app/Contents/Helpers/pepel /usr/local/bin/pepel
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
pepel free [--all] [--no-cache] [--yes]
                                 Free memory: show what would be stopped and flushed, then do it and measure
pepel free permission [--revoke] Whether PEPEL may flush the file cache without asking; remove that permission
pepel freeze <pid> | thaw [...]  Suspend an agent session without ending it; wake it
pepel memory growth | swapped    What keeps growing; what lives in swap and does nothing
pepel apps [unused|restart|quit] Applications by memory; unused ones; ask one to quit or restart
pepel simulators [shutdown …]    Booted simulators and what they hold
pepel budget [set <owner> <GB>]  Memory budgets per owner; alerts when exceeded
pepel agents servers [clean]     What agents' servers started and kept; end old idle copies
pepel apps tabs [unload]         Browser tab processes; unload the idle ones
pepel memory system [restart …]  Large macOS components; restart one the system brings back
pepel memory forecast | swap     Where memory use is heading; what swap takes on disk
pepel containers pause|unpause   Freeze a project's containers in place, and continue them
pepel summary [--hours N]        What PEPEL did over the last day and what it left for you
pepel journal [--days N] [path]  The memory journal: what the last days say, and where it is kept
pepel docker [clean …|compact]   What Docker keeps on disk; remove what is unused for N days; trim its disk image
pepel projects stale [clean]     Projects left untouched for N days; remove their environments and build output
pepel caches [trim …]            Tool caches; remove only what is unused, or above a size limit
pepel apps caches | leftovers    Application caches by last use; what removed applications left behind
pepel disk [logs [clean]]        Free space, when the disk would fill, other large places, old logs
pepel disk map [<folder>]        What a folder holds, largest first (the dashboard's Disk map as a table)
pepel disk temp [clean]          The temporary folder: what nothing has used for N days
pepel projects ignored [trash …] Large folders git ignores that PEPEL does not recognise
pepel disk emulators [delete …]  Android emulators by size and last use; delete chosen ones
pepel disk images [delete …]     Android system images no emulator uses; delete them
pepel disk backups [clean]       Clausona's backups; keep the newest N of each set, remove the rest after D days
pepel docker volumes             Named volumes no container mounts, and whether their project is still here
pepel disk files [--days N]      Large files not opened for N days, and identical copies (a report)
pepel containers limit [<GiB>]   Show or lower the Docker VM's memory limit
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

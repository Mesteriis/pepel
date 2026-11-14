# PEPEL

[![CI](https://github.com/Mesteriis/pepel/actions/workflows/ci.yml/badge.svg)](https://github.com/Mesteriis/pepel/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/Mesteriis/pepel)](https://github.com/Mesteriis/pepel/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-lightgrey)

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
| **Menu bar** | A small graph of memory in use with memory and free disk beside it (or reclaimable storage, pressure, builds). The popover has disk, memory, swap, builds and one-click Free memory. |
| **Overview** | What the daily rules will remove in the next 24 hours, with *Leave alone* per item, and everything PEPEL moved to the Trash with *Put back*. |
| **Storage & disk map** | Analyzers for build output, caches, dependencies, simulators, containers and AI-tool data; a treemap of the whole disk measured folder by folder. |
| **Memory** | The kernel's pressure, compression and swap; who holds memory; idle browser tabs, apps open but unused, processes living in swap. Memory is recovered only by stopping what is verifiably idle or abandoned. |
| **Apps** | How much each installed app is used (macOS's last-opened date plus PEPEL's own time-in-front record) and what it occupies with its data; suggests removing apps unused for 30 days. Removal goes to the Trash after you confirm. |
| **Startup** | Every launch agent, daemon and login helper with what it runs and holds now; switch agents off and on; a notification when something new appears. |
| **Builds & projects** | Repositories, worktrees and build generations with retention and budgets; projects left untouched and folders git ignores. |
| **Agents** | Detects Claude Code, Codex, OpenCode and Hermes sessions; protects the projects they work in; can pause idle sessions and wake them when you return; offers leases through a local API. |
| **Daily rules** | Optional rules for Docker, tool and app caches, logs, temp files, Android emulators and images, tool backups, Downloads and screenshots — with three ready-made rule sets. |
| **Cleanup** | One policy engine decides. Dry run, exact preview, revalidation at the moment of removal, audit log, restore center. |
| **Notifications** | Plain sentences about what PEPEL did on its own — which app it closed and how much memory that freed, what the disk rules removed — and a weekly summary. |

Everything in the app is also in the `pepel` command line, and the app speaks English and Russian.

## Install

Download `PEPEL-<version>.zip` from the [latest release](https://github.com/Mesteriis/pepel/releases/latest),
unzip it and move `PEPEL.app` to `/Applications`. The release is built for Apple Silicon and is not
notarized, so macOS blocks the first launch: open it once with a right-click → **Open**, or run

```bash
xattr -dr com.apple.quarantine /Applications/PEPEL.app
```

Then Settings › *Start PEPEL when you log in* keeps it running. The command line is inside the app:

```bash
ln -s /Applications/PEPEL.app/Contents/Helpers/pepel /usr/local/bin/pepel
```

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

## Languages

The app speaks English and Russian and follows macOS: the system language, or the one chosen
for PEPEL in System Settings › General › Language & Region › Applications (applied on the next
launch). The command line always prints English, so scripts and agents read stable text.

Texts live in one String Catalog, `Resources/Localizable.xcstrings` (English source, Russian with
plural forms). Sentences shown to a person are written as `Text("…")`, a literal passed to a PEPEL
primitive, or `L("… \(count) …")` in non-UI code; codes that code compares and audit records stay
English. After changing texts run `Scripts/sync-strings.sh`: it compiles the app with key
extraction and merges new keys into the catalog (they arrive untranslated). `Scripts/build-app.sh`
compiles the catalog into `en.lproj` / `ru.lproj`.

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
pepel summary [--hours N]        What PEPEL did over the last week (or day) and what it left for you
pepel plan [--all]               What the daily rules will remove in the next 24 hours
pepel plan leave|forget <id|path>  Keep the daily rules off one item, or let them act on it again
pepel restore [N] [--days N]     What PEPEL removed lately; put item N back from the Trash
pepel preset [careful|normal|aggressive] [--yes]  Ready-made sets for the daily disk rules
pepel self                       What PEPEL itself costs in memory and CPU
pepel apps installed [--all]     Installed apps: last used, time in front, size with data; which to remove
pepel apps uninstall <name> [--keep-data] [--yes]  Move an app and its data to the Trash (pepel restore puts it back)
pepel apps keep|unkeep <name>    Never suggest an app for removal, or judge it again
pepel startup [disable|enable <label>] [--yes]  Launch agents, daemons and login helpers, what they hold; switch an agent off or on
pepel login [on|off]             Whether PEPEL starts when you log in (the app registers it with macOS)
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
pepel apps windowless [on|off …] Apps that stay open with no window; quit the chosen ones when they have none
pepel disk tidy [clean]          Old screenshots and downloads; take them, to the Trash by default
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

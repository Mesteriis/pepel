# Analyzers and cleanup policies

## Analyzers

Each analyzer implements `StorageAnalyzer`: an identifier, a display name, a one-sentence
detection description, its fixed paths, a cheap `discover` step, and a `validate` step that the
executor runs again right before cleanup. `pepel analyzers` prints the live list.

Project-relative artifacts are only considered inside discovered projects. Where git is
available PEPEL asks it (`git check-ignore`) whether a directory is ignored; a directory git
tracks is treated as source and left alone.

| Analyzer | What it finds | Class | Cleanup |
|---|---|---|---|
| `xcode.derived-data` | `DerivedData/<Name>-<hash>`; workspace read from `info.plist` | Review. **Safe** when the recorded workspace no longer exists | Filesystem |
| | `ModuleCache.noindex` and other shared compiler caches | Review | Filesystem |
| `xcode.support` | Xcode Archives | Protected | — |
| | iOS / watchOS / tvOS / visionOS DeviceSupport, per OS version | Review | Filesystem |
| | CoreSimulator caches | Review | Filesystem |
| | Simulator devices | Protected | — |
| | Simulators whose runtime is gone (from `simctl`) | Review | `xcrun simctl delete unavailable` |
| `swiftpm` | `.build/<triple>/{debug,release}` next to a `Package.swift` | Review (build generation) | Filesystem |
| | `.build/{checkouts,repositories,artifacts,registry}` | Review | Filesystem |
| | `~/Library/Caches/org.swift.swiftpm` | Review | Filesystem |
| `python` | `.pytest_cache`, `.mypy_cache`, `.ruff_cache` | **Safe** | Filesystem |
| | `.tox`, `.nox` | Review | Filesystem |
| | `.venv` / `venv` containing `pyvenv.cfg` | Review, never by age, never automatic | Filesystem |
| | `build`, `dist` in a Python project, git-ignored | Review | Filesystem |
| | pip cache, uv cache | Review | Filesystem / `uv cache clean` |
| `node` | `node_modules` next to a `package.json` | Review | Filesystem |
| | `.next`, `.nuxt`, `.turbo`, `.parcel-cache`, `.svelte-kit`, `.angular` | Review (build generation) | Filesystem |
| | `dist`, `build`, `out`, only when git confirms they are ignored | Review | Filesystem |
| | npm, Yarn, Yarn Berry caches | Review | Filesystem |
| | pnpm store | Review; reclaimable amount not claimed | `pnpm store prune` |
| `rust` | `target/<profile>` next to a `Cargo.toml`, with Cargo's own markers | Review (build generation) | Filesystem |
| | Cargo registry archives, sources, git checkouts | Review | Filesystem |
| `go` | Build cache, module cache (locations from `go env`) | Review | `go clean -cache` / `-modcache` |
| | `go-build*` directories in the temp folder, older than a day | **Safe** | Filesystem |
| `cmake` | Directories containing `CMakeCache.txt` or `build.ninja` | Review (build generation) | Filesystem |
| `test-results` | `.xcresult` bundles in projects | Review | Filesystem |
| `docker` | Build cache, stopped containers, dangling images (from `docker system df`) | Review | `docker builder/container/image prune --force` |
| | Docker volumes, Colima and Lima disks | Protected | — |
| `ai-tools` | Claude Code, Codex, OpenCode, Hermes state | Protected | — |
| | Ollama, Hugging Face (incl. MLX), LM Studio models | Protected | — |
| | Claude Code cache in `~/Library/Caches` | Review | Filesystem |
| | Agent scratch directories in `/private/tmp`, untouched for three days | Review (heuristic) | Filesystem |
| `agent-registered` | Paths an agent marked disposable inside its own registered workspace | Review | Filesystem |

Where a tool has its own cleanup command PEPEL runs that command instead of deleting files.
`docker volume prune` and `docker system prune` are not in the list of commands PEPEL can run.

## Build generations and retention

A build generation is one artifact directory tied to a project: a DerivedData folder, a SwiftPM
triple/configuration, a Cargo profile, a framework output directory, a CMake tree. Worktrees of
one repository are reported together.

Retention is evaluated per repository, newest first:

1. Active builds are kept. Pinned builds are kept.
2. A build whose source no longer exists is a candidate.
3. The most recent build is kept.
4. The last *N* builds are kept (default 2). Builds whose outcome PEPEL did not observe count
   here: they may have been good.
5. The most recent build known to have succeeded is kept ("last known good").
6. The last *N* failed builds are kept (default 1).
7. Anything newer than the review threshold (default 48 h) is kept.
8. Optional maximum age: older builds become candidates unless protected by 1 or 3.
9. Budget: if what is kept still exceeds the project budget (default 40 GB), the oldest
   generations that are not hard-protected and are past the review threshold become candidates.

Candidates are classified **review**. With "treat builds retention marks obsolete as safe"
enabled they become **safe**, which lets automatic cleanup remove them. Artifacts PEPEL cannot
tie to a known project are never ranked against each other.

Budgets warn at 80 % and at 100 %. PEPEL cannot stop another tool from writing; it reports,
proposes and (when you opt in) cleans up afterwards.

### Build status and `pepel run`

For builds PEPEL did not launch it sees artifacts, timestamps and running processes, not the
outcome; the status is shown as *unknown*. Wrapping a build makes its lifetime and exit status
known:

```bash
pepel run -- swift build -c release
```

```bash
pepel run --enforce-budget -- xcodebuild -scheme App build
```

While the command runs the project counts as building. Afterwards the generation it wrote shows
*succeeded* or *failed*. With `--enforce-budget` a build is not started when the project is
already over its budget (exit status 75).

## Policy decisions

For each item the policy engine returns *allowed*, *needs confirmation* or *denied*.

| Condition | Result |
|---|---|
| Class protected, or no cleanup method | Denied |
| Path violates a structural rule (see [SECURITY.md](SECURITY.md)) | Denied |
| File identity differs from the scan | Denied |
| Protected by rule, pinned, or project excluded | Denied |
| Covered by an active lease | Denied |
| In use by a running process | Denied |
| Modified within the protection window | Denied |
| Agent session in the item's project | Automatic: denied. Manual: needs confirmation |
| Initiator is an agent | Denied (preview only) |
| Initiator is automatic, and automatic cleanup is off or the item is not safe | Denied |
| Class review, initiator user or CLI | Needs confirmation |
| Class safe, none of the above | Allowed |

## Removal modes

| Setting | Safe items | Review items |
|---|---|---|
| Automatic (default) | Removed permanently | Moved to the Trash |
| Always Trash | Trash | Trash |
| Always permanent | Removed permanently | Removed permanently |

Trashed items can be restored from the History view while they are still in the Trash; space is
reclaimed only when the Trash is emptied. Permanent removals and tool cleanups cannot be undone,
and PEPEL says so before you confirm.

## Monitoring modes

| Mode | Scans | Removes |
|---|---|---|
| Manual | Only on request | Only on request |
| Notify only (default) | In the background | Only on request |
| Automatic safe cleanup | In the background | Safe items the policy allows for the automatic initiator |

Also available: a global pause, quiet hours, battery-aware scheduling, excluded folders and
per-project exclusion (`pepel protect --kind project <path>`).

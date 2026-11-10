# Architecture

PEPEL is one Swift package. The app and the CLI are thin shells over the same engine.

```
PEPELApp ─┐                      ┌─ PEPELStorage ── PEPELProjects ─┐
          ├─ PEPELUI ─┐          ├─ PEPELBuilds                    │
PEPELCLI ─┴───────────┴─ PEPELEngine ─┼─ PEPELProcesses            ├─ PEPELCore
                                 ├─ PEPELMemory                    │
                                 ├─ PEPELAgents                    │
                                 ├─ PEPELCleanup                   │
                                 ├─ PEPELMonitoring                │
                                 └─ PEPELPersistence ──────────────┘
```

| Module | Responsibility |
|---|---|
| `PEPELCore` | Value types shared by everything: confidence, safety class, process identity, storage items, settings, path utilities, the tool runner. No behaviour that touches other modules. |
| `PEPELPersistence` | SQLite (WAL) wrapper and typed store: settings, telemetry and usage history, audit log, protection rules, leases, wrapped-build records, process observations. Multi-statement updates run in transactions. |
| `PEPELProjects` | Project discovery from `.git`, manifests and registered directories; git metadata read directly from `.git` files; longest-prefix attribution. |
| `PEPELProcesses` | Process enumeration (libproc, sysctl), role classification, process tree, activity analysis, the lifecycle guardian. |
| `PEPELMemory` | Interprets memory telemetry and assembles recovery proposals. |
| `PEPELStorage` | The analyzer protocol, the analyzers, the directory sizer and the scan coordinator. |
| `PEPELBuilds` | Build generations, the retention engine, budgets, the `pepel run` wrapper. |
| `PEPELAgents` | Agent session detection, the agent API service, the Unix-socket server and client. |
| `PEPELCleanup` | The policy engine, usage inspection, the cleanup executor, the process terminator. |
| `PEPELMonitoring` | Telemetry reader, FSEvents change watcher, the cadence policy. |
| `PEPELEngine` | `PepelEngine` (the facade actor) and `MonitorService` (the background loop). |
| `PEPELUI` | SwiftUI views, theme, the main-actor `AppModel`. No filesystem or process code. |

## The path of a cleanup

1. **Discover.** An analyzer lists candidates cheaply and describes each as a `StorageItem`:
   category, base safety class, explanation, cleanup method, recorded file identity (device +
   inode). Analyzers contain no deletion code.
2. **Measure.** `ScanCoordinator` removes overlapping items (a nested item is folded into the
   outer one, which inherits the stricter class), then measures sizes with bounded concurrency
   (four at a time). A shared hard-link ledger keeps data shared between items from being counted
   twice. Measurements of items nothing changed under are reused.
3. **Contextualise.** `UsageInspector` matches items against running processes;
   `BuildGuardian` groups build artifacts into generations and applies retention.
4. **Decide.** `CleanupPolicyEngine.evaluate` returns allowed / needs confirmation / denied with
   reasons. `approve` turns a plan into `ApprovedAction` values.
5. **Execute.** `CleanupExecutor` accepts only `ApprovedAction`. For each item it asks for a fresh
   policy context, evaluates again, runs the analyzer's shape validation, compares the file
   identity, looks for recent writes, and only then acts. Each outcome is written to the audit log.

`ApprovedAction` and `ApprovedTermination` have internal initialisers inside `PEPELCleanup`. Code
outside that module — analyzers, the agent API, the UI, the CLI — cannot construct one, so it
cannot reach the executor or the terminator except through the policy engine.

### Permanent removal

The executor renames the directory to a sibling `.pepel-removing-<uuid>` first. `rename` is
atomic, so the object deleted afterwards is the one that was validated even if something recreates
the original path in between. After the rename the inode is compared once more; on mismatch the
directory is renamed back untouched.

## Process identity and lifecycle

A process is identified by PID **and** kernel start time (`ProcessIdentity`). A parent link is
trusted only if the parent started no later than the child. Before any signal, the terminator
checks that the PID still has the assessed identity.

`ProcessGuardian` combines independent observations: role, live ancestors, agent ancestry,
controlling terminal, listening ports, whether the working directory still exists, project
ownership, and CPU activity of the whole process tree over the observation window. A dead parent
alone never makes a process abandoned.

| Lifecycle | Typical evidence | Automatic termination |
|---|---|---|
| agent session | recognised agent process | never |
| active build or test | live parent, terminal or agent ancestor, CPU activity | never |
| active dev service | server with a live parent | never |
| background service | detached server, protected by rule, container runtime | never |
| abandoned subprocess | build/test tool, parent gone, tree idle for the whole window | only if enabled, ownership verified, no terminal, no port |
| suspicious orphan | orphaned but still working, or working directory gone | never |
| unknown | not observed long enough | never |

## Monitoring

`MonitorService` sleeps between light samples (telemetry + process table). `CadencePolicy` picks
the interval: 10 s normally, 4–6 s under memory pressure, 30 s on battery, 45 s when the user is
idle. A storage scan runs at most every 30 minutes (four times less often on battery or in quiet
hours), only when FSEvents reported changes, and waits for active builds to finish (up to three
hours). FSEvents is used at directory granularity with a 15-second latency.

## State

`~/Library/Application Support/PEPEL/` (mode 0700): `pepel.sqlite`, `pepel.sock`, `api-token`.
`PEPEL_HOME` and `PEPEL_SUPPORT_DIR` redirect both the app and the CLI to another tree, which is
how the fixtures and the screenshot renderer run without touching real state.

## Extending

- **New analyzer:** implement `StorageAnalyzer` (`discover` + `validate`) and add it to
  `AnalyzerRegistry`. It needs no access to the cleanup module.
- **New agent:** add a case to `AgentKind` and a rule in `RoleClassifier.agentKind`.
- **MCP:** `AgentAPIService.handle(op:args:)` is transport-independent; an MCP server can call it
  directly with the same narrow operation set.

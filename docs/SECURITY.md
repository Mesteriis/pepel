# Security and permissions

## Permissions

PEPEL runs as the logged-in user and asks for nothing more.

| Permission | Requested | Why / what happens without it |
|---|---|---|
| Full Disk Access | No | Folders macOS protects are reported as unreadable; their sizes become lower bounds. `~/Documents`, `~/Desktop` and `~/Downloads` are not scanned by default so no privacy prompt appears. Adding one of them as a project root makes macOS ask once. |
| Administrator rights | No | Only the current user's processes are inspected or signalled. |
| Accessibility | No | Not used. |
| Notifications | On first alert | Without it PEPEL still shows alerts in the popover and dashboard. |
| Login item | When you enable "Launch at login" | Uses `SMAppService`; macOS may ask for approval in System Settings. |
| Privileged helper | None | Nothing PEPEL does needs one. |

PEPEL does not disable SIP, work around TCC or change system security settings.

## Distribution model

The app is **not sandboxed**. An App Sandbox app cannot enumerate other processes' arguments and
working directories, cannot signal them, and cannot read `~/Library/Developer` or arbitrary
project directories, which is the whole job. PEPEL is therefore distributed as a Developer ID /
ad-hoc signed app outside the Mac App Store. `Scripts/build-app.sh` produces an ad-hoc signed
bundle for local use; distributing it to other Macs requires a Developer ID signature and
notarisation, which this repository does not set up.

## What is never deleted

Enforced in `CleanupPolicyEngine`, independently of what any analyzer reports:

- Paths outside the home directory and the temporary folders; the home directory itself and its
  top-level folders.
- Anything containing or inside a git working tree's `.git`; any directory that is, or contains,
  a known project root (source code, including uncommitted changes).
- `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.kube`, `~/.azure`, `~/.netrc`, `~/.config/gh`,
  `~/.config/gcloud`, `~/.config/op`, `~/Library/Keychains`.
- `~/.claude`, `~/.codex`, `~/.hermes`, `~/.config/opencode`, `~/.local/share/opencode`
  (agent sessions, history, credentials).
- `~/.ollama`, `~/.cache/huggingface`, `~/.lmstudio` (model weights).
- `~/Library/Application Support`, `Containers`, `Group Containers`, `Preferences`, `Mail`,
  `Messages`, `Mobile Documents` (application state).
- Xcode archives, simulator devices, Docker volumes, Colima/Lima disks.
- Symbolic links, and paths that pass through one.
- Items in use by a running process, leased, pinned, protected by rule, or modified within the
  last ten minutes (configurable).

## Time of check, time of use

Between a scan and a cleanup the filesystem can change. The executor therefore, per item and
immediately before acting:

1. rebuilds the policy context from the current process table, leases and rules, and evaluates
   the item again;
2. runs the owning analyzer's validation;
3. compares device and inode with the identity recorded at scan time and refuses symlinks;
4. looks for files written inside the directory within the protection window;
5. for permanent removal, renames the directory aside atomically, compares the inode again, and
   deletes the renamed object.

Deletion uses `FileManager`, which removes symlinks without following them. No shell is involved
and there is no recursive-delete command line anywhere in the project.

## Process termination

- PEPEL only signals processes of the current user that it classified as developer workloads.
- Agent sessions, active builds and tests, container runtimes, protected services, applications
  and system processes are refused, also when asked explicitly.
- Two opt-in automatic rules exist beyond abandoned builds and tests. **Sleeping agent sessions**
  (`terminateSleepingAgents`): a session with no disk writes, CPU bursts, new processes or builds
  for the whole sleep window; agent binaries running as servers for an application are excluded.
  **Leftovers of quit applications** (`terminateAppLeftovers`): processes PEPEL saw an application
  start, or that run from inside its bundle, still alive after the application quit and a grace
  period; system-managed components (XPC services, extensions, login items), agent sessions and
  container runtimes are excluded. Both are off by default.
- Identity (PID + start time) is verified right before each signal.
- `SIGTERM` first; PEPEL waits for the exit. `SIGKILL` only when you ticked the box for that
  specific request; never automatically.
- Memory pressure, memory used and swap are sampled before and after and written to the audit
  log. PEPEL reports the observed change; it does not claim the process's footprint was freed.
- No `purge`, no memory ballooning, no undocumented kernel calls.

## Local agent API

- Unix-domain socket at `~/Library/Application Support/PEPEL/pepel.sock`, mode 0600, inside a
  0700 directory. Nothing listens on the network.
- Each request must come from the same user id (`getpeereid`) and carry the bearer token stored
  in `api-token` (mode 0600, 256 bits from the system random generator, compared in constant time).
- Operations: `ping`, `status`, `scan.request`, `cleanup.preview`, `lease.acquire`,
  `lease.renew`, `lease.release`, `lease.list`, `build.register`, `workspace.register`,
  `artifact.disposable`, `artifact.protect`, `task.complete`.
- There is no operation that deletes a file or signals a process. In the policy engine the
  `agent` initiator is denied for every cleanup and every termination.
- A disposable mark is accepted only inside a workspace the same agent registered, and only puts
  the path on the user's review list.
- Leases are capped at 24 hours. An expired lease stops protecting; it never makes something
  deletable. Whether the path can be cleaned is decided afterwards by the normal usage checks.

Threat model note: any process running as the same user can already read the token file and the
database, as it can read your source code. The socket permissions and the token keep out other
users and accidental callers; the narrow operation set is what limits a participating agent.

## Containers

- PEPEL reads Docker through `docker info`, `docker stats --no-stream` and `docker ps`.
- It can **stop** the containers of a compose project (`docker stop`): by hand with confirmation,
  or automatically (`stopContainersOfIdleProjects`, off by default) once the project has had no
  agent session for `projectIdleGraceMinutes` (60). Containers and volumes are kept. Never
  stopped automatically: containers not tied to a project, containers on the keep list or
  labelled `pepel.keep=true`, excluded or leased projects, projects with a running session.
- It can **restart the Docker Desktop VM** (`docker desktop restart`) and start the same
  containers again. Manual only, always confirmed; a VM restart cannot spare a container, so
  kept containers are named in the warning.
- It never runs `rm`, `down`, `kill`, `prune` on volumes, or anything else that removes data.

## Agents' instruction files

`pepel agents instructions --install` adds a short note about PEPEL to each installed agent's
global instruction file (`~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`,
`~/.config/opencode/AGENTS.md`, `~/.hermes/SOUL.md`). It runs only when asked. The note sits
between `PEPEL:BEGIN` and `PEPEL:END` markers, is replaced in place on update, and `--remove`
takes it out leaving the rest of the file as it was. The first version of each changed file is
copied to PEPEL's support directory. These are the only writes PEPEL ever makes inside an
agent's directory.

## Secrets

- Only the argument vector of a process is read. The environment block that follows it in the
  kernel buffer is never parsed.
- Command lines are passed through `ArgumentRedactor` before being shown, logged or stored:
  values of flags and `KEY=value` pairs whose name looks like a credential are masked, as is the
  user-info part of URLs.
- Credentials embedded in git remote URLs are stripped when repository metadata is read.
- External tools are run by absolute path from a fixed list of directories, with a minimal
  environment and a timeout.

## Reporting a vulnerability

Please open a private security advisory on the repository rather than a public issue.

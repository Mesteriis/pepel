# Security and permissions

## Permissions

PEPEL runs as the logged-in user and asks for nothing more.

| Permission | Requested | Why / what happens without it |
|---|---|---|
| Full Disk Access | No | Folders macOS protects are reported as unreadable; their sizes become lower bounds. `~/Documents`, `~/Desktop` and `~/Downloads` are not scanned by default so no privacy prompt appears. Adding one of them as a project root makes macOS ask once. |
| Administrator rights | Only for "Flush the file cache" | Only the current user's processes are inspected or signalled. Flushing the file cache runs the system's `purge`, which needs an administrator. The first flush shows the standard macOS prompt once and, with that approval, installs one sudo rule allowing this user to run exactly `/usr/sbin/purge`; later flushes do not ask. PEPEL stores no password and installs no helper. Dismiss the prompt and nothing is installed or flushed. |
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
- **Processes living in swap** (500 MB or more charged, at most 15% of it in RAM, under 1% of a
  core over what PEPEL has watched) are listed, excluding application bundles, system paths,
  agent sessions and the virtual machine. PEPEL does not know what such a process is for, so it
  is ended only on a confirmed request from a person, never automatically.
- **Old copies inside agent servers**: PEPEL cannot see conversations, so inside an agent's
  long-lived server it marks only an older copy of a program the server has since started
  again, idle for `serviceBranchIdleMinutes`. Ended only on a person's request.
- **Browser tabs**: renderer processes of known Chromium-based browsers (never Electron
  applications, extension hosts or GPU processes) idle for `tabIdleMinutes` can be ended on
  request, which unloads the tabs; they reload when opened, losing unsent form input.
- **System components**: Dock, Finder, SystemUIServer, ControlCenter, NotificationCenter,
  chronod and Spotlight are kept alive by launchd, so ending one restarts it. PEPEL offers that
  for a component holding 300 MB or more, on request only, and touches nothing else under `/System`.
- Identity (PID + start time) is verified right before each signal.
- `SIGTERM` first; PEPEL waits for the exit. `SIGKILL` only when you ticked the box for that
  specific request; never automatically.
- Memory pressure, memory used and swap are sampled before and after and written to the audit
  log. PEPEL reports the observed change; it does not claim the process's footprint was freed.
- No memory ballooning and no undocumented kernel calls. `purge` is used only by the
  "Flush the file cache" step described below, never as a substitute for stopping what holds
  memory and never automatically.

### Suspending agent sessions

PEPEL can suspend (`SIGSTOP`) an agent session with everything it started instead of ending it.
Nothing is lost, and a suspended tree gets no CPU, so its memory is never touched again and is
what macOS compresses and swaps out first. By hand: `pepel freeze <pid>`, the Agents section, or
the "Suspend quiet agent sessions" step of Free memory. Automatically (`freezeIdleAgents`, off by
default): after `freezeAfterMinutes` (20) of quiet, and only when PEPEL knows which application
the session lives in and that application is not in front.

- Never suspended: a working session, one with a build or test running, an agent binary running
  as a server for an application, the session PEPEL itself runs in, sessions of another user.
  Agents cannot ask for it.
- A suspended session is woken (`SIGCONT`): the moment its application comes to the front; when
  a short periodic peek (`freezePeekMinutes`, 10) finds it using CPU, meaning work arrived;
  before it is terminated; when PEPEL is paused, quits, or starts again after a crash; with
  `pepel thaw [<pid>|--all]`. A session that was just woken is left alone for a full quiet period.
- The list of suspended trees is kept in the store, so it survives PEPEL being killed. If PEPEL
  is killed and not started again, `pepel thaw --all` wakes everything.
- While suspended, a session cannot answer: anything talking to it over a socket waits.

### Applications

PEPEL records what each application, agent session and tool holds every five minutes (kept for a
week) and reports **steady growth**: at least two hours of readings in which the typical level
rose by 1 GiB and by half without dipping. A spike or a merely large application is not growth;
a restart starts the count over.

It can ask an application to **quit, or quit and open again** (`pepel apps restart|quit <name>`,
the Memory section, a Free memory step that is never preselected). The request is the ordinary
one an application gets from the Dock, never a signal: an application with unsaved changes asks
about them, and one that is still running after 30 seconds is left running and not reopened.
Refused: for agents and the automatic pass; for an application with agent sessions, builds, tests
or servers running inside it (a terminal, an editor with an agent); for PEPEL and the application
it runs in; for system components under `/System/Library`.

**Unused applications** are only listed: an ordinary application, not in front for
`unusedApplicationHours` (6) as far as PEPEL has seen, using under 2% of a core over the last
hour (so a music player or a syncing client is not mistaken for unused), holding at least
200 MB, and not named in `keepApplications`. Quitting one is the same confirmed request as above.

### Free memory

"Free memory" (popover button, `pepel free`) is one pass over what PEPEL can already stop:
abandoned developer processes, leftovers of quit applications, sleeping agent sessions,
containers of projects no agent works in, and a Docker VM restart. It first shows the plan and
does nothing until confirmed. Each step goes through the same policy decision as when done one
by one, so anything policy refuses is reported and skipped. Idle (not yet sleeping) sessions and,
while a session is working or a container is kept, the VM restart are offered but not
preselected; working sessions are never offered. Agents cannot run it.

The last step, **Flush the file cache**, runs `/usr/sbin/purge`. The first time it goes through
the macOS administrator prompt, which says that PEPEL also asks to be allowed to flush without
asking again. With that approval PEPEL writes `/private/etc/sudoers.d/pepel-purge`, root-owned
and read-only, containing one line:

    #<your user id> ALL=(root) NOPASSWD: /usr/sbin/purge ""

The line is checked with `visudo` before it is installed; the only variable part is the numeric
user id; `""` forbids arguments; `purge` sits on the sealed system volume and cannot be swapped.
Nothing else gains root. Later flushes run `sudo -n /usr/sbin/purge`. `pepel free permission`
shows the state and `--revoke` (or "Remove permission" in Settings) deletes the file, which asks
for an administrator once more. A flush turns cached file pages into
free pages and nothing else: memory used by applications, compressed memory and swap are
unchanged, and macOS fills the cache again as files are read. PEPEL therefore does not count it
in "up to N GB" and reports it separately as cached files and free memory before and after. Only
a person can start it, also after the permission exists; the automatic pass and agents are
refused by policy.

The result is the measured before/after of memory used, free memory, cached files, compressed
memory, swap and pressure.

### Standing instructions and budgets

Free memory can also run without the plan being shown first: from the button on a memory
pressure notification, and, with `freeMemoryOnLock` (off by default), whenever the screen is
locked. In both cases only the steps the plan preselects are run, and never one that would raise
a prompt (the cache flush is skipped until its permission exists). The global shortcut
(`freeMemoryHotkey`, Control-Option-Command-M, off by default) only opens the plan; it is
registered through the system hot key service, which needs no Accessibility permission.

A **memory budget** (`pepel budget set <owner> <GB>`, by owner name or `kind:<kind>`) raises an
alert when an owner holds more. It never ends, suspends or restarts anything.

### Forecast, swap and the daily summary

These only report. The **forecast** is a straight line through the last 90 minutes of readings,
shown only when memory in use rose steadily (at least 20 minutes, 1% of memory an hour, a line
that explains most of the variation) and would reach 90% of physical memory within three hours;
that 90% is an estimate of where macOS starts to struggle and is described as such. **Swap on
disk** is read from `/System/Volumes/VM` (file sizes only). The **daily summary** is built from
the audit log, so it says what was recorded, and can be sent once a day (`dailySummary`).

### Memory journal

While the PEPEL app runs it writes a reading every five minutes to
`~/Library/Application Support/PEPEL/journal/YYYY-MM-DD.jsonl` (directory 0700, files 0600):
memory in use, wired, compressed, cached, free and swap; the 25 largest owners; every agent
session (agent, project name, state, whether suspended, memory, quiet time); every browser
(memory, tab processes, idle ones); how many things PEPEL saw that could be acted on; and what
it did since the previous reading. Names only: no command lines, arguments or paths. Nothing
leaves the Mac. `journalEnabled` switches it off, `journalRetentionDays` (30) removes older
days, `pepel journal` and the History section summarise it. One-off commands never add readings.

### Under memory pressure

With `adaptToMemoryPressure` on (off by default), waiting periods of rules that are already
enabled shorten: half under elevated pressure, a quarter under critical pressure, with floors of
30 minutes for an agent session and 15 minutes for a project's containers. The Docker VM may
then restart outside its night window, at most every six hours, and still never while an agent
session is working or a kept container is up.

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
- It can **lower the VM's memory limit** (`pepel containers limit <GiB>`). Measured on Docker
  Desktop 4.97: dropping caches inside the VM frees guest memory but the Mac is charged the same,
  because the VM has no working balloon; only a restart gives memory back and only a lower limit
  keeps it from growing again. The change is manual and confirmed, refused below a quarter above
  the most the containers were seen to use (14 days) plus 1 GiB, and written to
  `settings-store.json` while Docker Desktop is stopped, keeping every other key. The original
  file is copied to PEPEL's support directory once.
- It can **pause** a project's containers instead of stopping them (`idleContainerAction`,
  `pepel containers pause|unpause`). Nothing is lost. PEPEL remembers which containers it paused
  and resumes exactly those when an agent session starts in the project; containers someone else
  paused are left alone.
- It never runs `rm`, `down`, `kill`, `prune` on volumes, or anything else that removes data.

## Disk cleaning beyond single artifacts

Everything below is off by default as an automatic rule, available on request, refused for
agents, and recorded in the audit log with measured figures. Daily rules run once in twenty
hours, or once an hour while free space is below the low-disk threshold.

**Keep markers.** A folder that holds a file named `DO_NOT_CLEAN.txt`, `DO_NOT_CLEAN` or
`.pepel-keep`, or carries the extended attribute `com.avm.do-not-clean` or
`dev.pepel.do-not-clean`, is never cleaned by any rule, nor is anything inside it. A marker is a
person's decision and outranks every rule PEPEL has.

**Docker** (`pepel docker`, Storage section). Stopped containers count from when they stopped,
images from when they were last pulled or built, build cache from its last use. Removal names
every object by identifier and never uses force, so Docker itself refuses anything that came
into use meanwhile. Left alone: containers of a compose project that is running or that an
agent works in, the keep list and the `pepel.keep` label. **Named volumes are never
candidates.** Anonymous volumes that nothing mounts can be removed on request only. After
removal the VM's filesystem is trimmed from a one-off privileged container of a local
Alpine/BusyBox image (nothing is pulled), which is what shrinks the disk image on the Mac.

**Projects left untouched** (`pepel projects stale`). A project's last activity is the newest
of git's own bookkeeping (index, HEAD, its log) and the project's files outside generated
directories; an agent session in it counts as now. For projects untouched for
`staleProjectDays`, only environments, installed dependencies, build output and project-local
caches are affected: what installing or building again recreates. Source, git data and
configuration never are. Linked worktrees are outside this rule. Every item still passes the
ordinary policy (in use, recently written, leased, pinned, excluded project).

**Tool caches** (`pepel caches`). A fixed list of home-relative cache locations; nothing else is
ever walked. Entries not read or written for `cacheUnusedDays` go; with `cacheSizeLimitGB`, the
least recently used above the limit go too, but never anything used in the last day. Stores of
independent files are trimmed file by file; caches of unpacked packages lose whole entries
only. A cache is skipped while its tool is running, and when it is a link. Gradle is left to
its own cleanup.

**Application caches** (`pepel apps caches`). Folders directly inside `~/Library/Caches`,
excluding `com.apple.*`, the tool caches above and `keepAppCaches`. Removed only when the
application is not running and nothing in the folder was used for `appCacheUnusedDays`; folders
PEPEL cannot tie to an application only on explicit request. **Leftovers of removed
applications** elsewhere in the Library are only ever moved to the Trash, on request.
`~/Library/Containers` is not read at all.

**Temporary folder** (`pepel disk temp`, `cleanTempFiles`, off by default). Entries directly
inside the user's temporary folder that nothing has read or written for `tempDays` (7). Left
alone whatever their age: sockets and pipes and folders holding one, `com.apple.*` and other
entries macOS manages, entries named after a running program or one a running program works in,
entries of another user, links and marked folders. Each entry is inspected again right before
removal.

**Large folders git ignores** (`pepel projects ignored`). Git is asked which folders each
project ignores; those no analyzer knows are measured (hard links once, outermost folder only)
and listed with a "looks like data" flag for names such as `data`, `postgres` or `backups`.
Secrets (`.env*`, `.ssh`, `secrets`), agents' folders (`.claude`, `.codex`, `worktrees`) and
linked worktrees are never listed. One can be moved to the Trash on a person's request after
the usual checks; PEPEL never removes these on its own.

**Android emulators** (`pepel disk emulators`). Listed with size and last use; a person can
delete chosen ones, which removes the `.avd` folder and its `.ini` as Android Studio does. A
running emulator (by its process, or by a lock some process holds) and a marked one are refused.
The daily rule (`cleanAndroidEmulators`, off by default) deletes emulators not started for
`emulatorUnusedDays` (30), except those named in `keepEmulators`; each candidate is checked again
right before deletion.

**Android system images** (`pepel disk images`). An image in the SDK's `system-images` that no
emulator names in its `config.ini` can be deleted on request or by the daily rule
(`cleanUnusedSystemImages`, off by default); one an emulator uses is refused.

**Clausona backups** (`pepel disk backups`, `cleanToolBackups`, off by default). Folders
Clausona makes before it switches profiles or migrates history: under
`~/.local/state/clausona-{codex,desktop}/backups` and the `before-*` folders under
`~/.local/share/clausona-setup/<date>`. Retention keeps the newest `toolBackupsKeep` (1) of each
set and removes the rest once they are `toolBackupsDays` (7) old. The live Codex and Claude
history is never part of it; nothing is removed while Clausona holds its switch lock. These
copies are often APFS clones of the live files, so the space recorded is the measured change in
free space, not the sum of their sizes. Removal of these backups was allowed by the owner on
11.11.2026.

**Named Docker volumes** (`pepel docker volumes`). A report of the named volumes no container
mounts, with their compose project and whether that project's folder is still on this Mac.
PEPEL never removes them. The Docker disk image's limit is shown and never changed: lowering it
in Docker Desktop deletes the disk image with everything in it.

**Large old files and copies** (`pepel disk files`). A report only: files of 500 MB or more not
opened for 90 days, and files of 100 MB or more with identical contents (same size, then the
same SHA-256; two names of one file are not copies). Library, caches, agents' folders,
dependency folders and guarded folders are left out.

**Logs and other places** (`pepel disk`). Log files in `~/Library/Logs` older than `logDays`
and larger than 1 MB can be removed; agents' own logs never. Emulators, language versions,
device support and tool data are sized and shown with their last use, and not removed.
Model weights are protected and are not offered for removal anywhere.

## Disk map

The Disk map (`pepel disk map`, the Disk map section) only measures: it reads file sizes with
`lstat`, never file contents, never follows a link below the starting folder and never leaves
the volume. It starts at the whole disk and measures folder by folder: each folder directly
inside the one on screen is walked on its own and its tile appears when it is done. Other
volumes, device nodes and the data volume's second mount point under `/System/Volumes` are
skipped, so nothing is counted twice. At the top of the disk the space the disk reports as used
but no readable folder accounts for (system data, other users, guarded folders, snapshots) is
shown as one "Not measured" tile; PEPEL does not ask for Full Disk Access to resolve it. Folders macOS guards (Documents, Desktop, Downloads, Pictures, the Trash, Mail,
Messages, Safari, iCloud and application containers) are shown as closed tiles and are not read
until the user opens one, because reading them makes macOS ask for access. The measured sizes
of the largest folders are kept in PEPEL's database so the map opens at once next time.

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

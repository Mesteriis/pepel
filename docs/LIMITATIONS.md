# Known limitations

Stated plainly so that nothing in the UI is mistaken for more than it is.

## Storage accounting

- **APFS clones are invisible.** macOS offers no cheap way to tell that two files share blocks
  through copy-on-write. Cloned data (for example packages `uv` clones from its cache into a
  virtual environment) is counted in both places, so sums can overstate real usage and removing
  one copy can free less than shown. Sizes are therefore labelled as upper bounds, not promises.
- **Snapshots keep blocks alive.** With local Time Machine snapshots, removed files free space
  only when the snapshot expires. PEPEL reports the observed change in available space next to
  its estimate so the difference is visible.
- **Hard links** are counted once per scan, in whichever item was measured first; the others
  show a lower figure and are marked approximate.
- **Unreadable folders** make a size a lower bound; the count of unreadable entries is shown.
- **Trashed items** free nothing until the Trash is emptied.
- Docker figures come from `docker system df`. The "reclaimable" number Docker reports for images
  includes unused tagged images, which PEPEL does not prune; the amount actually freed is smaller.
- The amount `pnpm store prune` will free is not known in advance and is not claimed.

## Builds

- The outcome of a build is known only for builds run through `pepel run`. For everything else
  the status is *unknown* and such builds are kept under the "last N builds" rule.
- Branch and commit shown for a generation are the project's **current** ones, not necessarily
  those it was built from (accurate for one-branch-per-worktree workflows, approximate otherwise).
- Plain `make` output has no reliable marker and is not detected. Go has no per-project build
  directory; only its shared caches are tracked.
- Xcode test results and logs inside DerivedData are part of their DerivedData generation, not
  separate items.
- PEPEL cannot prevent tools from writing. Budgets warn and drive proposals; hard enforcement
  exists only as `pepel run --enforce-budget`, which declines to start a build.

## Processes and agents

- Only the current user's processes are visible without elevated rights.
- A process started moments ago cannot be judged: abandonment needs the full idle window (30
  minutes by default) of observation. Observations survive restarts of the app for three hours.
- Role classification is by executable name and command line. An unusual wrapper script is
  classified as a generic project binary, which is never terminated automatically.
- Agent sessions are recognised by process name (`claude`, `codex`, `opencode`, `hermes`).
  PEPEL does not read agent session files, so it knows a session's working directory and process
  tree, not which task it is on. A binary named `hermes` that is not the Hermes agent would be
  misread as one (the effect is extra protection, not deletion).
- Which Xcode workspace the Xcode app has open is not visible; DerivedData is protected through
  recent writes and running build processes instead.
- Leases and disposable marks require an agent to cooperate through the API or `pepel agent`.
- A sleeping agent session cannot be told apart from one waiting for the user's reply: neither
  does any work. With `terminateSleepingAgents` on, both are terminated after the sleep window.
- "Work" is inferred from disk writes together with CPU, calibrated on Claude Code sessions
  (idle ones write 8–24 KB about once an hour at idle CPU; working ones write hundreds of
  kilobytes at 1–5 %). Another agent with different habits may need different thresholds, and
  a very light exchange — one short prompt answered at idle CPU — could go unnoticed.
- Leftovers of a quit application are only known for quits PEPEL observed (it has to have seen
  the application running first). A helper an application leaves running on purpose looks the
  same as a forgotten one, which is why automatic termination of leftovers is opt-in.

## Platform and distribution

- Not sandboxed, by necessity (see [SECURITY.md](SECURITY.md)); not suitable for the Mac App Store.
- The build script signs ad hoc. Developer ID signing and notarisation are not set up.
- Launch at login requires the app to run from its bundle, ideally in `/Applications`.
- Verified on macOS 27 / Apple Silicon. The deployment target is macOS 14; older systems and
  Intel Macs were not tested.
- The local API socket path must fit the 104-byte limit of Unix sockets, which the default
  support directory does; a very long custom `PEPEL_SUPPORT_DIR` disables the API.
- The menu bar item itself cannot be screenshotted without screen-recording permission;
  `Scripts/screenshots.sh` renders the same views off-screen instead.

## Menu bar managers on macOS 27

On macOS 27, Hidden Bar (1.11+) no longer hides icons by stretching a separator. When it
collapses it reads, through Accessibility, which apps have an icon to the right of its arrow and
hands macOS an allow-list of those apps; macOS hides every other third-party icon itself.

What was established on a real machine, by reading the menu bar layout through Accessibility
while Hidden Bar collapsed:

- **PEPEL must run from `/Applications`.** Started from the build folder in the home directory
  it was hidden on every collapse, wherever its icon stood and however it was signed. The same
  bundle, signed with a development certificate and copied to `/Applications`, stays visible.
  `Scripts/install.sh` installs it there. Another ad-hoc signed app run from `~/Applications`
  behaved the same way as the uninstalled PEPEL. Whether an *ad-hoc signed* PEPEL in
  `/Applications` is enough was not tested; the build script signs with a real identity when one
  exists.
- **An app started while Hidden Bar is collapsed stays hidden until Hidden Bar is expanded and
  collapsed once more**, because the allow-list is rebuilt only on collapse. This applies to
  every app and is Hidden Bar's documented behaviour. PEPEL notices that macOS gave its icon no
  place, says so in the Overview and in a notification, and opening `PEPEL.app` again always
  shows the dashboard.
- A hidden icon keeps reporting its last position, so an app cannot tell that it was hidden
  *after* it had been placed; PEPEL only detects the case where it was never placed.

PEPEL records where macOS placed its icon in
`~/Library/Application Support/PEPEL/menubar-placement.log` (a zero-height frame means "not
shown"). macOS does not let an app read the "Allow in the Menu Bar" switch or another app's
allow-list.

## Not implemented

- Per-project retention overrides exist in the settings model and the engine
  (`projectRetention`) but have no editor in the UI yet; use `pepel config set projectRetention '{…}'`.
- No MCP server yet. The agent API service is transport-independent so one can be added.
- No localisation; the interface is English only.
- Memory "growth over time" is shown per process since PEPEL started observing it; there is no
  long-term per-process memory history.

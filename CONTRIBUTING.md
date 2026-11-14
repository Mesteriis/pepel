# Contributing

Thanks for helping. PEPEL removes files and stops processes on people's machines, so the bar for
changes that act is high; changes that only report are always welcome.

## Getting started

```bash
swift build
```

```bash
swift test
```

`Scripts/build-app.sh release` builds `dist/PEPEL.app`; `Scripts/install.sh` installs and starts it.

## Ground rules

- **Safety first.** Read [docs/SECURITY.md](docs/SECURITY.md). Anything that deletes, moves or stops
  goes through the policy engine, is re-checked at the moment it acts, is written to the audit log,
  and is never available to the agent API. Automatic rules are off by default.
- **Tests never touch real files.** Use `Fixture` (a temporary home) and the fake process source;
  never call a real tool from a test.
- **CLI and app stay equal.** Every setting has a control in Settings, and every action exists both
  as a `pepel` command and in the app.
- **Texts are localizable.** Use `Text("…")`, a literal passed to a PEPEL primitive, or
  `L("… \(count) …")`; one sentence is one key. Run `Scripts/sync-strings.sh` and add the Russian
  translation in `Resources/Localizable.xcstrings`. Codes that code compares stay English.
- **Measure, do not guess.** A figure shown to a person is measured or labelled as an estimate.

## Pull requests

Keep a pull request to one change, with tests for behaviour that changed, `swift test` passing,
and the README or docs updated when commands, settings or behaviour change.

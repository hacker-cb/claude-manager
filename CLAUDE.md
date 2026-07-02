# Claude Manager — project context

Native macOS (SwiftUI) app to run multiple Claude Desktop accounts via **thin
launcher apps**. Read [README.md](README.md) for user-facing docs; this file holds
the engineering context and the hard-won macOS facts behind the design.

## Layout

```
Package.swift                     # SwiftPM: ClaudeManagerCore lib + tests (headless)
project.yml                       # XcodeGen spec → ClaudeManager.xcodeproj (generated, git-ignored)
Sources/ClaudeManagerCore/        # all logic — no SwiftUI, testable with `swift test`
Sources/ClaudeManagerApp/         # thin SwiftUI app (Window + MenuBarExtra + Settings)
Tests/ClaudeManagerCoreTests/     # Swift Testing suites (+ opt-in LiveIntegrationTests)
scripts/                          # app-icon generator + release (build/dmg/notarize)
.github/workflows/                # ci.yml (PR + trunk), release.yml (v* tags)
```

Everything the app does is in `ClaudeManagerCore`; the SwiftUI layer is a thin
shell over `ProfileStore`. Keep it that way — logic goes in the core (and gets a
test), views stay declarative.

## Why thin launchers (verified experimentally, macOS 26 / Apple Silicon)

Claude Desktop (Electron) has **no single-instance lock** and honors
`--user-data-dir`. One user-data-dir == one isolated account (cookie `sessionKey`
+ `safeStorage` token blobs live inside it). Multi-account == multiple instances on
different user-data-dirs. Ways to wrap that, all tested:

| Wrapper | Outcome |
|---|---|
| Script launcher execing the real binary | ✓ works — **this tool** |
| Bundle with symlinked binary/Frameworks | ✗ `open` fails (-54) or SIGKILL |
| Hardlink farm | ✗ instant SIGKILL by AMFI |
| APFS clone + ad-hoc re-sign | ✓ runs, ✗ entitlements stripped |
| Full copy + ad-hoc re-sign | ✓ runs, ✗ entitlements stripped, 700+ MB |

Ad-hoc re-signing strips Anthropic's entitlements → notifications
(`usernotificationsd` rejects the modified bundle id) and virtualization features
(`virtualization_entitlement_missing`) break. The thin launcher runs the untouched
signed binary → everything keeps working and Claude self-updates transparently.

## The source of truth

Each launcher's `Contents/Info.plist` carries a `ClaudeManagerLauncher` marker
dict (`name`, `label`, `color`, `profile`, `schemaVersion`). Scanning the install
directory for that key is how launchers are discovered — there is no external
registry the app depends on. A JSON file in `~/Library/Application Support/Claude
Manager` holds GUI-only metadata (ordering, notes) and is always optional.

## macOS facts baked into the code

- **Keep `CFBundleIconName` OUT of launcher Info.plists** — when present, macOS
  reads the icon from `Assets.car` and ignores our `.icns`. We write only
  `CFBundleIconFile = Badge.icns`.
- **Icon cache is sticky**: after writing a bundle's `.icns`, run `lsregister -f`,
  `touch`, and `killall Dock`. `killall Dock` flashes the screen, so it is gated
  (`IconCache.refresh(restartDock:)`): a brand-new bundle skips it (nothing cached
  for that path); a forced rebuild, a same-named twin in Trash, or an icon
  regenerate restart the Dock (the batch regenerate does it once).
- **Process detection**: main Claude processes are `ps` lines at
  `.../Contents/MacOS/<exe>` with **ppid == 1** (launchd). The ppid filter excludes
  Electron's renderer/utility/MCP children (forked from the main). Paths may
  contain spaces (`Claude P.app`) — the parser handles that; the pgrep pattern is
  regex-escaped and anchored with `( |$)` so `/p` never matches `/ps`.
- **Duplicate-instance guard** lives in the launcher script: if the profile is
  already running it activates the window via System Events (one-time TCC
  Automation prompt) instead of spawning a second instance that would corrupt the
  profile's LevelDB.
- **Locally-created launchers are not quarantined**, so the unsigned bash launcher
  runs without Gatekeeper prompts — no per-launcher signing needed.

## Sandboxing & distribution

The app is **not sandboxed** (writes launchers next to Claude.app, runs
`lsregister`/`iconutil`, restarts the Dock). It ships **Developer ID + notarized**,
never the App Store. Hardened Runtime is on; entitlements are minimal
(no sandbox, apple-events for activation).

## Development guidelines

- **Never touch the user's real profiles or default Claude** when testing. Tests
  use temp install dirs, a fake "real app", and a mocked `CommandRunner`; the only
  live path is `LiveIntegrationTests` (opt-in via `CLAUDE_MANAGER_LIVE=1`), which
  installs into a temp dir and never launches Claude.
- Logic → core + a test. Views stay thin.
- `swift test`, `swiftformat --lint .`, and `swiftlint --strict` must all pass;
  the pre-commit/pre-push hooks and CI enforce it.

## Backlog (not in the MVP; architecture leaves room)

Config comparison / master→profile cloning, window grouping, account-limit
summaries, Claude CLI management, `~/.claude/settings.json` and `~/.claude/projects`
tooling. These are read/aggregate features that fit on top of `ProfileStore` and
the JSON metadata store.

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
- **Set `LSArchitecturePriority = [arm64, x86_64]` in launcher Info.plists** — the
  launcher's executable is a bash *script*, not a Mach-O, so it carries no CPU
  slice for LaunchServices to read and it runs `/bin/bash` under Rosetta
  on Apple Silicon. The script's `exec` of the universal Claude binary then inherits
  x86_64, so the profile runs translated (shows as **Intel** in Activity Monitor).
  The priority key makes LaunchServices bring the interpreter up native, so the
  exec'd Claude is native too. The list is host-relative (Intel falls through to
  x86_64), so the same key is correct on both architectures. Only *newly built*
  bundles get it; older launchers are flagged stale by the wrapper-version check
  (below) and updated via **Rebuild** / **Apply to all launchers**.
- **Bump `CoreConstants.currentWrapperVersion` when the generated launcher changes**
  — whenever you change the output of `LauncherScript.render` (the bash script) or
  `LauncherBundle.writeInfoPlist` (keys/values), increment it. Every launcher stamps
  the version into its marker at build time, so a bundle whose stored version is
  lower reads back as *stale* (`Discovered.isStale` / `ManagedProfile.needsRebuild`),
  and the app surfaces a rebuild (per-launcher **Rebuild**, Settings **Apply to all
  launchers**, and a `Doctor` warning). This is the wrapper/launcher format version,
  **not** the app's `MARKETING_VERSION`. `ProfileStore.rebuild` / `rebuildAll`
  regenerate the whole bundle (script + Info.plist + icon) from the current format;
  a *running* launcher is skipped, not failed (a live bundle can't be rewritten).
  The marker reads an absent version as `1`, so pre-versioning launchers are stale.
- **Icon cache is sticky**: after writing a bundle's `.icns`, run `lsregister -f`,
  `touch`, and `killall Dock`. `killall Dock` flashes the screen, so it is gated
  (`IconCache.refresh(restartDock:)`): a brand-new bundle skips it (nothing cached
  for that path); a forced rebuild, a same-named twin in Trash, or a launcher
  rebuild restarts the Dock (the batch rebuild does it once).
- **Process detection**: main Claude processes are `ps` lines at
  `.../Contents/MacOS/<exe>` with **ppid == 1** (launchd). The ppid filter excludes
  Electron's renderer/utility/MCP children (forked from the main). Paths may
  contain spaces (`Claude Beta.app`) — the parser handles that; the pgrep pattern is
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

- **The version SSoT is the git tag, not `project.yml`.** `MARKETING_VERSION` /
  `CURRENT_PROJECT_VERSION` there are `0.0.0` / `1` dev placeholders; `scripts/build-app.sh`
  injects the real `VERSION` (from the `vX.Y.Z` tag) and `BUILD_NUMBER` (run number) at
  release time and asserts the exported bundle carries them. Don't bump the placeholders
  to release — push a tag (validated strict `X.Y.Z`). See [docs/RELEASING.md](docs/RELEASING.md).

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

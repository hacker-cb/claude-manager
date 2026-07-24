# Claude Manager — project context

Native macOS (SwiftUI) app to run multiple Claude Desktop profiles via **thin
launcher apps**. This file holds the working rules for changing code here; the
deeper material lives in dedicated docs:

- [README.md](README.md) — user-facing docs (install, usage, uninstall).
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — how it works and the hard-won macOS
  facts behind the thin-launcher design.
- [docs/DECISIONS.md](docs/DECISIONS.md) — why the design is what it is (wrapping
  strategies tested and rejected).
- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) — build, test, tooling.
- [docs/RELEASING.md](docs/RELEASING.md) — signing, notarization, Sparkle, releasing.

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

## Working principles

- **Logic → core + a test; views stay thin.** Everything the app does is in
  `ClaudeManagerCore`; the SwiftUI layer is a thin, declarative shell over
  `ProfileStore`. Keep it that way.
- **Never touch the user's real profiles or default Claude when testing.** Tests use
  temp install dirs, a fake "real app", and a mocked `CommandRunner`; the only live
  path is `LiveIntegrationTests` (opt-in via `CLAUDE_MANAGER_LIVE=1`), which installs
  into a temp dir and never launches Claude.
- **The quality gate is enforced:** `swift test`, `swiftformat --lint .`, and
  `swiftlint --strict` must all pass (pre-commit/pre-push hooks + CI).

## Gotchas that bite

Full reasoning for each is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md); the
short form:

- **Bump `CoreConstants.currentWrapperVersion`** whenever `LauncherScript.render`,
  `LauncherBundle.writeInfoPlist`, or anything else about the built bundle changes —
  otherwise existing launchers are never flagged stale for rebuild.
- **Ad-hoc signing is the last write into a launcher bundle.** macOS refuses to
  *execute* an unsigned `.app` (AppleSystemPolicy kills it seconds after it appears in
  the Dock), so `LauncherBundle.build` signs via `CodeSigner` as its final step — on the
  staging copy, before the atomic swap. The seal covers the script, Info.plist and icon:
  never add a write below that call, and never sign anywhere but `build`.
- **Keep `CFBundleIconName` out of launcher Info.plists** — otherwise macOS reads
  `Assets.car` and ignores our `.icns`.
- **`LSArchitecturePriority = [arm64, x86_64]`** keeps profiles native instead of
  running the launcher (and thus Claude) translated under Rosetta.
- **Process detection filters on ppid == 1** to find main Claude processes and skip
  Electron's forked children.
- **The version SSoT is the git tag, not `project.yml`** (`0.0.0` / `1` are dev
  placeholders). Don't bump the placeholders to release — push a `vX.Y.Z` tag. See
  [docs/RELEASING.md](docs/RELEASING.md).
- **Local/dev builds carry a separate identity** — the Debug config uses bundle id
  `io.github.hacker-cb.claude-manager.dev`, name "Claude Manager (Dev)", and a private
  `claude-cmdev://` scheme instead of `claude` (`project.yml` `settings.configs`). macOS keys
  LaunchServices / Login Items / TCC / `UserDefaults` on the bundle id, so a shared id
  lets a build in `build/` hijack the installed release's login item and `claude://`
  handler. Don't collapse the two identities; see
  [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) § Dev builds carry a separate identity.

## Backlog (not in the MVP; architecture leaves room)

Config comparison / master→profile cloning, window grouping, account-limit
summaries, Claude CLI management, `~/.claude/settings.json` and `~/.claude/projects`
tooling. These are read/aggregate features that fit on top of `ProfileStore` and the
JSON metadata store.

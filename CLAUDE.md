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
  never add a write below that call, and never sign anywhere but `build`. The two steps that
  *are* below it write nothing **into** the bundle: `HiddenFlag.set` sets the inode's own flag
  bits, and `matchInstalledSpelling` renames the bundle's directory. `codesign --verify
  --strict` passes across both — measured, for a case-only rename and a wholesale one alike —
  and neither is licence to move anything else down there.
- **Never turn signing off for the app's own build either.** The same execution policy
  applies one level up: `make build-app` (and CI, which builds through it) takes the ad-hoc
  identity `project.yml` declares (`CODE_SIGN_IDENTITY: "-"`), and putting
  `CODE_SIGNING_ALLOWED=NO` back on an `xcodebuild` line drops an `.app` with no
  `Contents/_CodeSignature` into `build/` — AppleSystemPolicy kills its first launch, so
  `make run` reads as a ~20 s hang. `codesign -dv` will not catch it (it reports the
  Mach-O, which the arm64 linker ad-hoc signs on its own); `codesign --verify --strict` on
  the `.app` will, and `scripts/assert-build-signed.sh` does it in CI.
- **Keep `CFBundleIconName` out of launcher Info.plists** — otherwise macOS reads
  `Assets.car` and ignores our `.icns`.
- **The badge resource is named after its own bytes** (`Badge-<sha256[:16]>.icns`, via
  `LauncherBundle.iconFileName`), and `CFBundleIconFile` points at that name. Never put a
  fixed file name back: a rebuild leaves every other part of the bundle's identity
  identical — same path, same `CFBundleIdentifier`, same `CFBundleVersion` — so the
  resource name is the only lever we have on what IconServices treats as a new icon, and a
  constant one means an edited badge is never drawn. Read the installed icon through the
  recorded `CFBundleIconFile`, never a literal, and treat a *name* change as an icon change
  (that is what makes the v3→v4 migration offer its Dock refresh).
- **Never compare two profile directories by string equality.** The path is free text when a
  profile is *created*, so one profile's user-data dir can *be* another's, or sit inside it —
  and `removeItem` is recursive, so purging the outer one takes the inner profile's Anthropic
  token and chat history with it. `ProfileStore+Remove.PurgeReach` compares by *component*, never by string
  prefix (`…/work` is not inside `…/wo`), and asks **both** spellings: canonical, because
  `…/Profiles/x` and `…/ProfilesLink/x` are one directory, *and* literal, because a recursive
  delete also takes any symlink inside it — the sibling that spelled its path through one keeps
  its bytes and loses its path, and only the literal comparison can see that. Case follows the
  volume, which means it holds only while the directory exists. Two things ride on
  the same care: a purge that would reach another launcher's data is declined and reported, and
  an install folder that could not be **listed** never counts as "nobody else uses this"
  (`LauncherBundle.Scan.isComplete`, `keptOwnersUnknown`). A single *bundle* that cannot be read
  deliberately does **not** make a scan incomplete — that folder is normally `/Applications`,
  and one unreadable stranger there would switch off data deletion, Doctor's orphan sweep and
  the restart nudge for every profile at once. And `removeItem` on a symlinked data path unlinks the link without
  walking it, so containment there is not containment at all: `PurgeReach` says so, and getting
  it wrong refuses the removal *and* advises deleting the profile whose data is actually at
  risk.
- **"Is something already at this path?" is a question about files, not strings.** `fileExists`
  folds case on the default macOS volume, so it answers *yes* for `WORK.app` while the profile's
  own `Work.app` is what it found — which is how renaming a profile to another capitalisation of
  its name came to be refused on behalf of the very launcher being renamed. `update` asks
  `PathUtils.sameFile` (`lstat` identity — `st_dev` + `st_ino`, so a symlink counts as itself)
  and treats that as a rename **in place**: the old bundle is never trashed, because it *is* the
  new one, and trashing it leaves the profile with no launcher at all. On a case-sensitive volume
  the same two paths are two files and the guard refuses exactly as before — the volume decides,
  not a rule stated here. The other half is in `build`: `replaceItemAt` writes into the file
  already at the path and **keeps that file's name** (measured), so it finishes by renaming the
  bundle to the spelling it was asked for. Without that the launcher's file says one thing while
  `Profile.id` — which *is* `appPath` — says another, and `liveRewrite`'s deliberate `==` on the
  bundle path quietly stops matching.
- **Never enumerate a directory with `contentsOfDirectory(at:)` — it loses a path's spelling
  twice over.** It resolves symlinks in the URLs it returns, *and* it throws `ENOTDIR` when the
  directory handed to it is itself a symlink; the `atPath` overload does neither. Both
  enumerations — `LauncherBundle.scan` and `Doctor.orphanProfileDiagnostics` — list by path and
  rebuild each URL from the directory they were handed. This matters because `Profile.id` *is*
  `appPath` while every other path comes from `ProfileStoreConfiguration`, and a marker records
  whichever spelling its profile was created with. Put `at:` back and: a launcher under a
  symlinked install directory carries one id from `scan` and another from `draft` (one bundle
  under two ids, an ordinary edit refused as a rename onto its own bundle, the "Restart to
  apply" nudge silently gone); an install directory that *is* a symlink reports no launchers at
  all (empty sidebar, `rebuildAll` succeeding having rebuilt nothing); and Doctor calls every
  live profile an orphan, naming the directory that holds the user's login as safe to delete.
  Comparisons of those paths belong to `PathUtils.sameDirectory` / `canonicalPath`, never `==`
  — except `liveRewrite`'s bundle-path check, which is `==` on purpose so that drift is caught
  rather than papered over.
- **An edit can never reach a profile's identity.** `update` takes `ProfileEdits` — display
  name, label, colour, bundle id — beside the profile, and `Profile.name` / `Profile.profilePath`
  are `let`. A launcher pointed at a different user-data dir does not take the login and chat
  history along, it abandons them, so no edit may stand in for moving profile data: that would
  be its own operation, moving the directory and its `-3p` overlay together. Keep both halves —
  passing a whole `Profile` as the edit target, or making those fields `var` again, each
  restores the hole on its own.
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

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
  never add a write below that call, and never sign anywhere but `build`. `HiddenFlag.set` is the
  one thing that writes into the shipped bundle afterwards, and only because it sets the inode's
  own flag bits, which the seal does not span. `alignInstalledSpelling` also runs after the
  signing call but before the swap, and renames the *previously installed* bundle rather than
  writing into anything — deliberately on that side of the swap, so that its failure leaves the
  old launcher whole like every other failure in `build` (a rename attempted afterwards throws
  with the rebuilt bundle already installed under the old name: an edit reported as failed whose
  marker already carries the new one). `codesign --verify --strict` passes across a rename,
  measured for a case-only change and a wholesale one alike.
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
  its name came to be refused on behalf of the very launcher being renamed. So `renaming` in
  `update` means "the bundle moves to a **different file**" — `PathUtils.sameFile`, `lstat`
  identity (`st_dev` + `st_ino`, a symlink counting as itself) — and not "the path is spelled
  differently". Folded into that one flag rather than subtracted at each site, because all four
  sites ask the same thing and a later `if renaming` that forgot the exception would trash the
  bundle `build` has just written. On a case-sensitive volume those two paths are two files and
  every guard refuses exactly as before: the volume decides, not a rule stated here. **The trash
  step asks again, after the build**, since before it there is nothing to compare when the
  launcher is not on disk — a supported state — and `build` will have created a bundle the old
  spelling then folds onto. The other half is in `build`: `replaceItemAt` writes into the file
  already at the path and **keeps that file's name** (measured), so `alignInstalledSpelling`
  renames the installed bundle to the requested spelling first — and `build` returns
  `BuildResult.appPath`, where the bundle actually ended up, rather than leaving each caller to
  re-derive it from a later lookup of its own. Without it the launcher's file
  says one thing while `Profile.id` — which *is* `appPath` — says another, and `liveRewrite`'s
  deliberate `==` on the bundle path quietly stops matching. For the same reason
  `profileMatchingItsLauncher` takes the bundle's spelling **and everything else the launcher
  records** from disk: `build` writes all of it from the profile handed to it, so a stale
  `Profile` would have `rebuild` undo as much of an edit as that value is stale. Where the volume
  will not say how it spells a name, every one of these **falls back rather than refusing** —
  that same function gates `remove`, and `alignInstalledSpelling` is on the only path a
  `currentWrapperVersion` bump reaches a launcher by, so a refusal there strands a profile that
  can then be neither edited, rebuilt nor deleted. What must not happen is *assuming* the rename
  landed: `update` reports the spelling the bundle actually ended up with. And every message
  naming an occupied path names it as the volume stores it (`add` and `update` alike) — the text
  sends the user to Finder, and the spelling they typed is not what anything there is called.
  **Which spellings fold is the volume's answer,
  never `lowercased()`:** APFS opens `Σ.app`, `σ.app` and `ς.app` as one file, while
  `"Σ".lowercased()` is `σ` and `"ς".lowercased()` is `ς` — so a guard phrased as "these differ
  only in case" declines exactly where the collision is real. Every side asks identity instead.
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
- **Claude Manager updates Claude; Squirrel is switched off.** `disableAutoUpdates` goes into
  the **default profile's** overlay as well as every clone's, and `ClaudeUpdateService` fetches
  each build, proves it is Anthropic's, and installs it on a press. That key is the whole
  lever: `autoUpdaterEnforcementHours` validates as `>0 && <=72`, so Claude's forced restart
  can only be *shortened*, never disabled — and with clones open, Squirrel's installer aborts
  every attempt anyway (`App Still Running Error`), so the old arrangement force-restarted the
  default profile every ~72 h and never finished. The cost is stated in
  [docs/DECISIONS.md](docs/DECISIONS.md): remove Claude Manager without switching the feature
  off and the key is orphaned, so uninstalling starts with turning it off, and Doctor warns
  when the release feed has not answered in a week.
- **Nothing may replace `/Applications/Claude.app` while anything runs out of it.** The
  default profile and every clone `exec` the same binary, and Electron loads resources lazily,
  so a swap under a live instance surfaces minutes later as something inexplicable. The
  installer closes every profile, re-checks with a probe that **fails closed** (an unreadable
  `ps` is "someone is running", never "nobody is"), swaps with `replaceItemAt` — atomic only
  within a volume, which is why staging shares one with `/Applications` — and reopens exactly
  the set it closed. `ShipItProbe` survives for one question only: Squirrel is disabled, not
  absent, so an armed job can outlive the switch and must not be raced.
- **A downloaded build is not trusted because of where it came from.** The feed hands out a
  version and a URL over TLS and that is all it can vouch for. Authenticity comes from the
  bundle: `codesign --verify --strict --deep`, the same check against a Developer ID
  requirement naming team `Q6L2SF6YDW`, `spctl --assess`, and the bundle's own identifier and
  version. It must also be a **real directory** — an archive can ship `Claude.app` as a
  symlink, and every one of those checks would then pass by resolving to the installed app
  while the "verified" bundle is a link that the swap would put into `/Applications`.
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

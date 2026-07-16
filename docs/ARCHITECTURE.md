# Architecture

How Claude Manager is put together, and the hard-won macOS facts that shape the
design. For the rejected alternatives that led here, see [DECISIONS.md](DECISIONS.md).

## Layers

```
ClaudeManagerCore (Swift package — headless, fully tested)
├─ Models      Profile, BadgeColor, BadgeStyle, LauncherMarker, ManagedProfile, Diagnostic,
│              ProfileManagedConfig (overlay desired-state), StagedUpdate
├─ RealClaude  locate the real app (LaunchServices + fallbacks), version, icon
├─ Launcher    LauncherBundle (build/scan/remove) + LauncherScript (bash launcher, duplicate guard)
├─ Icons       BadgeRenderer (CoreGraphics) → IcnsPacker (iconutil) → IconCache
├─ Process     ProcessProbe — pgrep/ps main-process detection (ppid==1 filter)
├─ ManagedConfig ManagedConfigWriter — the per-clone `-3p` overlay (disable update / deep-link reg)
├─ DeepLink    LaunchServicesHandlerGuard (hold claude://) + ProfileStore forwarding (open -n --args)
├─ Update      StagedUpdateProbe (read ShipItState.plist) + ProfileStore apply-to-all (quiesce/swap/relaunch)
├─ ProfileStore  the façade: add / remove / open / stop / update / rebuild / doctor
└─ CommandRunner injected process runner (mocked in tests)

ClaudeManagerApp (SwiftUI — thin)
└─ Window (list + detail + editor + doctor) · MenuBarExtra · Settings ·
   DeepLinkService + DeepLinkPresenter (claude:// hold + account picker)
```

Everything the app does lives in `ClaudeManagerCore`; the SwiftUI layer is a thin
shell over `ProfileStore`. Logic goes in the core (and gets a test); views stay
declarative. The conceptual groups above map to `Sources/ClaudeManagerCore/{Models,
Services,Support}/` — e.g. `Services/ProfileStore.swift`, `Services/LauncherBundle.swift`,
`Services/LauncherScript.swift`, `Services/ProcessProbe.swift`.

## Why thin launchers

Claude Desktop (Electron) has **no single-instance lock** and honors
`--user-data-dir`. One user-data-dir == one isolated account (the cookie `sessionKey`
and `safeStorage` token blobs live inside it), so multi-account just means multiple
instances on different user-data-dirs.

The load-bearing constraint: **do not copy and re-sign Claude.app.** Ad-hoc
re-signing strips Anthropic's entitlements, which breaks notifications
(`usernotificationsd` rejects the modified bundle id) and virtualization features
(`virtualization_entitlement_missing`). A **thin launcher** — a tiny `.app` whose
executable is a bash script that `exec`s the untouched, signed Claude binary with an
isolated `--user-data-dir` — keeps Anthropic's signature and entitlements intact, so
everything keeps working and Claude self-updates transparently. Other wrapping
strategies were tested and rejected; see [DECISIONS.md](DECISIONS.md).

## Source of truth

Each launcher's `Contents/Info.plist` carries a `ClaudeManagerLauncher` marker dict
(`name`, `label`, `color`, `profile`, `wrapperVersion`). Scanning the install
directory for that key is how launchers are discovered — there is no external
registry the app depends on. A JSON file in `~/Library/Application Support/Claude
Manager` holds GUI-only metadata (ordering, notes) and is always optional.

## Managed-config overlay

Clones all `exec` the one on-disk `/Applications/Claude.app`, so each clone would
otherwise run Claude's own Squirrel updater — N redundant feed checks and downloads
racing one shared cache — and re-grab the `claude://` scheme. Claude Manager
pre-seeds Claude's per-userData **local managed-config tier** to switch both off, per
clone.

Claude resolves managed config in tiers; the local tier lives at
`<userData>-3p/configLibrary` — a *sibling* of the data dir (the `-3p` suffix is
appended to the path **string**, so a trailing slash is trimmed first). Two files:
`_meta.json` names an `appliedId`, and `<appliedId>.json` holds a **flat** object of
enterprise-policy keys. Those keys are top-level booleans — `disableAutoUpdates` and
(broker-on) `disableDeepLinkRegistration`; the intuitive nested `autoUpdate.disabled`
shape is ignored by Claude's resolver. `ManagedConfigWriter` owns the files;
`ProfileManagedConfig` is the typed desired state.

The write is **merge-not-clobber and idempotent**: it strips only its own
`managedKeys` and re-adds the wanted ones (preserving any key Claude or another tool
keeps there), and skips the write when the serialized bytes are unchanged — so the
reconcile-per-launch path never churns a file Claude may be reading. `appliedId` is
reused when present and valid, else minted, validated against **Claude's own loose
gate `/^[a-f0-9-]{36}$/`** rather than a strict UUID (so CM never rejects an id Claude
itself applied, and the class can't form a `..` or `/` path component).

`ProfileStore` reconciles on add / update / rebuild and a startup sweep
(`reconcileAllManagedConfigs`), and removes the whole `-3p` tier when a profile's data
is purged. The schema is reverse-engineered and **pinned to a Claude build**
(`CoreConstants.claudeManagedConfigValidatedVersion`), so every read is defensive —
nil/skip on anything unexpected, never a crash.

## The `claude://` deep-link broker

A login / SSO / magic-link callback returns as a `claude://` URL, which macOS hands to
whichever Claude owns the scheme — not the account you're signing into. Claude Manager
registers itself as the **default `claude://` handler** (on by default) and, on each
inbound link, shows an account picker (`DeepLinkPresenter` — its own floating window,
since a menu-bar app may have none) to route it to a chosen profile or the default
account. The URL carries no account identity, so routing is **always** a user choice;
there is no auto-forward.

Claude re-grabs the scheme on every launch (`setAsDefaultProtocolClient`), so a
one-time registration isn't enough — CM **holds** it. Clones are muted by the
`disableDeepLinkRegistration` overlay; for anything that still registers,
`LaunchServicesHandlerGuard` re-asserts CM whenever LaunchServices fires its per-user
`user.uid.<uid>.com.apple.LaunchServices.database` Darwin notification (event-driven,
no polling — the notification fires *after* the change, so the re-assert lands last).
Claiming a **custom** scheme raises no consent prompt, which is what makes a silent
hold/restore viable.

Forwarding is `open -n <app> --args <url>` — a direct `execve` (no shell) with the URL
as a single argv element that Electron scans at launch. It's the only way to deliver a
link to a **specific not-running** launcher (the native Apple-event path can't address
one), and only a `DeepLink.isClaudeURL`-validated string (scheme + non-empty
authority) is ever passed, so it can't be re-split or read as a flag. Residual: a
cold-start callback's OAuth `code` is briefly on the command line — readable only by a
pre-existing same-user process.

**The default account is never written.** Its handler is held only by the guard, which
stops the moment CM isn't running — so removing Claude Manager (or toggling the broker
off) hands `claude://` straight back to Claude and can't leave the default's links
broken. `stopHoldingAndRestore` re-asserts Claude both while actively holding *and*
whenever CM currently owns the handler (recovering a crash that left it owning).

## Applying a staged Claude update

When the default account downloads an update while any account is open, ShipIt
(Squirrel.Mac) can't swap `/Applications/Claude.app` and the update stalls ("Update
didn't complete"). Claude Manager clears this — it never swaps the app itself;
**ShipIt does, and only with zero running real-Claude instances.**

`StagedUpdateProbe` reads ShipIt's per-bundle `ShipItState.plist` (**JSON despite the
extension**, under `~/Library/Caches/<bundleid>.ShipIt/`, keyed by the *installed*
app's real bundle id so a legacy-id install is found too). An armed job names an
`updateBundleURL`; the probe reads that bundle's version and surfaces a `StagedUpdate`
only when it's a genuine upgrade over the installed one.

`applyStagedUpdateToAll` snapshots the running set, then: **Gate 1** gracefully quits
every account (SIGTERM only — never SIGKILL a possibly-active conversation) and waits
until nothing blocks the swap; **Gate 2** lets ShipIt swap and polls the on-disk
version (`>=`, since ShipIt may land a build newer than the one staged). It then
relaunches exactly the snapshotted set. If an account won't quit it **aborts before
the swap** and reopens what it stopped; on every path it restores the set, so you never
end with fewer accounts than you had. Two sharp edges: the gate counts **only
processes at the real Claude binary path** (`ProcessProbe` matches CM's own "Claude
Manager" too — ppid 1, "Claude" in the path — so `blockingInstances` filters to
`realClaude.binaryURL.path` or the gate never passes); and every relaunch is guarded on
the account being **currently down** (a second `open -n` on a live default duplicates
it on one user-data-dir and corrupts LevelDB — and ShipIt often relaunches the default
itself after a swap).

## macOS facts baked into the code

- **Keep `CFBundleIconName` OUT of launcher Info.plists.** When present, macOS reads
  the icon from `Assets.car` and ignores our `.icns`. We write only
  `CFBundleIconFile = Badge.icns`.
- **Set `LSArchitecturePriority = [arm64, x86_64]` in launcher Info.plists.** The
  launcher's executable is a bash *script*, not a Mach-O, so it carries no CPU slice
  for LaunchServices to read and it runs `/bin/bash` under Rosetta on Apple Silicon.
  The script's `exec` of the universal Claude binary then inherits x86_64, so the
  profile runs translated (shows as **Intel** in Activity Monitor). The priority key
  makes LaunchServices bring the interpreter up native, so the exec'd Claude is native
  too. The list is host-relative (Intel falls through to x86_64), so the same key is
  correct on both architectures. Only *newly built* bundles get it; older launchers
  are flagged stale by the wrapper-version check (below) and updated via **Rebuild** /
  **Apply to all launchers**.
- **Bump `CoreConstants.currentWrapperVersion` when the generated launcher changes.**
  Whenever the output of `LauncherScript.render` (the bash script) or
  `LauncherBundle.writeInfoPlist` (keys/values) changes, increment it. Every launcher
  stamps the version into its marker at build time, so a bundle whose stored version
  is lower reads back as *stale* (`Discovered.isStale` / `ManagedProfile.needsRebuild`),
  and the app surfaces a rebuild (per-launcher **Rebuild**, Settings **Apply to all
  launchers**, and a `Doctor` warning). This is the wrapper/launcher **format**
  version, **not** the app's `MARKETING_VERSION`. `ProfileStore.rebuild` / `rebuildAll`
  regenerate the whole bundle (script + Info.plist + icon) from the current format; a
  *running* launcher is skipped, not failed (a live bundle can't be rewritten). The
  marker reads an absent version as `1`, so pre-versioning launchers are stale.
- **Icon cache is sticky.** After writing a bundle's `.icns`, run `lsregister -f`,
  `touch`, and `killall Dock`. `killall Dock` flashes the screen, so it is gated
  (`IconCache.refresh(restartDock:)`): a brand-new bundle skips it (nothing cached for
  that path); a forced rebuild, a same-named twin in Trash, or a launcher rebuild
  restarts the Dock (the batch rebuild does it once).
- **Process detection.** Main Claude processes are `ps` lines at
  `.../Contents/MacOS/<exe>` with **ppid == 1** (launchd). The ppid filter excludes
  Electron's renderer/utility/MCP children (forked from the main). Paths may contain
  spaces (`Claude Beta.app`) — the parser handles that; the pgrep pattern is
  regex-escaped and anchored with `( |$)` so `/p` never matches `/ps`.
- **Duplicate-instance guard** lives in the launcher script. If the profile is already
  running it activates the window via System Events (one-time TCC Automation prompt)
  instead of spawning a second instance that would corrupt the profile's LevelDB. The
  guard uses `shlock` (an atomic, PID-aware lock) to close the TOCTOU window between
  the check and the `exec`, with a best-effort `pgrep` fallback if `shlock` is absent.
- **Locally-created launchers are not quarantined**, so the unsigned bash launcher
  runs without Gatekeeper prompts — no per-launcher signing needed.
- **An MDM managed-preferences plist wins over our local overlay tier.** If
  `/Library/Managed Preferences/<claude-bundle-id>.plist` exists, Claude ignores the
  `-3p` local tier, so `ManagedConfigWriter` detects it and **skips** (writing there
  would be silently useless), and `Doctor` reports it as an informational note rather
  than an unclearable "overlay not applied" warning.

## Sandboxing &amp; distribution

The app is **not sandboxed** — it writes launcher bundles next to Claude.app, runs
`lsregister` / `iconutil`, and restarts the Dock. It ships **Developer ID +
notarized**, never the App Store. Hardened Runtime is on; entitlements are minimal
(no sandbox, apple-events for activation). See [RELEASING.md](RELEASING.md) for the
signing, notarization, and auto-update pipeline.

It self-updates via Sparkle, but the updater stays **dormant in local/dev builds** —
when `MARKETING_VERSION` is the `0.0.0` placeholder (`CoreConstants.isDistributionBuild`
is false), so a developer isn't nagged to overwrite their own build with a published
release. A release injects a real version from the git tag and the updater activates.

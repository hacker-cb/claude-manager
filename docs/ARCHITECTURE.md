# Architecture

How Claude Manager is put together, and the hard-won macOS facts that shape the
design. For the rejected alternatives that led here, see [DECISIONS.md](DECISIONS.md).

## Layers

```
ClaudeManagerCore (Swift package — headless, fully tested)
├─ Models        Profile, BadgeColor, BadgeStyle, LauncherMarker, ManagedProfile, Diagnostic,
│                ProfileManagedConfig (overlay desired-state), StagedUpdate
├─ RealClaude    locate the real app (LaunchServices + fallbacks), version, icon
├─ Launcher      LauncherBundle (build/scan/remove) + LauncherScript (bash launcher, duplicate guard)
│                + CodeSigner (ad-hoc signing — macOS refuses to run an unsigned launcher)
├─ Icons         BadgeRenderer (CoreGraphics) → IcnsPacker (iconutil) → IconCache
├─ Process       ProcessProbe — pgrep/ps main-process detection (ppid==1 filter)
├─ ManagedConfig ManagedConfigWriter — the per-clone `-3p` overlay (disable update / deep-link reg)
├─ DeepLink      LaunchServicesHandlerGuard (hold claude://) + ProfileStore forwarding (open -n --args)
├─ Update        StagedUpdateProbe (read ShipItState.plist) + ProfileStore apply-to-all (quiesce/swap/relaunch)
├─ ProfileStore  the façade: add / remove / open / stop / update / rebuild / doctor
└─ CommandRunner injected process runner (mocked in tests)

ClaudeManagerApp (SwiftUI — thin)
├─ Window (list + detail + editor + doctor) · MenuBarExtra · Settings
└─ DeepLinkService + DeepLinkPresenter — claude:// hold + profile picker
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

A `claude://` URL — a Cowork shared-artifact, a session `resume`, a login / SSO /
MCP-auth callback — is handed by macOS to whichever Claude owns the scheme, not the
profile you meant. Claude Manager registers itself as the **default `claude://` handler**
(on by default) and, on each inbound link, shows a profile picker (`DeepLinkPresenter` —
its own floating window, since a menu-bar app may have none) to route it to a chosen
clone or the default profile. The URL carries no profile identity, so routing is
**always** a user choice; the profile then resolves the link's contents itself.

**Holding the scheme.** Claude re-grabs it on every launch
(`setAsDefaultProtocolClient`), so a one-time registration isn't enough.
`LaunchServicesHandlerGuard` re-asserts CM whenever LaunchServices fires its per-user
`user.uid.<uid>.com.apple.LaunchServices.database` Darwin notification (event-driven, no
polling — it fires *after* the change, so the re-assert lands last), plus a cheap
re-check on `didBecomeActive`. Claiming a **custom** scheme raises no consent prompt,
which is what makes a silent hold/restore viable. This guard is the *sole* hold
mechanism, so CM must be running to intercept; while it's down a freshly-launched clone
can grab the scheme, and its own links then land there directly (no picker).

**Delivery is a `GURL` Apple event addressed by pid** (`DeepLinkDelivery`), *not* argv.
After a launcher `exec`s the real binary, every profile's Claude shares bundle id
`com.anthropic.claudefordesktop`, so `open`/bundle-id addressing can't disambiguate two
running instances — but a pid can. And Claude reads deep links **only** from the
`open-url` event (it does *not* scan `argv` for the scheme), so the old
`open -n … --args <url>` silently dropped the link. So a **running** target gets the
`GURL` straight to its pid; a **not-running** one is cold-launched, its pid polled for,
then sent the `GURL`. Sending an Apple event to another app needs a one-time TCC
Automation grant ("Claude Manager" → "Claude"); the app ships the
`com.apple.security.automation.apple-events` entitlement, and all profiles share the
target bundle id so one grant covers them all.
`AEDeterminePermissionToAutomateTarget` is checked *first* so a denied hand-off surfaces
actionable guidance rather than vanishing — a `.noReply` `GURL` send reports success even
when TCC has silently blocked it.

**No profile is muted with `disableDeepLinkRegistration`.** That key (Claude's "disable
`claude://` handling") makes Claude *drop* every forwarded non-auth link
(`dropping deep link (disableDeepLinkRegistration)`) — exactly the hand-off the broker
performs — so writing it would defeat forwarding. `ProfileManagedConfig` keeps it only in
`managedKeys`, so a reconcile *strips* one an earlier build wrote. Claude reads this
managed config **at launch**, so a clone already running when the key is stripped keeps
dropping until it is restarted once; fresh launches are clean.

**The default profile is never written.** Its handler is held only by the guard, which
stops the moment CM isn't running — so removing Claude Manager (or toggling the broker
off) hands `claude://` straight back to Claude and can't leave the default's links
broken. `stopHoldingAndRestore` re-asserts Claude both while actively holding *and*
whenever CM currently owns the handler (recovering a crash that left it owning).

**Wiring the sink.** SwiftUI's `@NSApplicationDelegateAdaptor` keeps its *own* object as
`NSApp.delegate` and only forwards callbacks to our `AppDelegate`, so
`NSApp.delegate as? AppDelegate` is always nil. `AppModel` reaches the real delegate
through `AppDelegate.shared` (set in its `init`), retrying on the main queue until the
adaptor has created it — otherwise the inbound-link sink is never wired and every link is
buffered and silently dropped.

## Applying a staged Claude update

When the default profile downloads an update while any profile is open, ShipIt
(Squirrel.Mac) can't swap `/Applications/Claude.app` and the update stalls ("Update
didn't complete"). Claude Manager clears this — it never swaps the app itself;
**ShipIt does, and only with zero running real-Claude instances.**

`StagedUpdateProbe` reads ShipIt's per-bundle `ShipItState.plist` (**JSON despite the
extension**, under `~/Library/Caches/<bundleid>.ShipIt/`, keyed by the *installed*
app's real bundle id so a legacy-id install is found too). An armed job names an
`updateBundleURL`; the probe reads that bundle's version and surfaces a `StagedUpdate`
only when it's a genuine upgrade over the installed one.

`applyStagedUpdateToAll` snapshots the running set, then: **Gate 1** gracefully quits
every profile (SIGTERM only — never SIGKILL a possibly-active conversation) and waits
until nothing blocks the swap; **Gate 2** lets ShipIt swap and polls the on-disk
version (`>=`, since ShipIt may land a build newer than the one staged). It then
relaunches exactly the snapshotted set. If a profile won't quit it **aborts before
the swap** and reopens what it stopped; on every path it restores the set, so you never
end with fewer profiles than you had. Two sharp edges: the gate counts **only
processes at the real Claude binary path** (`ProcessProbe` matches CM's own "Claude
Manager" too — ppid 1, "Claude" in the path — so `blockingInstances` filters to
`realClaude.binaryURL.path` or the gate never passes); and every relaunch is guarded on
the profile being **currently down** (a second `open -n` on a live default duplicates
it on one user-data-dir and corrupts LevelDB — and ShipIt often relaunches the default
itself after a swap).

## Plan-usage statistics

Surfaces each account's plan limits (5-hour / weekly / weekly-scoped-model / extra
credits), warns before a limit bites, and keeps a local history for analysis. On by
default, fully optional (Settings → Usage) — and the trust-model change it forces is
documented in [README.md](../README.md) and [SECURITY.md](../SECURITY.md).

**The account owns usage, not the profile.** Limits belong to the Anthropic
subscription, so N launchers on one account must issue **one** `/usage` call.
`AccountResolver` decrypts every binding's token locally first, groups by the config's
account-UUID hint (`lastKnownAccountUuid`), and elects one binding per account: valid
(unexpired + `user:inference`) → latest `expiresAt` → stable id. The default account is a
first-class peer, resolved from its own user-data-dir. A binding whose token can't be read
maps to a login-needed / no-source UI state; an account is only "login needed" if **every**
binding fails.

**The org is never the account key.** A Team/Enterprise org holds many accounts, so keying
on `organizationUUID` would collapse two profiles signed in as different users and render
one account's limits for both. Without the local hint a binding therefore stands alone as a
**provisional** identity, and `UsageService` settles it with a `/profile` call before
anything persistent is keyed on it. That matters twice over: the provisional key is the
*binding id*, so it would otherwise flip the moment Claude writes the hint, orphaning the
throttle window and every stored sample under the old key. The trade is deliberate —
over-splitting costs one extra call for a moment, collapsing shows the wrong account's
numbers.

**N launchers, one login — still one account.** Wanting several windows on one login is a
normal reason to make several launchers, and nothing local ties them together until Claude
writes `lastKnownAccountUuid` into each profile: each carries its own token, so they resolve
as separate provisional accounts. `UsageService` therefore settles identities **before**
fetching anything and then `AccountResolver.regroup` folds the ones sharing a uuid — union
the bindings, re-elect the healthiest token, keep the named identity. Without that pass one
login would issue N `/usage` calls on *every* poll (the differing token fingerprints read as
a re-login, bypassing even the 60s floor), store N rows for one account, and never say
"shared with N profiles". Identity itself is per-token, so the first pass does cost one
`/profile` per launcher — that is exactly what reveals the shared account — and every later
pass is served from cache.

**Naming the account, cheaply.** Launcher names are whatever the user typed, so `/profile`
is also what ties a row to a real login (email / display name, surfaced in the Usage header
and the sidebar tooltip). The answer is cached in `account_profiles` and looked up **by account uuid**
whenever that is known — the name belongs to the account, not to the token that asked, so
sibling launchers share one lookup instead of paying one each. A binding whose account is still
unknown falls back to the token fingerprint, which is all it has before `/profile` answers.
`UsageService.profileTTLSeconds` (24h) bounds staleness either way.

`/profile` is also **authoritative about which account a token belongs to** — its uuid wins even
over the config hint, which is only a cached guess and goes stale when a launcher is signed out
and back in as someone else. Reading that cache is free and happens on every pass, so a
throttled account still renders with its name; the network call is made only when a `/usage`
fetch is happening anyway, which keeps it inside the same floor and backoff — never once per
throttled tick. A provisional identity is the one exception: it must ask immediately, since
its storage key depends on the answer.

**Token source — Electron safeStorage, no separate keychain entry.** Desktop tokens
live inside each account's `config.json` under `oauth:tokenCacheV2`, encrypted by
Electron safeStorage. `SafeStorageDecryptor` reproduces the recipe with **CommonCrypto**
(CryptoKit has neither PBKDF2 nor AES-CBC, so this adds zero SPM deps): read the keychain
secret ("Claude Safe Storage"), `PBKDF2-HMAC-SHA1(salt "saltysalt", 1003 iters, 16 bytes)`
→ AES-128-CBC (IV = 16 spaces), strip the `v10` prefix, PKCS7-unpad. The plaintext is a
map keyed `<clientId>:<orgUuid>:<audience>:<scopes>`; the audience contains colons, so
entries are matched by substring, never split on `:`. `SafeStorageKeyStore` (an actor)
caches the derived key for the process lifetime, so a fleet of accounts costs **one**
keychain access — and one "Always Allow" prompt. Background polls read with
`kSecUseAuthenticationUISkip` so a locked/unauthorized keychain fails fast (serve stale)
instead of prompting mid-poll; the prompt is deferred to an interactive Refresh.

**Parsing is forward-compatible by design.** The `/usage` `limits[]` array is
self-describing (`kind`, `group`, `percent`, `resets_at`, `scope`, `severity`,
`is_active`) and is the source of truth; the model label is **data**
(`scope.model.display_name` — "Sonnet" became "Fable" mid-development). `UsageLimitsParser`
decodes field-by-field over `[String: Any]`, never a strict `Codable`: an unknown `kind`
is kept in an "other" bucket, percents are clamped, a bad date degrades to nil, a
non-object body to nil — it never drops the payload or crashes. Percent (0…100) is
normalized to a fraction (0…1) at the parse boundary so every internal comparison speaks
one unit.

**AppModel owns the loop; the core service is stateless.** `UsageService` is a value
rebuilt each tick (resolve → dedup → fetch-with-backoff → persist → return); the durable
state lives in two actors the model holds — `UsageHistoryStore` (SQLite) and
`SafeStorageKeyStore`. The poll loop mirrors `monitorTask`: default 30 min (presets
15/30/60/manual), an opt-in adaptive 5-min lane while any account is running, gated on
`!isApplyingStagedUpdate`. **The master switch is the choke point** — with tracking off,
`refreshUsage` returns before any keychain read, network call, or storage, so the
README/SECURITY promise holds literally. A rotated safeStorage key self-heals at the
**fleet** level: if *every* binding fails to decrypt (with at least one real
decrypt-failure), `UsageService` invalidates the shared key once and retries — the
provider never invalidates per-binding, which would poison a healthy key when a single
blob is corrupt.

**One gate, applied before every call.** Identity and usage share the expiry / backoff / floor
rule (`UsageService.isBlocked`), because the identity pass runs *first* and can't un-send what
it already sent — a dead login otherwise re-offered its token to `/profile` on every tick
forever, outside the floor and outside any 429 window. Only a **terminal** park (401/403) is
ever lifted early, and only through the two documented exits: a re-login or an explicit
Refresh, which is threaded down as `interactive`. The 60s floor is never bypassed — once
sibling launchers share an account the elected token flips whenever any of them refreshes its
own, with no re-login involved, so treating a changed fingerprint as "try again now" would
discard a standing rate-limit window.

**Throttle & backoff are persisted, honestly.** `UsageHistoryStore` holds per-account
throttle state (last attempt, `backoff_until`, a token fingerprint `sha256(token)[:16]`,
and the backoff **reason** — rateLimited / offline / terminal). A 60s floor gates even
the manual Refresh; 429 honors `Retry-After` (integer **and** HTTP-date); other errors
back off exponentially, capped ~30 min; 401/403 is terminal until the fingerprint changes
(a re-login) or a manual Refresh. Storing the *reason* means a later tick renders the
true cause rather than reading a transport failure back as a 429.

**Storage — one actor, one serialized `libsqlite3` connection** (system library, linked
via `.linkedLibrary("sqlite3")`; zero SPM deps). A canonical `snapshot_json` is the
restore source; flat columns index it; `raw_json` is kept **latest-only** for the Doctor
inspector; `notified_thresholds` dedups notifications across relaunches (keyed on account
+ limit identity + rounded threshold + reset window); a throttle table holds the state
above. Bootstrap is `PRAGMA user_version` drop-and-recreate on mismatch (early-stage: no
migrations). Every open/read failure degrades to empty (mirroring `MetadataStore`), with
an in-memory fallback for throttle/ledger so a dead DB can't strip backoff and hammer the
API. `CoreConstants.usageSchemaVersion` is bumped when the schema changes.

**Thresholds (`LimitEvaluator`, pure).** A time-relative model (warn when utilization is
high *and* the window is early: 5h (0.90, 0.72), 7d (0.75, 0.60)) plus an absolute
near-exhaustion tier (0.90 warning / 0.95 critical), floored at 0.70, firing only the
single most-severe tier per limit. `LimitNotifier` posts via `UNUserNotificationCenter`,
deduped against `notified_thresholds` so each threshold fires once per reset window.

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
  Whenever the output of `LauncherScript.render` (the bash script), of
  `LauncherBundle.writeInfoPlist` (keys/values), or of the bundle `LauncherBundle.build`
  assembles changes, increment it. Every launcher
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
- **Every launcher must be ad-hoc signed, or macOS will not run it.** Locally created
  bundles are *not* quarantined (they carry `com.apple.provenance`, not
  `com.apple.quarantine`), so Gatekeeper never prompts — but AppleSystemPolicy still
  refuses to **execute** code with no valid signature. An unsigned launcher registers
  with LaunchServices, appears in the Dock, and is then killed (`ASP: Security policy
  would not allow process` in `log show`), which reads to the user as "it hangs and
  never opens". So `LauncherBundle.build` ad-hoc signs the bundle — content hashes with
  no identity: no certificate, no Apple Developer account, no network, so it works the
  same locally and on CI. `CodeSigner` runs `/usr/bin/codesign --force --sign -` through
  the injected `CommandRunner`; the in-process `SecCodeSigner` API was tried and rejected
  (it deadlocks under a saturated thread pool — see [DECISIONS.md](DECISIONS.md)).
  Nothing here is launcher-specific: macOS applies the same policy to **any** bundle it is
  asked to execute, Claude Manager's own `.app` included — which is why `make build-app`
  and CI build it ad-hoc signed (`CODE_SIGN_IDENTITY: "-"` in `project.yml`) rather than
  with signing disabled (see [DEVELOPMENT.md](DEVELOPMENT.md) § Local builds are ad-hoc
  signed).
- **Sign last, and re-sign on every rebuild.** The signature seals the script, the
  Info.plist and the icon, so *any* write into the bundle after signing invalidates it —
  and an invalid signature is refused harder than a missing one. `build` is the single
  writer and signs as its final step, on the staging copy **before** the atomic swap: a
  launcher is never observable unsigned, and a signing failure leaves the previous
  working bundle in place. (The signature survives the swap because it lives in
  `Contents/_CodeSignature/`, ordinary files that move with the directory.)
  `IconCache.refresh` is safe — `lsregister -f` and `touch` change mtime, not content.
  Note that `spctl -a -t exec` still reports `rejected` for an ad-hoc signed bundle: it
  assesses *notarization*, not execution policy, so it is not a useful success signal
  here. `codesign --verify --strict` (or `SecStaticCodeCheckValidity`) plus an actual
  launch is.
- **An unsigned launcher is broken, not dated — and the app must say so.** Launchers
  built before wrapper v3 carry no signature, so they do not run at all.
  `CoreConstants.minimumRunnableWrapperVersion` separates that from ordinary staleness
  (`ManagedProfile.isUnrunnable` / `Discovered.isUnrunnable`): the list badge, the detail
  banner, and `Doctor` all report it as an **error** with "won't launch" wording and a
  mandatory rebuild, never as the optional "update available" nudge a merely-dated
  launcher gets. `Doctor` additionally runs `codesign --verify` per launcher
  (`CodeSigner.isValidlySigned`), because a *current-format* bundle whose seal was broken
  after the build passes every other check while being equally unable to start.
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

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
until nothing blocks the swap; **Gate 2** waits out the swap by watching ShipIt's
process, then reads the on-disk version (`>=`, since ShipIt may land a build newer than
the one staged). It then relaunches exactly the snapshotted set. If a profile won't quit
it **aborts before the swap** and reopens what it stopped; on every path it restores the
set, so you never end with fewer profiles than you had. Two sharp edges: the gate counts
**only processes at the real Claude binary path** (`ProcessProbe` matches CM's own "Claude
Manager" too — ppid 1, "Claude" in the path — so `blockingInstances` filters to
`realClaude.binaryURL.path` or the gate never passes); and every relaunch is guarded on
the profile being **currently down** (a second `open -n` on a live default duplicates
it on one user-data-dir and corrupts LevelDB — and ShipIt often relaunches the default
itself after a swap).

### Gate 2 watches the installer, never a clock

The swap has **no upper bound knowable in advance**. Measured over a month of real
installs, `Beginning installation` → `Moving bundle` takes 3–5 s; under disk contention
the same 800 MB bundle has taken 28 s and 57 s. So a timeout cannot separate "still
copying" from "gave up" — and being wrong is *destructive*, not merely unhelpful: ShipIt
re-checks its instance count after copying, so relaunching profiles mid-install makes it
abort with `App Still Running Error` and destroys an install that was going through.
That is precisely how a 30-second Gate 2 turned a working install into a loop of failed
ones, each costing a fresh ~800 MB download.

`ShipItProbe` therefore answers "is the installer alive?" (`pgrep` on the Squirrel binary
plus **our** job label — VS Code and GitKraken ship the same updater) and "what did it log
for *this* attempt?" (ShipIt's `stderr`, read only past an offset recorded before the
apply — the log is append-only and never rotated, so its tail is full of failures from
days ago). While ShipIt lives, nothing is relaunched. The poll budget is a **backstop**
(ten minutes), and if it elapses with the installer still working, profiles are
deliberately left **closed** and reported as such — reopening them is the harm.

Four details that keep that invariant honest:

- **"Can't tell" is a third answer, and the two callers need opposite readings of it.**
  `ShipItProbe.liveness()` keeps `running` / `gone` / `unknown` apart: only `pgrep` exit 1
  means nothing matched, exit 0 means something did (so it counts as running even when the
  captured pid is unreadable — the exit status is the answer), and 2, 3 or a failed spawn
  say nothing at all. `isRunning()` folds unknown to **running** — the reading a *wait*
  needs, since a wrong "gone" destroys the swap while a wrong "running" only spends a
  budget. `isConfirmedRunning()` folds it to **not running** — the reading a *guard* needs,
  since a guard has no budget to run out: refusing on a guess would disable every Open,
  Restart and deep link for as long as the probe stays unhealthy.
- **The version is re-read after the installer disappears.** Each pass reads the version
  *before* running `pgrep`, so an installer that swaps and exits between those two reads
  would otherwise be recorded as a failure for an update that had in fact succeeded.
- **A new version on disk is not the end of the install.** ShipIt swaps, then cleans up and
  hands off (~280 ms measured from `Moving bundle` to `ShipIt quitting`). Success therefore
  *drains* until the installer is actually gone, bounded by `swapDrainPolls` — the bundle is
  already in place by then, so a lingering installer is no reason to keep profiles closed.
  That drain runs on its **own** budget, after the wait loop: folded into it, a swap first
  seen on the final poll skipped the drain entirely and relaunched into a live installer —
  the original bug, back at the edge of the budget.
- **The launch guards ask the machine, not our flag.** `swapStillInstalling` hands control
  back with ShipIt still copying, and `isApplyingStagedUpdate` is false from that moment —
  so every launch path additionally consults `ProfileStore.isClaudeInstallerRunning()`.
  Without it the app itself would offer the one action that aborts the install it just
  protected. The guard is `async` and probes off the main actor: `SystemCommandRunner` blocks
  on `Process.waitUntilExit()`, so asking inline would stall the UI on every launch.

**Doctor reports the same machine state standing still.** The failure this whole section
exists for ran for nine days with nothing saying anything was wrong — ShipIt waits for zero
instances indefinitely and writes only to its own log, so the first hint the user got was
the default profile restarting itself at 4 am. So Doctor surfaces two facts: an installer
that has been alive past `CoreConstants.shipItStuckSeconds` (ten minutes — two orders of
magnitude past a 3–5 s swap, so it can only be waiting on profiles), read via
`ShipItProbe.runningFor()`; and the reason the last attempt failed, but **only while an
update is still armed** — the log is append-only and never rotated, so without that
condition it would keep reporting failures from days ago as though they mattered now.

The outcomes are kept distinct because their advice differs: `noStagedUpdate` is the only
one that should say "click Restart to update to arm it", and saying that to someone whose
armed install merely failed sends them to re-download the bundle for nothing.

### Claude protects its own working sessions

A profile with a **running session** refuses to quit: Claude's own before-quit interceptor
vetoes it (`beforeQuit: vetoed by before-quit interceptor`) and shows "Claude is still
working — Quit anyway / Wait for Claude / Cancel". Verified by experiment: `SIGTERM` to a
busy profile leaves it alive and the work intact, while `SIGTERM` to a profile whose
session is merely *open but idle* quits cleanly. The count behind it is `countRunningSessions`,
so it means working, not open.

This is why CM has **no busy-detector of its own, and must not grow one**. Everything
observable from outside was measured and none of it separates a working session from an
idle one: power assertions do not appear during agent work (they flicker for unrelated
reasons), CPU over the process tree measures UI rendering, and the session process itself
sits near 1% either way because an agent spends its time waiting on the network. Claude
answers the question correctly; CM asks by trying to stop, and treats the refusal as the
answer (`instancesStillRunning`).

## Plan-usage statistics

Surfaces each account's plan limits (5-hour / weekly / weekly-scoped-model / extra
credits), warns before a limit bites, and keeps a local history for analysis. On by
default, fully optional (Settings → Usage) — and the trust-model change it forces is
documented in [README.md](../README.md) and [SECURITY.md](../SECURITY.md).

**The account owns usage, not the profile.** Limits belong to the Anthropic
subscription, so N launchers on one account must issue **one** `/usage` call.
`AccountResolver` decrypts every binding's token locally first, then merges only what is
*provably* one account — bindings holding the **identical token** (same fingerprint, e.g. a
cloned user-data dir) — electing one binding per group: valid (unexpired + `user:inference`)
→ latest `expiresAt` → stable id. The default account is a first-class peer, resolved from its
own user-data-dir. A binding whose token can't be read maps to a login-needed / no-source UI
state; an account is only "login needed" if **every** binding fails.

**Neither the org nor a config hint is an account key.** A Team/Enterprise org holds many
accounts, so keying on `organizationUUID` would collapse two profiles signed in as different
users. The config's `lastKnownAccountUuid` is no safer as a *key* — it can lag the actual token
(a re-login, a copied dir), so merging on it would file one account's usage under another. So
distinct tokens are **never** merged locally — each stands alone as a **provisional** account
keyed by its token fingerprint — and `UsageService` settles the real account with a `/profile`
call. The fingerprint is a stable placeholder (a changed token changes it), so it can't flip
mid-life the way a hint could; and the moment `/profile` first resolves the real uuid,
`UsageHistoryStore.reassignAccount` moves the throttle window, samples, and notification ledger
off the fingerprint onto it — so the key promotion orphans nothing.

**A profile stays on its login even when we can't read it.** That is a *display* question, and
it has a different answer from the keying one above. A binding belonged to its account only
while it could itself present that account's token, so one failed decrypt did not make a profile
"temporarily unreadable" — it removed it from the login entirely, name and membership included.
Three defects came out of that: a profile with an expired, never-identified token stood alone as
a fingerprint-keyed phantom showing an orange "Sign in" beside a sibling on the same login
showing real figures; a cold start could not name a signed-out profile at all (the "was ps@…"
clause needed a snapshot carried within the same process, and the map is empty at launch); and a
profile we merely could not read went silent on every surface.

The answer is the same `lastKnownAccountUuid`, under a boundary that makes it safe:

> **The hint decides how a profile is displayed, never where usage is filed.**

`DesktopSafeStorageProvider` returns a `BindingReading` — the token arm plus the plaintext hint,
lifted out immediately after the JSON parse so it survives every way the token work below it can
fail. `AccountResolver` carries it in a separate `ResolvedAccounts.hints` channel, collected only
for bindings that cannot spend a token (none readable, or the readable one expired), so a healthy
fleet pays nothing; grouping and election never see it. `UsageService.merge` is the only consumer,
and it runs after every call and every write — so nothing a hint resolves can reach a storage key.
Three shapes, told apart by the failure that brought them: an **expired** token takes the name and
the membership but keeps "Sign in" (its own credential is dead, and its row is the only place that
can say so); a profile **signed in but unreadable** takes the account's current figures from
whichever sibling resolved, while still naming its own blocker; a **signed-out** one takes the name
and nothing else — no figures, and no place in its former sibling's "shared with N profiles".

A binding's published state has **two halves**, and both are folded, through one rule. Beside the
per-binding account map the app publishes a per-binding *failure* map, which is the only voice a
binding has when nothing could be resolved or carried for it — a profile signed out before launch
on a machine whose `account_profiles` cannot name its login. Only a sign-out may speak without an
account (`UsagePresentation.speaksWithoutAccount`), so a single poll that read `config.json` mid-
rewrite used to replace `.signedOut` with `.configUnreadable` and take the row's account line, cell
and menu suffix with it. `UsageService.mergeFailures` folds that map exactly as `merge` folds the
other, sharing the stickiness rule rather than paraphrasing it: a binding that had already lost its
login does not regain one because the next pass could not read the file that would say so. The rule
stays narrow to `.configUnreadable` — every other failure names a real, current blocker, and a
keychain refusal held behind a stale "signed out" would never be shown at all.

Four bounds, each with a test. A hint may only point at an account something else already
knows — this pass's results, else `account_profiles` via `UsageHistoryStore.profile(accountUUID:)`
— so a stale hint can misattribute a row to a real login and can never invent one. A hint never
overrules `/profile`: only a still-**provisional** identity may take a name from a config. Donors
are read from the pass's own accounts, never from the map being built, so attachments cannot chain.
And nothing is written — no `/usage`, no `/profile`, no sample, no throttle row — or the next real
fetch for that login would be gated by a floor it never earned.

The interaction worth naming: `shouldSelfHeal` guards on *nothing having resolved*. Had hints
minted accounts, a machine whose safeStorage key had rotated would present a full account list
beside an empty token set and lose fleet-wide key recovery **silently**. The separate channel is
what keeps that guard true.

Residual risks, accepted deliberately: a hint that lags a re-login can show the previous login's
figures on a row whose token happens to be unreadable at that moment (display only, self-corrects
on the first readable pass); `account_profiles` is promoted from a cache to the local account
directory and is not pruned, so a login the user has left keeps naming its former profile; and a
`usageSchemaVersion` bump drops that directory, after which only a token that gets identified can
put a row back. For a login with a readable profile that is the next pass — but for one whose only
profile is signed out there is no token to identify, so **that account stays unnameable until the
user signs in again**, not for a pass. Two other plaintext signals were examined and rejected:
`dxt:allowlist*:<orgUuid>` keys **accumulate historically** (a profile carries one per org it has
ever touched, so they name no current account), and `windowSizeWasSignedIn` could only ever
*demote* a live profile out of its login on a stale `false`, which is strictly worse than the
status quo.

**N launchers, one login — still one account.** Wanting several windows on one login is a
normal reason to make several launchers; each carries its own token, so they resolve as
separate provisional accounts. `UsageService` settles identities **before** fetching anything,
then `AccountResolver.regroup` folds the ones whose `/profile` returned the **same authoritative
uuid** — the only signal that proves two different tokens share an account — union the bindings,
re-elect the healthiest token, keep the named identity. Election lives here, not in the local
merge (which only ever sees identical tokens). Without this pass one login would issue N
`/usage` calls on *every* poll, store N rows for one account, and never say "shared with N
profiles". The trade is deliberate — over-splitting costs one extra `/profile` per token for a
moment, collapsing on a fallible hint would show the wrong account's numbers.

**Naming the account, cheaply.** Launcher names are whatever the user typed, so `/profile` is
also what ties a row to a real login (email / display name, surfaced in the Usage header and the
sidebar tooltip). The answer is cached in `account_profiles` keyed by the **token fingerprint** —
the only local id that authoritatively maps to an account — so a re-login (new token → new
fingerprint) simply misses and re-fetches, with no stale-hint risk. `UsageService.profileTTLSeconds`
(24h) bounds staleness. Each distinct token costs one `/profile` per day; a cloned sibling shares
the token, hence a cache hit and no extra call.

`/profile` is **authoritative about which account a token belongs to**, and identity comes only
from the token — its fingerprint locally, `/profile`'s uuid authoritatively — never a config
hint. Reading the cache is free and happens on every pass, so a throttled account still renders
with its name; the network call is made only when a `/usage` fetch is happening anyway, which
keeps it inside the same floor and backoff — never once per throttled tick. When identity can't
be refreshed (offline, or an expired token past its TTL), it is recovered from any stored
`/profile` row for the fingerprint — that mapping never goes stale — so serve-stale, the
throttle, and the ledger still key on the real account.

**Token source — Electron safeStorage, no separate keychain entry.** Desktop tokens
live inside each account's `config.json` under `oauth:tokenCacheV2`, encrypted by
Electron safeStorage. `SafeStorageDecryptor` reproduces the recipe with **CommonCrypto**
(CryptoKit has neither PBKDF2 nor AES-CBC, so this adds zero SPM deps): read the keychain
secret, `PBKDF2-HMAC-SHA1(salt "saltysalt", 1003 iters, 16 bytes)`
→ AES-128-CBC (IV = 16 spaces), strip the `v10` prefix, PKCS7-unpad. The plaintext is a
map keyed `<clientId>:<orgUuid>:<audience>:<scopes>`; the audience contains colons, so
entries are matched by substring, never split on `:`.

The keychain **service** (`"Claude Safe Storage"` = `<app name> Safe Storage`) is stable,
but the **account** is not, and we deliberately don't hard-code it. Chromium's `os_crypt`
migration to its async provider stores the *same* password under a second account:
`keychain_password_mac.mm` (sync) writes `"Claude"`, `keychain_key_provider.mm` (async)
writes `"Claude Key"` — and a given machine carries one, the other, or both depending on its
Claude version and migration state (all three were observed while building this; the shipping
`v10` blob decrypts under either password). So `SafeStorageKeyStore` (an actor) enumerates
every account under the service — attributes only, `kSecReturnData: false`, so the discovery
never prompts — and keeps whichever derived key actually *decrypts* the token cache (a probe
the caller supplies). Guessing an account name would silently break on the next provider
rename; keying off the stable service does not. Reading is **two-pass**: a prompt-free
non-interactive pass over every account first (so an already-authorized account — even a stale
one — is tested without a dialog), then an interactive pass only for accounts that are actually
locked, so a stale item never adds a second "Always Allow" prompt merely by existing. The
derived key is then cached for the process lifetime, so a fleet of accounts costs **one**
keychain access — and one "Always Allow" prompt. Background polls read with
`kSecUseAuthenticationUISkip` so a locked/unauthorized
keychain fails fast (serve stale) instead of prompting mid-poll; the prompt is deferred to an
interactive Refresh. No item at all under the service reads as `.notFound` (Claude never
signed in here) — distinct from an access refusal, so the UI can point at the right fix.

**Which cache may speak for the login.** An upgraded profile carries both `oauth:tokenCacheV2`
and the legacy `oauth:tokenCache`, and neither presence nor decodability says which of them holds
a live token — so both are read, and the whole rule is **the live cache is asked first and its
answer stands**; a sibling only ever fills a silence. "Live" means v2 wherever it exists, v1 when
there is no v2.

Two answers count as an answer, and the second was the expensive one to learn:

- **Empty.** Desktop's logout rewrites the cache as an encrypted `{}` rather than removing the
  key, so an empty live cache *is* the sign-out and the read stops there. Falling through to a
  populated legacy sibling — which is what the code did until this was traced — handed a
  signed-out profile a token anyway: still inside its validity it produced real, current,
  unmarked figures for a login the user had left, and expired it produced "Sign in" with the
  account's stored bars beside it. Neither could be caught downstream, because every rule that
  strips a signed-out row's figures keys on a verdict that shape never reached. The
  justification for that fall-through — "an emptied v2 can sit beside a v1 that still has the
  entries" — was a conjecture, and reverse-engineering Desktop 1.24012.9 refuted it: the two
  caches have **separate** clear functions, the legacy one called from several sites and the
  live one's whole-map clear from none in that build. The shape it was protecting is the
  opposite one, and that one still works (below).
- **Entries.** Election runs over every populated cache, so a foreign-only v2 — another OAuth
  client's entries, or an organization the user has left — cannot bury a usable token sitting
  decrypted in the v1 beside it. `.noUsableEntry` is therefore a verdict about the *profile*,
  not about one of its caches.

Silence is the only case a sibling answers: an **absent or undecryptable** live cache said
nothing, so a populated legacy one is all there is and it speaks. And when nothing readable held
anything, the verdict is the failure, never a sign-out — `.signedOut` is a positive claim (it
costs the binding its figures, detaches it from its account's fan-out, and tells the user to sign
in), and the cache that would have supported it is precisely the one that defeated us. Reporting
the honest reason is also what lets the fleet-wide self-heal recognise a rotated key.

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
high *and* the window is early: 5h (0.80, 0.72), 7d (0.75, 0.60) — each tier sits below the
0.90 absolute or it could never fire) plus an absolute near-exhaustion tier (0.90 warning /
0.95 critical), floored at 0.70, firing only the single most-severe tier per limit. The app
layer (`AppModel+UsageNotifications`) posts the warnings via `UNUserNotificationCenter`,
deduped against `notified_thresholds` so each threshold fires once per reset window.

## macOS facts baked into the code

- **Keep `CFBundleIconName` OUT of launcher Info.plists.** When present, macOS reads
  the icon from `Assets.car` and ignores our `.icns`. We write only `CFBundleIconFile`,
  pointed at the content-addressed badge resource (below).
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
  regenerate the whole bundle (script + Info.plist + icon) from the current format,
  *including* a running launcher (below). The marker reads an absent version as `1`, so
  pre-versioning launchers are stale.
- **A running profile does not block rewriting its launcher.** The bundle is a bash script
  that `exec`s the real Claude binary, so the live process is **not** executing out of it
  and holds nothing in it open; `LauncherBundle.build` assembles into a staging directory
  and swaps it in atomically. `update`, `rebuild` and `rebuildAll` therefore run while the
  profile is up and report it through `LiveRewrite` (the pid observed at the write) instead
  of refusing. What a rewrite genuinely cannot reach is the **running instance**, which
  keeps the window name and Dock tile it launched with — so the app shows that profile a
  *Restart to apply* nudge, retired automatically once the pid changes or the instance
  stops. `remove` still refuses while running: trashing the bundle out from under a profile
  the user may relaunch is a different act from rewriting it, and so does `add`, whose
  refusal is about re-creating a launcher over a user-data dir that already has an instance
  live. The old blanket refusal was worse than an inconvenience: a wrapper-version bump
  makes every launcher stale at once, and **Rebuild** is how the new format reaches them —
  gating it on "not running" put each fix out of reach of exactly the profiles someone
  keeps open all day.
- **Name the badge resource after its own bytes, or an edited icon never appears.** A
  launcher rebuild presents the same bundle *identity* every time — same path, same
  `CFBundleIdentifier`, same `CFBundleVersion` (launchers ship a fixed `1`) — so when it
  also points at the same constant `Badge.icns`, IconServices has nothing to tell the new
  icon apart by and goes on serving the image it already rendered, `lsregister -f` +
  `touch` included. That is why changing a profile's colour used to leave the Dock, and
  Finder, showing the previous badge indefinitely. The resource name is the one part of
  that identity we control, so `LauncherBundle.iconFileName` derives it from the icon:
  `Badge-<sha256(icns)[:16]>.icns`, with `CFBundleIconFile` pointing at it. New bytes ⇒ new
  name ⇒ an icon nothing has rendered yet. Nothing accumulates — `build` assembles into a
  fresh staging directory, so the previous name leaves with the bundle it belonged to.
  The read side follows the same rule: `build` compares against the installed bundle's
  *recorded* `CFBundleIconFile` rather than a hardcoded name, which keeps it correct
  against a pre-v4 launcher — and it treats a changed **name** as an icon change, not only
  changed bytes. That last part is not a detail: a pre-v4 launcher that was already edited
  holds the current bytes behind a stale-rendered name, so a byte-only check would call the
  migration rebuild "unchanged" and withhold the Dock refresh from exactly the launchers
  this fix exists for.
- **Icon cache is sticky, but a rebuild never flashes the screen.** Content-addressing
  settles what the *cache* answers; a tile the Dock has **already drawn** is a second,
  opaque cache on top of it, and no write reaches that one — there is no documented
  per-bundle refresh. Only restarting the Dock repaints it, and that flashes the whole
  screen (the Dock repaints the wallpaper as it relaunches). So the Dock restart is
  **never** issued silently by a rebuild. Instead every write reports whether the icon
  actually changed (`add`/`update`/`rebuild`/`rebuildAll` surface a `dockRefreshPending`
  flag) and the app offers an opt-in **Refresh Dock now** banner. `IconCache.restartDock`
  signals `iconservicesagent` *before* `killall Dock`, and the order matters: the Dock does
  not render the image it draws, it asks that agent, so restarting the Dock alone hands it
  back to a live process holding the old render. `killall` only *sends* SIGTERM, and macOS
  has no `-w` (that flag is Linux's), so `restartDock` polls `pgrep` for a bounded spell to
  let the agent actually exit before the Dock comes back. Treat the agent kill as
  best-effort, **not** a guarantee: the agent also reads a persistent on-disk store only
  root can remove, so for a *pre-v4* bundle a relaunched agent can answer from the same
  stale entry — there the real remedy is the rebuild onto a content-addressed name.
  A rebuild that leaves the icon unchanged (a wrapper-format bump, the common case) sets
  nothing and shows no banner.
  **Do not promise a pinned tile "self-heals the next time you open it"** — it is not
  observed to, and wording the banner that way sends the user off to wait for a repaint
  that never comes. For the same reason the refresh is reachable from **Settings → Badge
  style → Refresh Dock icons** and not only from the dismissible banner, whose flag is
  in-memory: dismissing it, or relaunching the app, must not leave a stale tile with no
  in-app remedy.
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
  `IconCache.register` is safe — `lsregister -f` and `touch` change mtime, not content.
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
`lsregister` / `iconutil`, and can restart the Dock (the opt-in icon refresh). It ships **Developer ID +
notarized**, never the App Store. Hardened Runtime is on; entitlements are minimal
(no sandbox, apple-events for activation). See [RELEASING.md](RELEASING.md) for the
signing, notarization, and auto-update pipeline.

It self-updates via Sparkle, but the updater stays **dormant in local/dev builds** —
when `MARKETING_VERSION` is the `0.0.0` placeholder (`CoreConstants.isDistributionBuild`
is false), so a developer isn't nagged to overwrite their own build with a published
release. A release injects a real version from the git tag and the updater activates.

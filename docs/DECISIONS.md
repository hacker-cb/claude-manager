# Design decisions

Design rationale worth keeping out of the day-to-day docs but not out of the repo.

## Why a thin script launcher (wrapping strategies tested)

The goal: run multiple isolated Claude Desktop profiles without breaking anything
the real, Apple-notarized app relies on. Every wrapping strategy below was tried on
macOS (Apple Silicon); only the thin script launcher survives.

| Wrapper | Outcome |
|---|---|
| **Script launcher `exec`ing the real binary** | ✓ works — **this is the tool's approach** |
| Bundle with symlinked binary / Frameworks | ✗ `open` fails (-54) or SIGKILL |
| Hardlink farm | ✗ instant SIGKILL by AMFI |
| APFS clone + ad-hoc re-sign | ✓ runs, ✗ entitlements stripped |
| Full copy + ad-hoc re-sign | ✓ runs, ✗ entitlements stripped, 700+ MB |

**The decisive factor is entitlements.** Any approach that re-signs the bundle
ad-hoc strips Anthropic's entitlements, which observably breaks notifications
(`usernotificationsd` rejects the modified bundle id) and virtualization-based
features (`virtualization_entitlement_missing`). The copy-based approaches also cost
hundreds of MB per profile and go stale on every Claude update.

The thin launcher sidesteps all of it: its executable is a bash script that `exec`s
the **untouched** signed Claude binary with an isolated `--user-data-dir`. The
running process keeps Anthropic's signature and entitlements, and Claude
self-updates transparently because there is nothing of ours to rebuild.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the macOS facts that follow from this
choice.

## Signing launchers: `codesign`, not the in-process signer

A launcher bundle has to carry a signature or macOS refuses to execute it (see
[ARCHITECTURE.md](ARCHITECTURE.md) § macOS facts). It can only ever be an **ad-hoc**
signature: launchers are generated on the user's machine, where no Developer ID
certificate exists. That is enough here — ad-hoc gives integrity, which is what the
execution policy wants, and the bundle is not quarantined, so authenticity (certificate,
Team ID, notarization) never enters the picture.

The open question was how to produce it, and the in-process route was tried first:
`Security.framework`'s `SecCodeSigner` signs with no subprocess and no dependency on a
command-line tool. It ships no public header (only the readers `SecStaticCode.h` /
`SecCode.h` do), but the symbols are exported from `Security.tbd` and have been stable
since 10.5, so a small pinned re-declaration was enough to call it from Swift. It signed
correctly.

**It was rejected because it deadlocks under a saturated thread pool.**
`SecCodeSigner::Signer::prepare` fans its resource hashing out over a dispatch group and
blocks the calling thread in `Dispatch::Group::wait()`. When many launchers are built at
once — exactly what the parallel test suite does — every worker ends up parked in
`__ulock_wait` with nothing left to run the hashing, and the process wedges forever. A
sample of the hung run showed all cooperative-pool threads inside `signAdHoc`. Neither
mitigation helped: serializing signing behind a process-wide lock just moved the threads
from `dispatch_group_wait` to the lock, and running the call on a dedicated non-pool
thread still starved the group of workers. (`SystemCommandRunner` carries a comment
about the same class of starvation biting `Process.waitUntilExit`.)

So signing shells out to `/usr/bin/codesign` through the existing `CommandRunner` seam.
The subprocess has its own thread pool, so the hazard cannot arise; the seam is the one
every other external tool already uses (`lsregister`, `iconutil`, `pgrep`, …); and
`codesign` is base macOS rather than an Xcode Command Line Tools shim — on a test machine
the known CLT shims (`git`, `clang`) are the same 118,928-byte stub with an identical
md5, while `codesign` is a distinct 459,824-byte binary. A signing failure is surfaced as
`ClaudeManagerError.codeSigningFailed` rather than a raw command error, because the
consequence is specific: an unsigned launcher will not run.

Tests assert the *result* through the public reader API (`SecStaticCodeCheckValidity` +
`SecCodeCopySigningInformation`) rather than by echoing the `codesign` invocation, and
the store suites delegate `codesign` to the real system (like `iconutil`), so they
exercise the signing path the app actually takes.

## Disabling clone auto-updates, and the overlay shape

Every clone `exec`s the one on-disk Claude.app, so a clone running Claude's Squirrel
updater gains nothing and costs plenty: N profiles each check the feed and download the
same build into one shared ShipIt cache, with a "restart to update" nag per clone. So
Claude Manager disables the self-updater **on clones only** (the `disableAutoUpdates`
policy key) and lets the **default profile be the update leader** that checks,
downloads, and stages.

Two shapes were settled by reverse-engineering Claude's real resolver, not by guessing:

| Choice | Tried | Kept |
|---|---|---|
| Policy key shape | nested `autoUpdate.disabled` | **flat top-level `disableAutoUpdates`** — the nested form is ignored |
| Config tier | MDM `/Library/Managed Preferences` plist | **local `<userData>-3p/configLibrary` tier** — no admin rights, per-profile |
| `appliedId` check | strict RFC-4122 UUID | **Claude's own loose `/^[a-f0-9-]{36}$/`** — a stricter check could reject an id Claude applied |

When an MDM managed-preferences plist *is* present it overrides the local tier, so the
writer detects that and skips rather than writing something Claude will ignore. Writes
**merge rather than clobber** (and no-op when unchanged), so CM never drops a key Claude
keeps there and never churns a file it may be reading.

## Owning `claude://` without a config footgun

The broker makes Claude Manager the default `claude://` handler. Keeping profiles from
re-grabbing it had two options:

- Write `disableDeepLinkRegistration` into each profile's overlay.
- Hold the handler at runtime with an event-driven guard and **never write that key**.

The overlay key is a footgun in two ways. For the **default profile**: if Claude Manager
is removed (or crashes) **without first disabling the broker**, the key persists with
nothing to take over, silently breaking the default's deep links. (That reasoning still
holds for `disableDeepLinkRegistration`, which is never written. It is *knowingly*
accepted for `disableAutoUpdates` — see "Taking Claude's updates off Squirrel" below,
which explains what is done about the orphan it can leave.) For **clones**: the
same key makes Claude *drop* every forwarded non-auth link
(`dropping deep link (disableDeepLinkRegistration)`) — defeating the very hand-off the
broker exists to perform. So **no profile carries it**: `ProfileManagedConfig` writes only
`disableAutoUpdates` (on clones), and keeps `disableDeepLinkRegistration` in `managedKeys`
only so a reconcile *removes* one an older build wrote. The guard degrades gracefully: it
stops re-asserting the moment CM isn't running, and LaunchServices falls back to Claude.

Three smaller calls followed:

- **Event-driven, not polled.** CM reclaims the handler on the
  `user.uid.<uid>.com.apple.LaunchServices.database` Darwin notification (it fires
  *after* the change, so the re-assert lands last), reached via
  `CFNotificationCenterGetDarwinNotifyCenter()` — pure CoreFoundation, so the app target
  needs no bridging header.
- **On by default.** Claude Manager should be fully functional out of the box, and the
  guard-based hold makes on-by-default uninstall-safe.
- **Always a picker.** A `claude://` URL carries no profile identity, so auto-forwarding
  would only guess; the user picks. Forwarding sends the URL as a `GURL` Apple event to the
  target's **pid** (`DeepLinkDelivery`): Claude reads deep links only from `open-url`, never
  `argv`, and every profile shares one bundle id, so a pid is the only way to address a
  *specific* instance — a running target gets it directly, a stopped one is launched first.
  (One-time TCC Automation grant, "Claude Manager" → "Claude", covers all profiles.)

## Coordinating a Claude update across profiles

Claude Manager does **not** swap `/Applications/Claude.app` itself — that's ShipIt's
(Squirrel.Mac's) job, and it only swaps with **zero running real-Claude instances**.
CM's role is to clear the blockers and get out of the way: quiesce every profile, wait,
then relaunch. It confirms success by polling the **on-disk** version with `>=` (not
equality), because ShipIt may land a build newer than the one staged when the apply
began.

Quiescing is **graceful (SIGTERM) only** — never SIGKILL, which could kill an active
conversation. If any profile won't exit in time, CM **aborts before the swap window**
and reopens what it stopped rather than force it. Two guards keep the coordination safe:
the zero-instance gate counts only processes at the real Claude binary path (CM's own
"Claude Manager" matches the generic "Claude, ppid 1" probe and would otherwise block
its own swap forever), and every relaunch is conditional on the profile being currently
down (a second `open -n` on a live default duplicates it on one user-data-dir and
corrupts LevelDB — and ShipIt often relaunches the default itself).

**"Wait" means watching ShipIt, not a timer — rejected: a fixed swap timeout.** The
obvious shape is "poll the version for N seconds, then give up", and it was wrong in a
way that only showed up in the field. The swap normally takes 3–5 s, so 30 s looked like
a generous margin; then a swap took 57 s under disk contention, the timer fired,
CM relaunched the profiles, and ShipIt — which re-checks its instance count *after*
copying — aborted with `App Still Running Error`. The timeout did not merely fail to
help, it destroyed an install that was succeeding, and each destroyed attempt re-downloaded
~800 MB. Since the duration has no upper bound we can know, CM asks the installer instead:
while a ShipIt process for our bundle is alive, nothing is relaunched. The poll budget
survives only as a backstop, and when it expires with ShipIt still working, CM leaves the
profiles closed rather than trade a working install for an open window.

**Offering when it's stuck — rejected: on by default with a one-time announcement.** Leaving
unattended applying off has a real cost: a Mac running clones never installs a Claude update
by itself, and Claude's own enforcement restarts the default profile every ~72 h to no effect.
The obvious answer is to flip the default and announce the change once. It was written, and
then rejected in review.

The flaw is structural rather than a bug: the action (closing every profile overnight) and the
safeguard (the notice) are **independent**. When the notice fails to arrive, nothing falls back
to the safe state — the feature simply runs. And it fails in ordinary ways: notifications
denied, which for a menu-bar app is common and permanent; authorization still `.notDetermined`
on the first launch, where the request is issued moments earlier and never awaited; and a
released version having already shipped the toggle *off*, which makes "no key written"
indistinguishable from "saw it and chose not to". Making the default safe needed a fallback
banner, a gate on delivery, a re-check inside the session and a migration — four props holding
up one flag, each of them new code on a path that runs at night with nobody watching.

This whole section is now history: the release that took updating over removed the staged-apply
path, the nightly window and the offer along with it. Kept because the reasoning still applies
to anything unattended that closes the user's windows — consent and the action it licenses have
to be one event, and an announcement the user may never see is not consent. Installing is a
press, and only a press.

**Deciding whether a profile is busy is Claude's job — rejected: a busy-detector in CM.**
An auto-apply wants to know "is this profile actually working?", and nothing observable
from outside answers it: power assertions don't track agent work, CPU across the process
tree measures UI rendering, and the session process itself sits near 1% whether it is
working or idle, because an agent spends its time waiting on the network. Claude already
answers it correctly — a profile with a running session vetoes its own quit and offers
"Quit anyway / Wait for Claude / Cancel", while an idle-but-open session quits cleanly.
So CM asks by attempting a graceful stop and reads the refusal as the answer, which also
means the protection holds even for cases CM never modelled.

## Taking Claude's updates off Squirrel — and what that costs

Claude Manager now switches `disableAutoUpdates` on for the **default profile** as well
as for clones, and fetches, verifies and installs Claude itself.

The reason is that the old arrangement had no stable state. Clones block Squirrel's
installer (it aborts unless *zero* instances are running), so a machine with profiles open
accumulates a downloaded-but-unapplied build; Claude then force-restarts the default
profile roughly every 72 h trying to install it, and each destroyed attempt costs a fresh
download. `autoUpdaterEnforcementHours` cannot be disabled — the policy validates as
`>0 && <=72`, so it can only be shortened — and nothing but `disableAutoUpdates` stops
that timer arming at all.

**The cost, stated plainly.** Writing that key into the default profile is exactly what
the deep-link decision above refuses to do, for exactly the reason given there: if Claude
Manager is removed without first switching the feature off, the key persists with nothing
to take over, and Claude stays on its current build forever. That is a real hole and it is
accepted knowingly, because the alternative — leaving Squirrel armed — is a machine that
force-restarts a working profile every three days and never finishes the install anyway.

Three things narrow it:

- The setting is a plain toggle, and turning it off *removes* the key rather than writing
  `false`, so handing the job back is one click and leaves no fossil.
- `README.md` § Uninstall makes switching it off step one, and says where the file is for
  anyone who has already removed the app.
- Doctor warns when this app is in charge and the release feed has not answered
  successfully in a week, and **Settings → Claude updates** carries the same stamp beside a
  **Check Now** that asks immediately and says what came back — a build, "up to date", or the
  reason the service could not be reached. Between them they cover the quiet version of this
  failure — a blocked feed, with Claude's updater off and a healthy-looking machine — which
  is otherwise invisible: a background check that never reaches Anthropic leaves the state
  `.idle`, which is exactly what a check finding nothing leaves behind. A check the user
  *asked* for is the exception, and lands on `.failed` so the reason is on screen.

**Doctor's Squirrel diagnostics went with it.** The old health check reported a staged
update blocked by open profiles, an installer that had been waiting for minutes, and what
the last failed attempt said. Those describe a world where Squirrel is in charge, and with
managed updates on it no longer is. They are *not* restored for the hand-back case, and that
is a knowing gap: switch the feature off and you are back in the original situation —
Squirrel stages a build, cannot apply it while clones are open, and waits indefinitely and
silently — with nothing pointing at it. The reasoning is that the setting exists as an escape
hatch, its own Settings text says plainly that this app cannot control what happens next, and
carrying a whole diagnostic subsystem for a mode nobody is expected to sit in permanently is
worse than saying so. If people do sit in it, the check to restore is
`stagedUpdateDiagnostics` in the history of `Doctor+StagedUpdate.swift`.

What is deliberately *not* done: restoring the key when the app quits. A menu-bar app is
closed all the time, and re-arming Squirrel on every quit would put back the 72-hour
restart cycle this exists to remove.

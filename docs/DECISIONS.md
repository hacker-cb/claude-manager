# Design decisions

Design rationale worth keeping out of the day-to-day docs but not out of the repo.

## Why a thin script launcher (wrapping strategies tested)

The goal: run multiple isolated Claude Desktop accounts without breaking anything
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

## Disabling clone auto-updates, and the overlay shape

Every clone `exec`s the one on-disk Claude.app, so a clone running Claude's Squirrel
updater gains nothing and costs plenty: N accounts each check the feed and download the
same build into one shared ShipIt cache, with a "restart to update" nag per clone. So
Claude Manager disables the self-updater **on clones only** (the `disableAutoUpdates`
policy key) and lets the **default account be the update leader** that checks,
downloads, and stages.

Two shapes were settled by reverse-engineering Claude's real resolver, not by guessing:

| Choice | Tried | Kept |
|---|---|---|
| Policy key shape | nested `autoUpdate.disabled` | **flat top-level `disableAutoUpdates`** — the nested form is ignored |
| Config tier | MDM `/Library/Managed Preferences` plist | **local `<userData>-3p/configLibrary` tier** — no admin rights, per-account |
| `appliedId` check | strict RFC-4122 UUID | **Claude's own loose `/^[a-f0-9-]{36}$/`** — a stricter check could reject an id Claude applied |

When an MDM managed-preferences plist *is* present it overrides the local tier, so the
writer detects that and skips rather than writing something Claude will ignore. Writes
**merge rather than clobber** (and no-op when unchanged), so CM never drops a key Claude
keeps there and never churns a file it may be reading.

## Owning `claude://` without a config footgun

The broker makes Claude Manager the default `claude://` handler. Keeping accounts from
re-grabbing it had two options:

- Write `disableDeepLinkRegistration` into each account's overlay.
- Hold the handler at runtime with an event-driven guard and **never write that key**.

The overlay key is a footgun in two ways. For the **default account**: if Claude Manager
is removed (or crashes) **without first disabling the broker**, the key persists with
nothing to take over, silently breaking the default's deep links. For **clones**: the
same key makes Claude *drop* every forwarded non-auth link
(`dropping deep link (disableDeepLinkRegistration)`) — defeating the very hand-off the
broker exists to perform. So **no account carries it**: `ProfileManagedConfig` writes only
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
- **Always a picker.** A `claude://` URL carries no account identity, so auto-forwarding
  would only guess; the user picks. Forwarding sends the URL as a `GURL` Apple event to the
  target's **pid** (`DeepLinkDelivery`): Claude reads deep links only from `open-url`, never
  `argv`, and every account shares one bundle id, so a pid is the only way to address a
  *specific* instance — a running target gets it directly, a stopped one is launched first.
  (One-time TCC Automation grant, "Claude Manager" → "Claude", covers all accounts.)

## Coordinating a Claude update across accounts

Claude Manager does **not** swap `/Applications/Claude.app` itself — that's ShipIt's
(Squirrel.Mac's) job, and it only swaps with **zero running real-Claude instances**.
CM's role is to clear the blockers and get out of the way: quiesce every account, wait,
then relaunch. It confirms success by polling the **on-disk** version with `>=` (not
equality), because ShipIt may land a build newer than the one staged when the apply
began.

Quiescing is **graceful (SIGTERM) only** — never SIGKILL, which could kill an active
conversation. If any account won't exit in time, CM **aborts before the swap window**
and reopens what it stopped rather than force it. Two guards keep the coordination safe:
the zero-instance gate counts only processes at the real Claude binary path (CM's own
"Claude Manager" matches the generic "Claude, ppid 1" probe and would otherwise block
its own swap forever), and every relaunch is conditional on the account being currently
down (a second `open -n` on a live default duplicates it on one user-data-dir and
corrupts LevelDB — and ShipIt often relaunches the default itself).

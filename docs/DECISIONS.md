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

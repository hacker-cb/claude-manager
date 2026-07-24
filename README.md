# Claude Manager

Run **multiple Claude Desktop profiles side by side** on macOS — each in its own
window, with its own login, settings, and extensions — using tiny launcher apps
instead of full copies of Claude.app.

> _Claude and Claude Desktop are products of Anthropic. Claude Manager is an
> independent, unofficial tool — not affiliated with, sponsored by, or endorsed by
> Anthropic._

![Claude Manager — the management window with two profiles, showing a running
profile's badge, status, and paths](docs/images/main-window.png)

Each profile is a ~1 MB launcher `.app` with its own badge icon and name. Opening
it starts the *real* `/Applications/Claude.app` with a dedicated `--user-data-dir`,
so every profile is fully isolated and can hold its own Claude account. Because the
real, Apple-notarized app runs untouched, notifications, Keychain access, and
virtualization features all keep working. Claude's own updates keep working too —
Claude Manager just **coordinates** them across profiles (so they don't each
download the same build) and can **route `claude://` login links** to the profile
you choose. See [Deep links](#deep-links) and [Updates](#updates).

## Requirements

- **macOS 14 (Sonoma) or later**, on Apple Silicon or Intel.
- **Claude Desktop** installed. Claude Manager finds it automatically via
  LaunchServices, wherever it lives (`/Applications/Claude.app` is the fallback). If
  it isn't detected, click **Re-detect** in **Settings → Real Claude**.

## Install

1. Download the latest **`ClaudeManager-X.Y.Z.dmg`** from the
   [**Releases**](https://github.com/hacker-cb/claude-manager/releases) page.
2. Open the DMG and drag **Claude Manager** into **Applications**.
3. Launch it. The app is **Developer ID–signed and notarized**, so a normal
   double-click opens it. If macOS ever shows a warning, right-click the app →
   **Open** once.

The app self-updates from then on (see [Updates](#updates)).

## Getting started

1. **Open Claude Manager.** It locates your installed Claude automatically — you
   can confirm the path in **Settings → Real Claude**.
2. **Add a profile.** Give it a display name, a short **badge label** (a few
   characters — 3 by default), and a **color** (palette or custom hex). This creates
   a launcher app next to Claude.app.
3. **Open it.** A dedicated Claude window launches with its own isolated login and
   settings. Sign in to that account.
4. **Repeat** for each profile, and use the **menu bar icon** for quick open/stop.

The first time you re-activate an *already-running* profile, macOS asks for
**Automation** permission (to bring its window to the front) — allow it once. See
[Permissions](#permissions).

## Features

- **Add / list / open / stop / remove** launcher profiles.
- Per-profile **badge label**, **color** (palette or custom hex), **display name**,
  and **bundle id**.
- **Menu bar extra** for quick open/stop, plus a full management window.
- **Menu-bar-first** — the Dock icon appears only while the management window is open;
  closing the window keeps Claude Manager in the menu bar (reopen and quit from the menu
  bar icon). Launched at login, it starts quietly in the menu bar. Optional **Launch at
  login** in **Settings → Startup** (off by default).
- **Doctor** — health checks for the real app, each launcher, orphaned profile
  dirs, version skew, and duplicate running instances.
- **Rebuild launchers** — regenerate a launcher (script + Info.plist + badge icon)
  after a Claude update or a launcher-format change; **Apply to all launchers** (in
  Settings → Badge style) rebuilds every profile at once.
- **Route `claude://` links to a chosen profile** — login / SSO / magic-link
  callbacks would otherwise always land in whichever Claude the system opens. Claude
  Manager intercepts them and shows a picker so you send each to the right profile.
  On by default; toggle in **Settings → Deep links**. See [Deep links](#deep-links).
- **Coordinated Claude updates** — clones don't each run Claude's own updater (only
  your default profile checks and downloads), and when a downloaded update is blocked
  by open windows, **Apply to all profiles** quits them, lets it install, and reopens
  the set. See [Updates](#updates).
- **Auto-update** — the app updates itself via Sparkle (each update EdDSA-signed),
  separate from Claude Desktop's own updates.

## Where things live &amp; privacy

- **Launcher apps** — one `<Name>.app` next to Claude.app (default `/Applications`).
  Configurable in **Settings → Launcher install location**.
- **Profile data** — each *launcher* profile's isolated `--user-data-dir`, default
  `~/Library/Application Support/Claude Manager/Profiles/<name>`. Configurable in
  **Settings → New profile data**. The **Default profile** is not one of these: it
  keeps Claude's own `~/Library/Application Support/Claude`, untouched.
- **App metadata** — a small JSON file of GUI-only state (ordering, notes) in
  `~/Library/Application Support/Claude Manager`. It is always optional: the launcher
  apps themselves are the source of truth.

Claude Manager **never reads your credentials or session tokens** — those live
inside each profile's user-data-dir and are managed by Claude itself. It keeps no
account data of its own; its only network activity is Sparkle **checking for and
downloading app updates** (see [Updates](#updates)). Routing a `claude://` link
registers Claude Manager as the local handler for that scheme (a LaunchServices
setting — no network) and hands the link to the profile you pick; it doesn't store or
inspect the link's contents.

## Permissions

- **Automation (System Events)** — asked **once**, only to bring an already-running
  profile's window to the front. It is not needed to launch a profile.
- **Notifications, Keychain, virtualization** keep working normally, because the
  untouched, signed Claude binary is what actually runs.

## Deep links

Claude Desktop registers itself as the handler for `claude://` links — a shared **Cowork
artifact**, a session **resume**, or an in-browser **login / SSO / MCP-auth** callback.
With several profiles that's a problem: the link lands in whichever Claude the system
opens, not the profile you meant.

**Claude Manager becomes the `claude://` handler (on by default)**, and when a link
arrives it shows a small picker so you choose which profile receives it — any launcher
profile or your default profile. That profile then opens the link itself.

- **Delivery works whether or not the target is already open** — Claude Manager hands the
  link to the chosen profile directly. The first time it does, macOS asks you to allow
  "Claude Manager" to control "Claude"; approve it once and it covers every profile.
- **Your default profile is never modified.** Claude Manager only *holds* the handler
  while it's running, so keep it running (e.g. **launch at login**) for links to be
  routed. Turning the broker off — or removing Claude Manager — hands `claude://` straight
  back to Claude.
- Toggle it under **Settings → Deep links** ("Route claude:// links to a chosen profile").
- **After updating to this version, restart any profiles you already had open** once, so
  they pick up the fix that lets forwarded links through; newly opened profiles need
  nothing.

## Updates

**Claude Manager** updates itself via [Sparkle](https://sparkle-project.org) — each
update download is EdDSA-signed. Use **Check for Updates…** in the app. This is
separate from Claude Desktop's own update mechanism.

**Claude Desktop** updates are coordinated so multiple profiles don't fight over them.
Every profile runs the one on-disk `Claude.app`, so a clone updating itself would just
re-download the build your default profile already fetches. So Claude Manager **turns
off the self-updater in clones** and lets your **default profile** be the one that
checks, downloads, and stages Claude updates. When an update is downloaded but can't
install because profiles are open, a banner (and a notification) offer **Apply to all
profiles** — it quits every profile, lets the update install, and reopens the ones
that were running.

## Troubleshooting

Open the **Doctor** tab for a health report. Common findings:

| Doctor says | What to do |
|---|---|
| _built by an older launcher format — rebuild to update_ | Click **Rebuild** on the launcher, or **Settings → Badge style → Apply to all launchers** for every profile at once. |
| _running vX — Claude vY available, restart to update_ | Quit and reopen that profile; Claude updated on disk while it was running. |
| _Claude vX staged but not applied — N running instance(s) block the swap_ | Click **Apply to all profiles** (window banner) or **Apply Claude vX to all profiles** (menu bar) to quit, install, and reopen everything at once. |
| _profile dir missing — created on launch_ | Informational — it launches fine and creates the dir. |
| _Real Claude.app is missing_ | Install Claude Desktop (found automatically wherever it lives). If it's installed but not detected, click **Re-detect** in **Settings → Real Claude**. |
| _Duplicate instances on one profile_ | Close the extra windows; the launcher normally prevents this. |
| Profile shows as **Intel** in Activity Monitor | An old launcher — **Rebuild** it to run native (arm64). |

## Known limitations

- **The real `Claude.app` Dock/Finder icon can focus a clone instead of launching
  your default profile.** If a launcher profile is already running and you then click
  the untouched `Claude.app` (Dock, Finder, Spotlight, or Launchpad), macOS may just
  bring the running *clone* to the front rather than starting your default profile.

  Why: a launcher runs the untouched, signed Claude binary in place, so every
  instance — clones and the original alike — shares Anthropic's one bundle id
  (`com.anthropic.claudefordesktop`). LaunchServices can't tell them apart, so a plain
  launch of the real app finds it "already running" and activates whichever instance
  it finds. This is inherent to the thin-launcher design (giving a clone a distinct
  identity would require re-signing, which strips the entitlements Claude needs — see
  [docs/DECISIONS.md](docs/DECISIONS.md)).

  **Workaround:** launch your default profile from Claude Manager instead — **Default
  profile** in the menu-bar extra, or the first sidebar row → **Open**. It activates
  the running default instance if there is one, otherwise starts a fresh one,
  regardless of what clones are running. Removing the raw `Claude.app` from your Dock
  avoids the trap entirely.

## Uninstall

1. In Claude Manager, **remove each launcher profile** (this deletes its launcher
   app). The **Default profile** has no launcher and nothing to remove.
2. Quit and drag **Claude Manager** to the Trash.
3. Optionally delete `~/Library/Application Support/Claude Manager` (per-profile data
   and app metadata).

Removing Claude Manager never touches your real `/Applications/Claude.app` or its
data. If it was handling `claude://` links, the scheme falls back to Claude on its own
once Claude Manager is gone (no cleanup needed).

## Contributing &amp; development

The core logic is a headless Swift package (`ClaudeManagerCore`); the SwiftUI shell
is an Xcode target generated by [XcodeGen](https://github.com/yonaskolb/XcodeGen).
Quick start:

```bash
make setup   # git hooks + brew bundle (xcodegen, swiftformat, swiftlint)
make test    # headless core suite
make run     # build (unsigned) and launch the app
```

- [**docs/DEVELOPMENT.md**](docs/DEVELOPMENT.md) — build, test, and tooling.
- [**docs/ARCHITECTURE.md**](docs/ARCHITECTURE.md) — how it works and the hard-won
  macOS facts behind the thin-launcher design.
- [**docs/RELEASING.md**](docs/RELEASING.md) — signing, notarization, Sparkle, and
  cutting a release.
- [**CONTRIBUTING.md**](CONTRIBUTING.md) — branch and PR flow.
- [**SECURITY.md**](SECURITY.md) — reporting vulnerabilities and the update trust
  model.

## License

[MIT](LICENSE) © 2026 Pavel Sokolov

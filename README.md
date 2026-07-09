# Claude Manager

Run **multiple Claude Desktop accounts side by side** on macOS — each in its own
window, with its own login, settings, and extensions — using tiny launcher apps
instead of full copies of Claude.app.

> _Claude and Claude Desktop are products of Anthropic. Claude Manager is an
> independent, unofficial tool — not affiliated with, sponsored by, or endorsed by
> Anthropic._

![Claude Manager — the management window with two profiles, showing a running
profile's badge, status, and paths](docs/images/main-window.png)

Each profile is a ~1 MB launcher `.app` with its own badge icon and name. Opening
it starts the *real* `/Applications/Claude.app` with a dedicated `--user-data-dir`,
so every profile is a fully isolated account. Because the real, Apple-notarized app
runs untouched, notifications, Keychain access, virtualization features, and
Claude's own auto-updates all keep working.

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
4. **Repeat** for each account, and use the **menu bar icon** for quick open/stop.

The first time you re-activate an *already-running* profile, macOS asks for
**Automation** permission (to bring its window to the front) — allow it once. See
[Permissions](#permissions).

## Features

- **Add / list / open / stop / remove** launcher profiles.
- Per-profile **badge label**, **color** (palette or custom hex), **display name**,
  and **bundle id**.
- **Menu bar extra** for quick open/stop, plus a full management window.
- **Stays in the menu bar** — closing the window leaves Claude Manager running in the
  menu bar; reopen it from the menu bar icon or the Dock, and quit with ⌘Q. Optional
  **Launch at login** in **Settings → Startup** (off by default).
- **Doctor** — health checks for the real app, each launcher, orphaned profile
  dirs, version skew, and duplicate running instances.
- **Rebuild launchers** — regenerate a launcher (script + Info.plist + badge icon)
  after a Claude update or a launcher-format change; **Apply to all launchers** (in
  Settings → Badge style) rebuilds every profile at once.
- **Auto-update** — the app updates itself via Sparkle (each update EdDSA-signed),
  separate from Claude Desktop's own updates.

## Where things live &amp; privacy

- **Launcher apps** — one `<Name>.app` next to Claude.app (default `/Applications`).
  Configurable in **Settings → Launcher install location**.
- **Profile data** — each account's isolated `--user-data-dir`, default
  `~/Library/Application Support/Claude Manager/Profiles/<name>`. Configurable in
  **Settings → New profile data**.
- **App metadata** — a small JSON file of GUI-only state (ordering, notes) in
  `~/Library/Application Support/Claude Manager`. It is always optional: the launcher
  apps themselves are the source of truth.

Claude Manager **never reads your credentials or session tokens** — those live
inside each profile's user-data-dir and are managed by Claude itself. It keeps no
account data of its own; its only network activity is Sparkle **checking for and
downloading app updates** (see [Updates](#updates)).

## Permissions

- **Automation (System Events)** — asked **once**, only to bring an already-running
  profile's window to the front. It is not needed to launch a profile.
- **Notifications, Keychain, virtualization** keep working normally, because the
  untouched, signed Claude binary is what actually runs.

## Updates

Claude Manager updates itself via [Sparkle](https://sparkle-project.org) — each
update download is EdDSA-signed. Use **Check for Updates…** in the app. This is
separate from Claude Desktop's own update mechanism.

## Troubleshooting

Open the **Doctor** tab for a health report. Common findings:

| Doctor says | What to do |
|---|---|
| _built by an older launcher format — rebuild to update_ | Click **Rebuild** on the launcher, or **Settings → Badge style → Apply to all launchers** for every profile at once. |
| _running vX — Claude vY available, restart to update_ | Quit and reopen that profile; Claude updated on disk while it was running. |
| _profile dir missing — created on launch_ | Informational — it launches fine and creates the dir. |
| _Real Claude.app is missing_ | Install Claude Desktop (found automatically wherever it lives). If it's installed but not detected, click **Re-detect** in **Settings → Real Claude**. |
| _Duplicate instances on one profile_ | Close the extra windows; the launcher normally prevents this. |
| Profile shows as **Intel** in Activity Monitor | An old launcher — **Rebuild** it to run native (arm64). |

## Known limitations

- **The real `Claude.app` Dock/Finder icon can focus a clone instead of launching
  your primary account.** If a launcher profile is already running and you then click
  the untouched `Claude.app` (Dock, Finder, Spotlight, or Launchpad), macOS may just
  bring the running *clone* to the front rather than starting your default account.

  Why: a launcher runs the untouched, signed Claude binary in place, so every
  instance — clones and the original alike — shares Anthropic's one bundle id
  (`com.anthropic.claudefordesktop`). LaunchServices can't tell them apart, so a plain
  launch of the real app finds it "already running" and activates whichever instance
  it finds. This is inherent to the thin-launcher design (giving a clone a distinct
  identity would require re-signing, which strips the entitlements Claude needs — see
  [docs/DECISIONS.md](docs/DECISIONS.md)).

  **Workaround:** launch your primary account from Claude Manager instead — **Open
  Claude** in the menu-bar extra (or the window toolbar). It activates the running
  default instance if there is one, otherwise starts a fresh one, regardless of what
  clones are running. Removing the raw `Claude.app` from your Dock avoids the trap
  entirely.

## Uninstall

1. In Claude Manager, **remove each profile** (this deletes its launcher app).
2. Quit and drag **Claude Manager** to the Trash.
3. Optionally delete `~/Library/Application Support/Claude Manager` (per-profile data
   and app metadata).

Removing Claude Manager never touches your real `/Applications/Claude.app` or its
data.

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

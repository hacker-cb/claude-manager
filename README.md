# Claude Manager

A native macOS app for running **multiple Claude Desktop accounts** side by side —
via thin launcher apps, not full copies of Claude.app.

Each profile is a ~1 MB launcher `.app` with its own badge icon and name. The
launcher starts the *real* `/Applications/Claude.app` with a dedicated
`--user-data-dir`, so every profile has an isolated login, settings, and
extensions, while the real app keeps its Apple-notarized signature and
entitlements — notifications, virtualization features, Keychain access, and
auto-updates all keep working.

> Built on the mechanic proven by the
> [`cc-desktop-multiprofile`](https://github.com/hacker-cb) CLI prototype, wrapped
> in a native SwiftUI GUI.

## Features (MVP)

- **Add / list / open / stop / remove** launcher profiles.
- Per-profile **badge label**, **color** (palette or custom hex), **display name**,
  and **bundle id**.
- **Doctor** — health checks for the real app, each launcher, orphaned profile
  dirs, and duplicate running instances.
- **Regenerate icons** — rebuild badges after a Claude update.
- **Menu bar extra** for quick open/stop, plus a full management window.

## Why thin launchers?

Copying Claude.app and re-signing it ad-hoc strips Anthropic's entitlements, which
observably breaks notifications and virtualization-based features (Cowork
sandboxes report the installation as "corrupted"). A thin launcher execs the
untouched, signed binary, so nothing breaks and there is nothing to rebuild after
Claude self-updates. See [CLAUDE.md](CLAUDE.md) for the hard-won macOS details.

## Requirements

- macOS 14 (Sonoma) or later, Apple Silicon.
- `/Applications/Claude.app` (the real, untouched app).

## Build & develop

The core logic lives in a Swift package (`ClaudeManagerCore`) that builds and
tests headlessly; the SwiftUI app is an Xcode target generated from
[`project.yml`](project.yml) by [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
make setup        # git hooks + brew bundle (xcodegen, swiftformat, swiftlint)
make test         # swift test — headless core suite
make gen          # regenerate ClaudeManager.xcodeproj from project.yml
make build-app    # compile the app (unsigned) to verify it builds
make lint format  # swiftformat + swiftlint
open ClaudeManager.xcodeproj   # develop in Xcode
```

`ClaudeManager.xcodeproj` is generated and git-ignored — run `make gen` (or open
via `xcodegen generate`) after cloning.

## Testing

`swift test` runs the full core suite headlessly (no window server) — process
parsing, launcher bundle building, marker round-trips, badge/icns rendering
through the real `iconutil`, and the `ProfileStore`/`Doctor` orchestration against
temp directories with a mocked command runner. An opt-in live test exercises the
real app end-to-end:

```bash
CLAUDE_MANAGER_LIVE=1 swift test --filter LiveIntegrationTests
```

## Architecture

```
ClaudeManagerCore (Swift package — headless, fully tested)
├─ Models      Profile, BadgeColor, LauncherMarker, ManagedProfile, Diagnostic
├─ RealClaude  locate the real app (LaunchServices + fallbacks), version, icon
├─ Launcher    bundle build/scan/remove; bash launcher script (duplicate guard)
├─ Icons       CoreGraphics badge renderer → iconutil .icns packer
├─ Process     pgrep/ps main-process detection (ppid==1 filter)
├─ ProfileStore  the façade: add/remove/open/stop/update/regenerate/doctor
└─ CommandRunner injected process runner (mocked in tests)

ClaudeManagerApp (SwiftUI — thin)
└─ Window (list + detail + editor + doctor) · MenuBarExtra · Settings
```

The launcher's Info.plist **marker** is the source of truth: launchers are
discovered by scanning the install directory, with a small JSON store in
Application Support for GUI-only metadata.

## Signing & release

Claude Manager is **not** sandboxed (it must write launcher bundles next to
Claude.app, run `lsregister`, and refresh the Dock), so it ships via **Developer
ID + notarization**, never the App Store. CI builds a signed, notarized, stapled
DMG on every `v*` tag — see [docs/RELEASING.md](docs/RELEASING.md) for the exact
secrets to configure.

## License

[MIT](LICENSE) © 2026 Pavel Sokolov

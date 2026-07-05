# Developing Claude Manager

The core logic lives in a Swift package (`ClaudeManagerCore`) that builds and tests
headlessly — no Xcode, no window server. The SwiftUI app is a thin shell, built as
an Xcode target generated from [`project.yml`](../project.yml) by
[XcodeGen](https://github.com/yonaskolb/XcodeGen).

See [ARCHITECTURE.md](ARCHITECTURE.md) for how the pieces fit together and
[RELEASING.md](RELEASING.md) for signing and shipping.

## Prerequisites

- macOS 14+ with Xcode (Swift 6 toolchain).
- Developer tools installed by `make setup` via [Homebrew](https://brew.sh):
  `xcodegen`, `swiftformat`, `swiftlint` (see [`Brewfile`](../Brewfile)).

```bash
make setup   # installs git hooks (core.hooksPath=.githooks) + runs `brew bundle`
```

## Everyday commands

`ClaudeManager.xcodeproj` is generated and git-ignored — run `make gen` (or
`xcodegen generate`) after cloning, or just use the `make` targets below, which
regenerate it as needed.

| Command | What it does |
|---|---|
| `make setup` | Install git hooks and dev tooling (`brew bundle`). |
| `make test` | Run the headless core test suite (`swift test`). |
| `make gen` | Regenerate `ClaudeManager.xcodeproj` from `project.yml`. |
| `make build-app` | Build the app **unsigned** into `build/` to verify it compiles. |
| `make run` | Build (unsigned) and launch the app. |
| `make xcode` | Generate and open the project in Xcode. |
| `make lint` | `swiftformat --lint .` and `swiftlint --strict`. |
| `make format` | Auto-format the tree with SwiftFormat. |
| `make archive` | Export a Developer ID `.app` into `dist/` (needs signing env — see [RELEASING.md](RELEASING.md)). |
| `make dmg` | Package `dist/Claude Manager.app` into a DMG. |
| `make clean` | Remove the generated project and build artifacts. |

Run `make` with no target (or `make help`) to list them.

## Testing

`swift test` runs the full core suite headlessly (no window server) — process
parsing, launcher bundle building, marker round-trips, badge/`.icns` rendering
through the real `iconutil`, and the `ProfileStore` / `Doctor` orchestration against
temp directories with a mocked command runner.

An **opt-in live test** runs against the real Claude.app on disk — LaunchServices
lookup, version read, and the icon/badge pipeline — installing into a temp directory
and never launching Claude:

```bash
CLAUDE_MANAGER_LIVE=1 swift test --filter LiveIntegrationTests
```

> **Never touch the user's real profiles or default Claude when testing.** All other
> tests use temp install dirs, a fake "real app", and a mocked `CommandRunner`.

## Quality gate

`swift test`, `swiftformat --lint .`, and `swiftlint --strict` must all pass. The
pre-commit / pre-push hooks (installed by `make setup`) and CI enforce it. Keep
logic in the core with a test; keep views thin and declarative.

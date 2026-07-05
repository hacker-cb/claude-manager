# Contributing

Thanks for considering a contribution! This page is the short human contract; the
mechanics live in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Getting set up

```bash
make setup   # git hooks + dev tooling (xcodegen, swiftformat, swiftlint)
make test    # headless core suite
```

Keep logic in `ClaudeManagerCore` with a test; keep SwiftUI views thin. Before you
push, `swift test`, `swiftformat --lint .`, and `swiftlint --strict` must all pass —
the git hooks and CI enforce it. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for
how the code is organized.

## Branches

Name a branch `<type>/[<issue>-]<slug>`, where `<type>` is a
[Conventional Commits](https://www.conventionalcommits.org) type (`feat`, `fix`,
`refactor`, `docs`, `chore`, …) and `<issue>` is the GitHub issue number when one
exists — e.g. `feat/42-custom-hex-badges`, `docs/readme-overhaul`.

## Pull requests

- **Base your PR on `dev`**, not `master`.
- Give it a **Conventional-Commit-shaped title** — `<type>(<scope>): summary` — it
  becomes the squash-commit message on `dev`.
- Link the issue it closes with `Closes #N` in the body.
- Keep it focused and green: CI must pass and review comments resolved before merge.
- Standalone PRs **squash-merge** into `dev`; `dev` integrates into `master` by merge
  commit at release time.

Large features spread across several PRs use a long-lived `umbrella/<issue>-<slug>`
branch as the single integration point — see
[`.claude/rules/git-branches.md`](.claude/rules/git-branches.md) for the full policy.

## Reporting bugs &amp; ideas

Open a [GitHub issue](https://github.com/hacker-cb/claude-manager/issues). For
security-sensitive reports, follow [SECURITY.md](SECURITY.md) instead.

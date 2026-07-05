# Security policy

## Reporting a vulnerability

Please report security issues **privately** — do not open a public issue for a
vulnerability.

- Preferred: GitHub **[Report a vulnerability](https://github.com/hacker-cb/claude-manager/security/advisories/new)**
  (Security → Advisories) on this repository.
- Or email the maintainer at **pavel@sokolov.me**.

Include the version, macOS version, and steps to reproduce. You'll get an
acknowledgement, and a fix or mitigation will ship in a new release once confirmed.

## Supported versions

This project is pre-1.0 and moves fast: **only the latest release** receives security
fixes. Because the app auto-updates (below), staying current is the intended path.

## Trust model &amp; hardening

- **Signed &amp; notarized.** Releases ship **Developer ID–signed, notarized, and
  stapled**; the app runs under the **Hardened Runtime** with minimal entitlements
  (no sandbox — it must write launcher bundles and refresh the Dock — plus apple-events
  for window activation). See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
- **Auto-update integrity.** Updates are delivered via [Sparkle](https://sparkle-project.org):
  the appcast is served over HTTPS from GitHub Pages, and **every update is
  EdDSA-signed**. Sparkle verifies each download against the public key
  (`SUPublicEDKey`) baked into the installed app before applying it, so a tampered or
  unsigned update is rejected. The signing private key is held only as a CI secret and
  is **un-rotatable once shipped** — see [docs/RELEASING.md](docs/RELEASING.md) §
  Auto-update.
- **Your credentials stay local.** Claude Manager never reads account credentials or
  session tokens; each profile's login lives inside its own `--user-data-dir`, managed
  by the real Claude app. Nothing is transmitted to any third party.

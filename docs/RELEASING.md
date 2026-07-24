# Releasing Claude Manager

Releases are cut by CI on a `v*` tag: build → Developer ID sign → notarize + staple
the app → DMG → notarize + staple the DMG → sign a Sparkle `.zip` → GitHub Release
(DMG + `.zip`) → publish the appcast to `gh-pages`. This doc lists exactly
what to configure once, and how to cut a release.

## Versioning

**The git tag is the single source of truth for the version.** There is nothing to
bump in the repo — the `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` in `project.yml`
are `0.0.0`/`1` dev placeholders for local (non-release) builds only.

- **Marketing version** (`CFBundleShortVersionString`) comes from the tag: `v1.2.3` →
  `1.2.3`. CI injects it into the build (`scripts/build-app.sh`) and asserts the
  exported bundle actually carries it, so a release can never ship mislabelled.
- **Build number** (`CFBundleVersion`) is the workflow run number — monotonic and
  zero-maintenance, so two builds of the same marketing version stay distinguishable.
- Tags are validated **strict semver `X.Y.Z`** (three numeric components — a valid
  `CFBundleShortVersionString`, ready for Sparkle/Homebrew version comparison). A
  malformed tag (`v0.1`, `v1.2.3.4`, `v1.2-beta`) fails the release fast.

## One-time: GitHub Actions secrets

Configure these repository secrets (`gh secret set <NAME>` or **Settings →
Secrets and variables → Actions**). All are required for `release.yml`.

| Secret | What it is | How to get it |
|---|---|---|
| `DEVELOPMENT_TEAM` | 10-char Apple Team ID | Apple Developer → Membership |
| `SIGNING_IDENTITY` | Full identity name, e.g. `Developer ID Application: Pavel Sokolov (TEAMID)` | `security find-identity -v -p codesigning` |
| `DEVELOPER_ID_CERT_P12_BASE64` | Your **Developer ID Application** cert + private key, exported as `.p12`, base64-encoded | Keychain → export the cert → `base64 -i cert.p12 \| pbcopy` |
| `DEVELOPER_ID_CERT_PASSWORD` | Password you set on the `.p12` export | — |
| `AC_API_KEY_ID` | App Store Connect API **Key ID** | App Store Connect → Users and Access → Integrations → App Store Connect API |
| `AC_API_ISSUER_ID` | App Store Connect **Issuer ID** | Same page |
| `AC_API_KEY_P8_BASE64` | The `.p8` API private key, base64-encoded | Download once on key creation, then `base64 -i AuthKey_XXXX.p8 \| pbcopy` |
| `SPARKLE_ED_PRIVATE_KEY` | The Sparkle EdDSA **private** key (auto-update signing) | `./bin/generate_keys -x sparkle_private_key` then `gh secret set SPARKLE_ED_PRIVATE_KEY < sparkle_private_key` — see § Auto-update |

### Preparing the certificate `.p12`

1. In **Apple Developer → Certificates**, create a **Developer ID Application**
   certificate if you don't have one (needs a CSR from Keychain Access).
2. In **Keychain Access**, find `Developer ID Application: …`, expand it, select
   both the certificate **and** its private key, right-click → **Export 2 items…**
   → `.p12`, set a password.
3. `base64 -i DeveloperID.p12 | pbcopy` → paste into `DEVELOPER_ID_CERT_P12_BASE64`.

### Preparing the App Store Connect API key

1. **App Store Connect → Users and Access → Integrations → App Store Connect API**
   → generate a key with the **Developer** role (sufficient for notarization).
2. Note the **Key ID** and **Issuer ID**; download the `.p8` (one-time).
3. `base64 -i AuthKey_XXXX.p8 | pbcopy` → paste into `AC_API_KEY_P8_BASE64`.

## Auto-update (Sparkle)

The app self-updates with [Sparkle 2](https://sparkle-project.org). The release job
signs a `.zip` of the notarized app with an EdDSA key and appends an entry to a
cumulative `appcast.xml` served from the `gh-pages` branch at a **fixed** URL
(`https://hacker-cb.github.io/claude-manager/appcast.xml`, baked into every build as
`SUFeedURL`). The DMG stays the human download; Sparkle installs from the `.zip`.

**One-time setup (before the first Sparkle-enabled release):**

1. **Generate the EdDSA keypair** with Sparkle's `bin/generate_keys` (from the
   `Sparkle-X.Y.Z.tar.xz` release or the resolved SPM checkout's `artifacts/…/bin`):

   ```bash
   ./bin/generate_keys          # prints the base64 PUBLIC key; PRIVATE key → login Keychain
   ./bin/generate_keys -x sparkle_private_key   # export a copy for CI
   ```

2. **Paste the public key** into `project.yml` → `SUPublicEDKey` (replacing the
   `REPLACE_WITH_SUPUBLICEDKEY` placeholder). `scripts/build-app.sh` fails the build
   while the placeholder is present, so a signed build can never ship unable to update.
3. **Store the private key** as the `SPARKLE_ED_PRIVATE_KEY` secret
   (`gh secret set SPARKLE_ED_PRIVATE_KEY < sparkle_private_key`), then **back it up
   offline** (password manager) and delete the file. The key is **un-rotatable** once
   `SUPublicEDKey` ships — losing it breaks auto-update for every installed user (only a
   manual reinstall recovers). There is no recovery path other than that.
4. **Create the `gh-pages` branch and enable Pages** (Settings → Pages → source =
   `gh-pages` / root). The feed 404s until this exists and serves at least one appcast.

   ```bash
   git switch --orphan gh-pages && git rm -rf . && git commit --allow-empty -m "init pages"
   git push origin gh-pages && git switch -
   ```

**Version mapping (nothing to bump manually):** `sparkle:shortVersionString` reuses the
injected `MARKETING_VERSION` (the tag) and `sparkle:version` reuses `CFBundleVersion`
(the run number). The appcast step **refuses to publish** either a build number that
isn't greater than the latest published one (a no-op) **or** a marketing version older
than the latest published one (a downgrade Sparkle would otherwise offer as an update) —
so a re-dispatch of an old tag is rejected rather than shipped.

**Before the first real release**, rehearse the full loop with two throwaway tags
(`vN` → `vN+1`): install `vN`, publish its appcast, then tag `vN+1` and confirm the
installed app downloads, verifies, and relaunches into `vN+1`. This is where any
nested-Sparkle signing or enclosure-format issue surfaces.

## Launch at login

The **Launch at login** toggle (Settings → Startup) registers the app itself as a login
item via `SMAppService.mainApp` — no helper bundle, since the app is non-sandboxed. It
needs no extra entitlement, but macOS only honours the registration for a **Developer ID
signed + notarized** build, which is exactly what the release pipeline produces. The gate
is **not** the signature — a local `make archive` is Developer ID signed too, yet still must
not add a login item under the dev identity — so the toggle keys on
`AppBuild.isDistribution` (the `MARKETING_VERSION` placeholder the release injects, not any
signing fact) and is **disabled in non-distribution builds** with a caption explaining why,
so a released build shows a working toggle and any local build — ad-hoc `make run` or
Developer ID `make archive` alike — never lands in the user's Login Items. See [DEVELOPMENT.md](DEVELOPMENT.md) § Dev builds carry a
separate identity for the broader identity split.

## Cutting a release

```bash
git switch master && git pull
git tag v0.1.0
git push origin v0.1.0
```

CI produces a signed, notarized, stapled `ClaudeManager-0.1.0.dmg` and attaches it
to a new GitHub Release. Or trigger **Actions → Release → Run workflow** and pass a
version manually.

## Local dry run

With the same env vars exported locally (and a valid signing identity in your
login keychain) you can reproduce the pipeline:

```bash
VERSION=0.1.0 BUILD_NUMBER=1 \
  DEVELOPMENT_TEAM=TEAMID SIGNING_IDENTITY="Developer ID Application: … (TEAMID)" \
  bash scripts/build-app.sh
AC_API_KEY_ID=… AC_API_ISSUER_ID=… AC_API_KEY_PATH=AuthKey.p8 \
  bash scripts/notarize.sh "dist/export/Claude Manager.app"
VERSION=0.1.0 SIGNING_IDENTITY="…" bash scripts/make-dmg.sh
AC_API_KEY_ID=… AC_API_ISSUER_ID=… AC_API_KEY_PATH=AuthKey.p8 \
  bash scripts/notarize.sh dist/ClaudeManager-0.1.0.dmg
```

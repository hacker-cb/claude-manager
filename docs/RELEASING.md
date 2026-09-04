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

## Merging dev → master

The release PR can arrive `BEHIND` on an **empty diff**. Every previous release left a merge
commit on `master` that `dev` never took back, and `strict_required_status_checks_policy` is
on — so GitHub requires the branch to be up to date even when the two carry identical
content.

**Read "can" as "always", and do not measure it early.** The merge commit is not an accident
some releases leave behind: it is what merging the release PR *as a merge commit* produces, on
`master`, every time. So this sync is the first step of every release rather than a conditional
one — and a check of whether it is needed answers correctly only **after the previous release
PR has merged**. Taken any earlier — right after the previous sync landed, say — it reports the
two branches level and stays wrong from the moment the release merges. v0.15.0 nearly shipped on
exactly such a stale reading.

Two things make that awkward to fix, and both are worth knowing before you hit them:

- **`dev` cannot be pushed to directly** (repository rules require status checks on any
  write), and `update-branch` on the PR fails for the same reason. The sync has to go through
  its own PR.
- **That sync PR has an empty diff**, so `copilot-review-gate` never gets a review out of
  Copilot — it answers "wasn't able to review any files" and the gate fails after its 15-minute
  wait. Give the PR something real to review (this section was written for exactly that
  reason), or merge it with admin rights.

Merge the sync PR as a **merge commit**, not a squash: squashing flattens away the very
commits `dev` needs in its history for the release PR to stop reading as behind.

The whole dance, as commands. Run from a clean checkout with `origin` fetched, with
the release version in the branch name (`0.12.0` below stands for it):

```bash
git switch -c chore/sync-master-into-dev-0.12.0 origin/master && git merge --no-edit origin/dev
git diff --stat origin/dev   # expect empty: the trees must already match
git push origin -u chore/sync-master-into-dev-0.12.0
```

**Suffix the branch with the version** (as the v0.11.0 sync already did in practice —
#147, `chore/sync-master-into-dev-0.11.0`) rather than reusing a bare
`chore/sync-master-into-dev`. The merge deletes the remote
ref but not the local branch, so the bare name survives in whichever checkout cut the
previous release — v0.12.0 found exactly such a leftover, still pointing at the
v0.11.0-era sync — and a later `git switch` to the bare name lands on that stale merge
instead of a fresh one. A per-release name can't collide with its predecessors, and
names the release it belonged to in history.

Then open the PR against `dev`, give it something real to review (see below), merge it as
a **merge commit**, and only then open the release PR.

Two more things learned cutting v0.10.1:

- **Branch the sync off `master` and merge `dev` into it**, rather than pushing `master` as-is.
  The release's own feature PR has already landed on `dev` by this point, so a branch that is
  just `master` is itself `BEHIND` its base and the same strict-checks rule blocks it — you'd
  be one PR deeper in the same hole. Merging `dev` in leaves the tree identical to `dev` and
  the branch up to date.
- **The empty-diff gate is not a one-off.** It has now blocked every release sync, each
  time after burning its full 15-minute wait. Adding a real change to the sync PR is the
  reliable way through, and this section is where those changes have gone: each release has
  paid for the paragraph documenting the trap it hit. If that stops being funny, the fix is
  to teach `copilot-review-gate` to pass a diff with no reviewable files rather than to keep
  feeding it prose.
- **A feature branch cut from `master` cannot go to `dev` untouched** (v0.13.0). A worktree
  session starts on the default branch, so a branch cut there sits on the previous release's
  merge commit; `master` and `dev` carry identical trees, so the PR's *diff* is clean while its
  commit list opens with `Merge pull request #NNN from hacker-cb/dev`, which then rides into the
  squash body. Move the branch onto `dev` before the first commit — `git reset --soft origin/dev`
  where nothing is committed yet, a rebase afterwards.
- **Admin merge may not be available to you.** It is the documented escape from the empty-diff
  gate, but an agent session can have it withheld (it is, after all, a branch-protection
  bypass). Giving the PR something real to review is the path that needs no special rights —
  and a sync PR cut this way has a natural candidate: whatever you just learned about this
  procedure, which is how both of these bullets got here.

### The release PR itself

The section above names "the release PR" three times without ever saying what it is — and
what it is turns out to be the thing that *creates* the divergence the whole first half is
about. So, stated once:

- **Head is `dev` itself**, not a topic branch cut from it. `#157` and every release before
  it were opened straight from `dev`.
- **Base is `master`.**
- **Merge it as a merge commit**, never a squash. That commit — `585df96 Merge pull request
  #157 from hacker-cb/dev` — is precisely the one `master` then carries and `dev` never takes
  back, which is why the *next* release opens with the sync dance above. Squashing would not
  avoid that; it would flatten `dev`'s history onto `master` and leave the two genuinely
  divergent rather than merely out of order.
- **Title:** `Release: dev → master (vX.Y.Z — <one-line headline>)`.

Only after that merge lands does the tag get pushed.

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

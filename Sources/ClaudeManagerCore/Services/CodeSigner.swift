import Foundation

/// Seals a launcher bundle with an **ad-hoc** code signature.
///
/// Why launchers are signed at all: a locally created `.app` is not quarantined (it
/// carries `com.apple.provenance`, not `com.apple.quarantine`), so Gatekeeper never
/// prompts — but AppleSystemPolicy still refuses to *execute* a binary with no valid
/// signature, killing a freshly built launcher seconds after it checks in with
/// LaunchServices. An ad-hoc signature is exactly what clears that: content hashes with
/// no identity, so it needs no certificate, no Apple Developer account, and no network,
/// and behaves the same on a contributor's machine and on CI.
///
/// It buys integrity, not authenticity — no Team ID, and it is emphatically not
/// notarization. That also means `spctl -a -t exec` still reports `rejected` for these
/// bundles: it assesses notarization, not execution policy, so it is not a useful
/// success signal here. `codesign --verify` (or `SecStaticCodeCheckValidity`) plus an
/// actual launch is.
///
/// Signing shells out through the injected `CommandRunner` instead of calling
/// `Security.framework`'s in-process signer, which wedges under a saturated thread pool
/// — see [DECISIONS.md](../../../docs/DECISIONS.md) § Signing launchers.
public struct CodeSigner: Sendable {
    let runner: CommandRunner

    public init(runner: CommandRunner) {
        self.runner = runner
    }

    /// Ad-hoc sign the bundle at `bundleURL` in place, replacing any existing signature.
    public func signAdHoc(bundleURL: URL) throws {
        do {
            try runner.runChecked(CoreConstants.codesignPath, ["--force", "--sign", "-", bundleURL.path])
        } catch let ClaudeManagerError.commandFailed(_, exitCode, message) {
            throw ClaudeManagerError.codeSigningFailed(
                path: bundleURL.path, exitCode: exitCode, message: message
            )
        } catch let ClaudeManagerError.commandLaunchFailed(_, message) {
            // `/usr/bin/codesign` missing or unrunnable — same user-facing consequence
            // as a signing failure, so it surfaces as one rather than as a raw exec error.
            throw ClaudeManagerError.codeSigningFailed(path: bundleURL.path, exitCode: -1, message: message)
        }
    }
}

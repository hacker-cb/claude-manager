import Foundation

/// Renders the thin launcher's `Contents/MacOS/launcher` bash script.
///
/// The script execs the real, signed Claude binary with an isolated
/// `--user-data-dir`, so the process keeps Anthropic's signature, entitlements,
/// notifications, and auto-updates. Before launching it guards against a
/// duplicate instance on the same profile: Electron has no single-instance lock,
/// so a second `open` would corrupt the profile's LevelDB — instead we bring the
/// existing window to the front via System Events (one-time TCC Automation prompt).
public enum LauncherScript {
    public static func render(profilePath: String, realBinaryPath: String) -> String {
        // The pgrep pattern must match the command line ps reports for the running
        // instance: `<real-bin> --user-data-dir=<profile>`. Both parts are
        // regex-escaped so paths with dots/spaces match literally, and the trailing
        // `( |$)` anchors the profile so `/p` doesn't match `/ps`.
        let pattern = "^"
            + PathUtils.regexEscaped(realBinaryPath)
            + " --user-data-dir="
            + PathUtils.regexEscaped(profilePath)
            + "( |$)"

        let quotedProfile = PathUtils.shellSingleQuoted(profilePath)
        let quotedReal = PathUtils.shellSingleQuoted(realBinaryPath)
        let quotedPattern = PathUtils.shellSingleQuoted(pattern)

        return """
        #!/bin/bash
        # Thin launcher for a Claude Desktop profile (managed by Claude Manager).
        # Runs the real, Apple-signed Claude binary with an isolated user-data-dir.
        PROFILE=\(quotedProfile)
        REAL=\(quotedReal)
        PATTERN=\(quotedPattern)
        # If this profile already runs, bring its window to front instead of
        # spawning a duplicate instance on the same user-data-dir.
        MAIN=$(pgrep -f "$PATTERN" | head -1)
        if [ -n "$MAIN" ]; then
          osascript -e "tell application \\"System Events\\" to set frontmost of (first process whose unix id is $MAIN) to true" >/dev/null 2>&1
          exit 0
        fi
        exec "$REAL" --user-data-dir="$PROFILE" "$@"

        """
    }
}

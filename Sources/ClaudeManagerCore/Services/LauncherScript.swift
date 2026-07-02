import Foundation

/// Renders the thin launcher's `Contents/MacOS/launcher` bash script.
///
/// The script execs the real, signed Claude binary with an isolated
/// `--user-data-dir`, so the process keeps Anthropic's signature, entitlements,
/// notifications, and auto-updates. Before launching it guards against a
/// duplicate instance on the same profile: Electron has no single-instance lock,
/// so a second `open` would corrupt the profile's LevelDB — instead we bring the
/// existing window to the front via System Events (one-time TCC Automation prompt).
///
/// The guard is a check-then-exec, so a naïve `pgrep` test has a TOCTOU window:
/// two rapid launches (a double-click, or `open -n` mid-launch) both see nothing
/// running — the instance only appears at `exec` — and both start. We close that
/// window with `shlock`, an atomic, PID-aware lock file shipped with macOS: only
/// one launch acquires the lock. Because `exec` preserves the PID recorded in the
/// lock, it names the live Claude process until it exits, at which point `shlock`
/// reclaims the stale lock for the next launch. `shlock` is a base-system tool on
/// every supported macOS, but we keep the old best-effort `pgrep` guard as a
/// fallback in case it is ever absent.
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
        LOCK="$PROFILE/.claude-manager.lock"

        # Bring the already-running instance's window to the front (System Events
        # needs a one-time TCC Automation grant).
        activate_existing() {
          local main
          main=$(pgrep -f "$PATTERN" | head -1)
          [ -n "$main" ] || return
          osascript -e "tell application \\"System Events\\" to set frontmost of (first process whose unix id is $main) to true" >/dev/null 2>&1
        }

        # Ensure the lock's parent exists (Electron uses this dir as user-data-dir
        # anyway); creating it early is harmless and idempotent.
        mkdir -p "$PROFILE" 2>/dev/null

        # Atomically claim the profile so two rapid launches can't both start an
        # instance on the same user-data-dir (which corrupts LevelDB). shlock ties
        # the lock to a live PID: we record our own, and `exec` below keeps it, so
        # the lock names the running Claude process until it exits.
        if [ -x /usr/bin/shlock ]; then
          if /usr/bin/shlock -f "$LOCK" -p $$; then
            exec "$REAL" --user-data-dir="$PROFILE" "$@"
          fi
          activate_existing
          exit 0
        fi

        # Fallback when shlock is unavailable: a best-effort pgrep guard with a
        # small TOCTOU window (the behaviour of the original launcher).
        if [ -n "$(pgrep -f "$PATTERN" | head -1)" ]; then
          activate_existing
          exit 0
        fi
        exec "$REAL" --user-data-dir="$PROFILE" "$@"

        """
    }
}

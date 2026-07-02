import Testing
@testable import ClaudeManagerCore

struct LauncherScriptTests {
    let realBinary = "/Applications/Claude.app/Contents/MacOS/Claude"

    @Test
    func rendersExecLineWithProfile() {
        let script = LauncherScript.render(profilePath: "/data/work", realBinaryPath: realBinary)
        #expect(script.hasPrefix("#!/bin/bash"))
        #expect(script.contains(#"exec "$REAL" --user-data-dir="$PROFILE" "$@""#))
        #expect(script.contains("PROFILE='/data/work'"))
        #expect(script.contains("REAL='\(realBinary)'"))
    }

    @Test
    func embedsRegexEscapedDuplicateGuardPattern() {
        let script = LauncherScript.render(profilePath: "/data/p", realBinaryPath: realBinary)
        // The dot in `.app` is escaped and the profile is anchored with ( |$) so
        // `/p` never matches `/ps`.
        #expect(script
            .contains(
                #"PATTERN='^/Applications/Claude\.app/Contents/MacOS/Claude --user-data-dir=/data/p( |$)'"#
            ))
        #expect(script.contains(#"pgrep -f "$PATTERN""#))
        #expect(script.contains("osascript"))
    }

    @Test
    func singleQuotesPathsWithSpaces() {
        let script = LauncherScript.render(
            profilePath: "/data/with space",
            realBinaryPath: "/Applications/Claude Beta.app/Contents/MacOS/Claude"
        )
        #expect(script.contains("PROFILE='/data/with space'"))
        #expect(script.contains("REAL='/Applications/Claude Beta.app/Contents/MacOS/Claude'"))
    }
}

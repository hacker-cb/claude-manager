import Foundation

/// A running Claude main process (any bundle).
public struct ClaudeInstance: Equatable, Sendable {
    public let pid: Int32
    public let executablePath: String
    /// `--user-data-dir` value, or `nil` for the default profile.
    public let profilePath: String?
    /// Marketing version the live process is actually running, resolved from an
    /// Electron child's `--desktop-telemetry-config` `appVersion`. A thin launcher
    /// execs the real binary, so a running instance keeps the version it launched
    /// with until relaunched — even after Claude.app updates on disk. `nil` means no
    /// child has reported a version (freshly launched, or the flag shape changed);
    /// callers treat that as "unknown", never as "up to date".
    public let runningVersion: String?

    public init(pid: Int32, executablePath: String, profilePath: String?, runningVersion: String? = nil) {
        self.pid = pid
        self.executablePath = executablePath
        self.profilePath = profilePath
        self.runningVersion = runningVersion
    }

    /// True when this instance runs the real Claude binary at `realClaude`'s path —
    /// exactly the set ShipIt's swap gates on (the default profile and every clone
    /// `exec` that one binary). Excludes Claude Manager's own "Claude Manager" main,
    /// which `ProcessProbe` also matches (its path contains "Claude" too) and which
    /// must never count as a swap blocker. The single definition of "real-Claude
    /// instance"; change the match (bundle id, a second binary path, symlink
    /// resolution) here and every gate stays in lockstep.
    public func isRealClaudeBinary(_ realClaude: RealClaude) -> Bool {
        executablePath == realClaude.binaryURL.path
    }
}

/// Detects running Claude instances. All process listing goes through the injected
/// `CommandRunner`, and the `ps` parsing is a pure static function, so behaviour is
/// unit-testable without spawning anything.
public struct ProcessProbe {
    let runner: CommandRunner

    public init(runner: CommandRunner) {
        self.runner = runner
    }

    /// PID of the running instance for a specific profile+binary, or `nil`.
    public func mainPID(forProfilePath profile: String, realBinaryPath: String) -> Int32? {
        let pattern = "^"
            + PathUtils.regexEscaped(realBinaryPath)
            + " --user-data-dir="
            + PathUtils.regexEscaped(profile)
            + "( |$)"
        guard let output = try? runner.run(CoreConstants.pgrepPath, ["-f", pattern]) else {
            return nil
        }
        // pgrep exits 1 with no match; only trust a zero exit.
        guard output.succeeded else { return nil }
        return output.trimmedOutput
            .split(whereSeparator: \.isWhitespace)
            .first
            .flatMap { Int32($0) }
    }

    /// All running Claude main processes across every bundle.
    public func allClaudeMains() -> [ClaudeInstance] {
        // `axww` (doubled `w`) disables argv truncation: the child's app version
        // lives deep in a very long Electron argv, past where the default width cuts.
        // Ignore the output unless `ps` exits 0 — don't parse a failed command's
        // possibly-partial output; return no instances instead.
        guard let output = try? runner.run(CoreConstants.psPath, ["axww", "-o", "pid=,ppid=,command="]),
              output.succeeded
        else { return [] }
        return Self.parseMains(psOutput: output.standardOutput)
    }

    /// Profile dir → the version its live instance is running, from an already-fetched sweep.
    /// Only mains that reported a version and carry a `--user-data-dir` are included. If
    /// duplicate instances share one profile, keeps the OLDEST version, so a lagging instance
    /// still surfaces "restart to update" instead of being masked by a newer sibling (a
    /// duplicate is itself flagged separately by `Doctor`).
    public func runningVersionsByProfilePath(from mains: [ClaudeInstance]) -> [String: String] {
        var versions: [String: String] = [:]
        for instance in mains {
            guard let profile = instance.profilePath, let version = instance.runningVersion else { continue }
            if let existing = versions[profile], !VersionOrder.isNewer(existing, than: version) { continue }
            versions[profile] = version
        }
        return versions
    }

    /// Parse `ps axww -o pid=,ppid=,command=` output into Claude main processes.
    ///
    /// A "main" is a GUI process spawned directly by launchd (`ppid == 1`) whose
    /// executable lives at `.../Contents/MacOS/<name>` with "Claude" in the path.
    /// The `ppid == 1` filter excludes Electron's renderer/utility/MCP children
    /// (which are forked from the main and so have its pid as parent); framework
    /// helpers are excluded explicitly.
    ///
    /// A main carries no version in its own argv — only its Electron children do (in
    /// `--desktop-telemetry-config`). So a first pass maps every pid/ppid to a reported
    /// `appVersion`, and each main is then stamped with its own or one of its direct
    /// children's version — the version that instance is really running.
    public static func parseMains(psOutput: String) -> [ClaudeInstance] {
        let lines = psOutput.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)

        var versionByPID: [Int32: String] = [:]
        var versionByParentPID: [Int32: String] = [:]
        for line in lines {
            guard let row = splitLeadingPIDs(line),
                  let version = parseAppVersion(row.command) else { continue }
            versionByPID[row.pid] = version
            if versionByParentPID[row.ppid] == nil { versionByParentPID[row.ppid] = version }
        }

        var instances: [ClaudeInstance] = []
        for line in lines {
            guard let base = parseLine(line) else { continue }
            let version = versionByPID[base.pid] ?? versionByParentPID[base.pid]
            instances.append(ClaudeInstance(
                pid: base.pid,
                executablePath: base.executablePath,
                profilePath: base.profilePath,
                runningVersion: version
            ))
        }
        return instances
    }

    /// pid   ppid   /path .../Contents/MacOS/<exe>   <rest-of-args>
    private static let lineRegex = makeRegex(#"^\s*(\d+)\s+(\d+)\s+(/.+?/Contents/MacOS/\S+)(.*)$"#)

    private static func parseLine(_ line: String) -> ClaudeInstance? {
        let range = NSRange(line.startIndex ..< line.endIndex, in: line)
        guard let lineRegex,
              let match = lineRegex.firstMatch(in: line, range: range),
              let pidRange = Range(match.range(at: 1), in: line),
              let ppidRange = Range(match.range(at: 2), in: line),
              let execRange = Range(match.range(at: 3), in: line),
              let restRange = Range(match.range(at: 4), in: line),
              let pid = Int32(line[pidRange]),
              let ppid = Int32(line[ppidRange])
        else { return nil }

        let executable = String(line[execRange])
        let rest = String(line[restRange])

        guard ppid == 1,
              executable.contains("Claude"),
              !executable.contains("/Frameworks/")
        else { return nil }

        return ClaudeInstance(
            pid: pid,
            executablePath: executable,
            profilePath: userDataDir(in: rest)
        )
    }

    /// Capture the whole --user-data-dir value, including spaces (the default
    /// profiles dir lives under "Application Support/Claude Manager/…"), stopping
    /// before the next `--flag`, a positional URL argument, or end of line. `ps`
    /// space-joins argv, so a greedy `\S+` would truncate any path containing a
    /// space. The URL stop is defensive: deep links are delivered by Apple event
    /// (not appended to argv), but should any positional `scheme://…` arg ever follow
    /// `--user-data-dir`, this keeps it out of the captured profile path.
    private static let profileRegex =
        makeRegex(#"--user-data-dir=(.+?)(?=\s--|\s[a-zA-Z][a-zA-Z0-9+.\-]*://|$)"#)

    private static func userDataDir(in arguments: String) -> String? {
        let range = NSRange(arguments.startIndex ..< arguments.endIndex, in: arguments)
        guard let profileRegex,
              let match = profileRegex.firstMatch(in: arguments, range: range),
              let valueRange = Range(match.range(at: 1), in: arguments)
        else { return nil }
        return String(arguments[valueRange])
    }

    /// One `ps` row split into its leading `pid ppid` and the rest of the command.
    private struct PSRow {
        let pid: Int32
        let ppid: Int32
        let command: String
    }

    /// Split any `ps` row regardless of the executable path — used to version-map the
    /// whole process tree (including the Electron children `parseLine` drops).
    private static let leadingPIDsRegex = makeRegex(#"^\s*(\d+)\s+(\d+)\s+(.*)$"#)

    private static func splitLeadingPIDs(_ line: String) -> PSRow? {
        let range = NSRange(line.startIndex ..< line.endIndex, in: line)
        guard let leadingPIDsRegex,
              let match = leadingPIDsRegex.firstMatch(in: line, range: range),
              let pidRange = Range(match.range(at: 1), in: line),
              let ppidRange = Range(match.range(at: 2), in: line),
              let commandRange = Range(match.range(at: 3), in: line),
              let pid = Int32(line[pidRange]),
              let ppid = Int32(line[ppidRange])
        else { return nil }
        return PSRow(pid: pid, ppid: ppid, command: String(line[commandRange]))
    }

    /// The `appVersion` from an Electron child's `--desktop-telemetry-config` JSON,
    /// e.g. `--desktop-telemetry-config={…,"appVersion":"1.18286.0"}` → `1.18286.0`.
    /// Anchored to that flag's object (`[^}]*` stays inside the one JSON object) so an
    /// unrelated `appVersion` elsewhere in the argv can't be mistaken for it.
    private static let appVersionRegex =
        makeRegex(#"desktop-telemetry-config=\{[^}]*"appVersion":"(\d+(?:\.\d+)*)""#)

    static func parseAppVersion(_ command: String) -> String? {
        let range = NSRange(command.startIndex ..< command.endIndex, in: command)
        guard let appVersionRegex,
              let match = appVersionRegex.firstMatch(in: command, range: range),
              let versionRange = Range(match.range(at: 1), in: command)
        else { return nil }
        return String(command[versionRange])
    }

    /// Compile a compile-time-constant pattern; `nil` only if the literal is
    /// malformed (a programming error caught immediately in tests).
    private static func makeRegex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern)
    }
}

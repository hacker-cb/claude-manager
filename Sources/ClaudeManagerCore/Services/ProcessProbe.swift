import Foundation

/// A running Claude main process (any bundle).
public struct ClaudeInstance: Equatable, Sendable {
    public let pid: Int32
    public let executablePath: String
    /// `--user-data-dir` value, or `nil` for the default profile.
    public let profilePath: String?

    public init(pid: Int32, executablePath: String, profilePath: String?) {
        self.pid = pid
        self.executablePath = executablePath
        self.profilePath = profilePath
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
        guard let output = try? runner.run(CoreConstants.psPath, ["ax", "-o", "pid=,ppid=,command="]) else {
            return []
        }
        return Self.parseMains(psOutput: output.standardOutput)
    }

    /// Parse `ps ax -o pid=,ppid=,command=` output into Claude main processes.
    ///
    /// A "main" is a GUI process spawned directly by launchd (`ppid == 1`) whose
    /// executable lives at `.../Contents/MacOS/<name>` with "Claude" in the path.
    /// The `ppid == 1` filter excludes Electron's renderer/utility/MCP children
    /// (which are forked from the main and so have its pid as parent); framework
    /// helpers are excluded explicitly.
    public static func parseMains(psOutput: String) -> [ClaudeInstance] {
        var instances: [ClaudeInstance] = []
        for rawLine in psOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard let parsed = parseLine(line) else { continue }
            instances.append(parsed)
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
    /// only before the next `--flag` or end of line. `ps` space-joins argv, so a
    /// greedy `\S+` would truncate any path containing a space.
    private static let profileRegex = makeRegex(#"--user-data-dir=(.+?)(?=\s--|$)"#)

    private static func userDataDir(in arguments: String) -> String? {
        let range = NSRange(arguments.startIndex ..< arguments.endIndex, in: arguments)
        guard let profileRegex,
              let match = profileRegex.firstMatch(in: arguments, range: range),
              let valueRange = Range(match.range(at: 1), in: arguments)
        else { return nil }
        return String(arguments[valueRange])
    }

    /// Compile a compile-time-constant pattern; `nil` only if the literal is
    /// malformed (a programming error caught immediately in tests).
    private static func makeRegex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern)
    }
}

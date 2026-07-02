import Foundation

/// Result of running an external command.
public struct CommandOutput: Sendable, Equatable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public init(exitCode: Int32, standardOutput: String, standardError: String) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var succeeded: Bool {
        exitCode == 0
    }

    public var trimmedOutput: String {
        standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Abstraction over running external tools (`pgrep`, `iconutil`, `lsregister`, …).
/// Injecting this is what makes every service that shells out unit-testable: tests
/// pass a mock that returns canned output instead of touching the real system.
public protocol CommandRunner: Sendable {
    @discardableResult
    func run(_ executable: String, _ arguments: [String]) throws -> CommandOutput
}

public extension CommandRunner {
    /// Run and throw `commandFailed` unless the exit code is zero.
    @discardableResult
    func runChecked(_ executable: String, _ arguments: [String]) throws -> CommandOutput {
        let output = try run(executable, arguments)
        guard output.succeeded else {
            throw ClaudeManagerError.commandFailed(
                executable: executable,
                exitCode: output.exitCode,
                message: output.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return output
    }
}

/// Real implementation backed by `Foundation.Process`.
public struct SystemCommandRunner: CommandRunner {
    public init() {}

    @discardableResult
    public func run(_ executable: String, _ arguments: [String]) throws -> CommandOutput {
        let fileManager = FileManager.default
        let outURL = fileManager.temporaryDirectory.appendingPathComponent("cmd-out-\(UUID().uuidString)")
        let errURL = fileManager.temporaryDirectory.appendingPathComponent("cmd-err-\(UUID().uuidString)")
        fileManager.createFile(atPath: outURL.path, contents: nil)
        fileManager.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? fileManager.removeItem(at: outURL)
            try? fileManager.removeItem(at: errURL)
        }

        // Redirect to files rather than pipes: no 64 KB pipe-buffer deadlock on
        // chatty commands (e.g. `ps ax`), and — crucially — no concurrent pipe
        // reads competing for libdispatch threads. Under a saturated cooperative
        // pool (e.g. the parallel test suite) that competition can starve
        // `Process`'s own termination monitoring and wedge `waitUntilExit()`.
        guard let outHandle = try? FileHandle(forWritingTo: outURL),
              let errHandle = try? FileHandle(forWritingTo: errURL)
        else {
            throw ClaudeManagerError.commandLaunchFailed(
                executable: executable,
                message: "could not open capture files"
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outHandle
        process.standardError = errHandle

        do {
            try process.run()
        } catch {
            try? outHandle.close()
            try? errHandle.close()
            throw ClaudeManagerError.commandLaunchFailed(
                executable: executable,
                message: error.localizedDescription
            )
        }
        process.waitUntilExit()
        try? outHandle.close()
        try? errHandle.close()

        let outData = (try? Data(contentsOf: outURL)) ?? Data()
        let errData = (try? Data(contentsOf: errURL)) ?? Data()
        return CommandOutput(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: outData, as: UTF8.self),
            standardError: String(decoding: errData, as: UTF8.self)
        )
    }
}

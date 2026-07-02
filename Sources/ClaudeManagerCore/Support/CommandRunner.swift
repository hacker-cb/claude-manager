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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw ClaudeManagerError.commandLaunchFailed(
                executable: executable,
                message: error.localizedDescription
            )
        }

        // Drain both pipes concurrently: reading one to EOF while the other's
        // buffer fills would otherwise deadlock on chatty commands.
        let box = OutputBox()
        let group = DispatchGroup()
        for (pipe, isStdout) in [(outPipe, true), (errPipe, false)] {
            group.enter()
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                box.set(data, isStdout: isStdout)
                group.leave()
            }
        }
        process.waitUntilExit()
        group.wait()

        return CommandOutput(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: box.stdout, as: UTF8.self),
            standardError: String(decoding: box.stderr, as: UTF8.self)
        )
    }
}

/// Thread-safe accumulator for the two pipe reads.
private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func set(_ data: Data, isStdout: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if isStdout { out = data } else { err = data }
    }

    var stdout: Data {
        lock.lock(); defer { lock.unlock() }; return out
    }

    var stderr: Data {
        lock.lock(); defer { lock.unlock() }; return err
    }
}

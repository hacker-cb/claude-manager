import CoreGraphics
import Foundation
@testable import ClaudeManagerCore

/// A `CommandRunner` that records every invocation and returns programmable
/// output. Optionally delegates specific executables (e.g. `iconutil`) to the real
/// system so icon packing works while process/Dock calls stay stubbed and safe.
final class RecordingCommandRunner: CommandRunner, @unchecked Sendable {
    struct Invocation: Equatable {
        let executable: String
        let arguments: [String]
    }

    private let lock = NSLock()
    private var _invocations: [Invocation] = []
    private var handler: @Sendable (String, [String]) -> CommandOutput

    init(handler: @escaping @Sendable (String, [String]) -> CommandOutput = { _, _ in
        CommandOutput(exitCode: 0, standardOutput: "", standardError: "")
    }) {
        self.handler = handler
    }

    var invocations: [Invocation] {
        lock.lock(); defer { lock.unlock() }
        return _invocations
    }

    func invocations(of executable: String) -> [Invocation] {
        invocations.filter { $0.executable == executable }
    }

    func setHandler(_ handler: @escaping @Sendable (String, [String]) -> CommandOutput) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
    }

    func run(_ executable: String, _ arguments: [String]) throws -> CommandOutput {
        lock.lock()
        _invocations.append(Invocation(executable: executable, arguments: arguments))
        let handler = handler
        lock.unlock()
        return handler(executable, arguments)
    }

    /// Runner that delegates `delegated` executables to the real system and routes
    /// everything else through `stub`.
    static func delegating(
        _ delegated: Set<String> = [CoreConstants.iconutilPath],
        stub: @escaping @Sendable (String, [String]) -> CommandOutput
    ) -> RecordingCommandRunner {
        let system = SystemCommandRunner()
        let runner = RecordingCommandRunner()
        runner.setHandler { executable, arguments in
            if delegated.contains(executable) {
                return (try? system.run(executable, arguments))
                    ?? CommandOutput(exitCode: 1, standardOutput: "", standardError: "delegate failed")
            }
            return stub(executable, arguments)
        }
        return runner
    }
}

/// Common stub: no process is running, other tools succeed silently.
@Sendable
func idleStub(_ executable: String, _: [String]) -> CommandOutput {
    if executable == CoreConstants.pgrepPath {
        return CommandOutput(exitCode: 1, standardOutput: "", standardError: "")
    }
    if executable == CoreConstants.psPath {
        return CommandOutput(exitCode: 0, standardOutput: "", standardError: "")
    }
    if executable == CoreConstants.duPath {
        return CommandOutput(exitCode: 0, standardOutput: "0B\t/x", standardError: "")
    }
    return CommandOutput(exitCode: 0, standardOutput: "", standardError: "")
}

/// A thread-safe call counter for stateful stubs (e.g. "running, then gone").
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}

enum Fixture {
    struct FixtureError: Error { let message: String }

    /// Remove any Trash entries whose name starts with `prefix` — keeps a test's
    /// trashed launchers from accumulating in the developer's Trash.
    static func purgeTrash(displayNamePrefix prefix: String, fileManager: FileManager = .default) {
        let trash = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        guard let entries = try? fileManager.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)
        else { return }
        let bundle = LauncherBundle(fileManager: fileManager)
        // Only ever delete our own managed launcher bundles — never an unrelated
        // user file in ~/.Trash that happens to share the prefix.
        for entry in entries {
            guard entry.lastPathComponent.hasPrefix(prefix),
                  entry.pathExtension == "app",
                  bundle.isManagedLauncher(at: entry)
            else { continue }
            try? fileManager.removeItem(at: entry)
        }
    }

    static func makeTempDir(_ fileManager: FileManager = .default) throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("cmtest-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func solidImage(size: Int, color: RGBAColor) throws -> CGImage {
        guard let ctx = BadgeRenderer.makeContext(size: size) else {
            throw FixtureError(message: "no context")
        }
        ctx.setFillColor(BadgeRenderer.cgColor(color))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        guard let image = ctx.makeImage() else { throw FixtureError(message: "no image") }
        return image
    }

    /// A small but valid `.icns` built through the real `iconutil`, usable as the
    /// badge base for a fake "real Claude" app.
    static func baseICNSData() throws -> Data {
        let base = try solidImage(size: 512, color: RGBAColor(red: 40, green: 40, blue: 40))
        let pngs = try BadgeRenderer().makeIconSet(
            base: base,
            label: "•",
            color: RGBAColor(red: 200, green: 80, blue: 60)
        )
        return try IcnsPacker(runner: SystemCommandRunner()).makeICNS(pngs: pngs)
    }

    /// Build a stand-in for the real Claude app in `dir` and return its handle.
    static func makeFakeRealApp(
        in dir: URL,
        iconData: Data,
        fileManager: FileManager = .default
    ) throws -> RealClaude {
        let app = dir.appendingPathComponent("Claude.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        let resources = app.appendingPathComponent("Contents/Resources")
        try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)
        fileManager.createFile(
            atPath: macOS.appendingPathComponent("Claude").path,
            contents: Data("#!/bin/sh\nexit 0\n".utf8)
        )
        try iconData.write(to: resources.appendingPathComponent("base.icns"))
        let info: [String: Any] = [
            "CFBundleExecutable": "Claude",
            "CFBundleIdentifier": "com.anthropic.claudefordesktop",
            "CFBundleShortVersionString": "9.9.9",
            "CFBundleIconFile": "base.icns"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        return RealClaude(appURL: app, executableName: "Claude", iconFileName: "base.icns")
    }
}

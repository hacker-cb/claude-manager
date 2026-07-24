import CoreGraphics
import Foundation
import Security
@testable import ClaudeManagerCore

/// Reads a bundle's signature through the public Security API — deliberately not by
/// inspecting the `codesign` invocation, so a test asserts the on-disk result rather
/// than echoing the call that produced it. Equivalent to what
/// `codesign --verify --strict` + `codesign -dv` report.
enum SignatureProbe {
    /// Strictly validate the bundle's signature (every sealed resource included) and
    /// confirm it is ad-hoc. False if the bundle is unsigned, tampered with, or signed
    /// with an identity.
    static func isValidAdHoc(_ bundleURL: URL) -> Bool {
        let strict = SecCSFlags(rawValue: kSecCSStrictValidate)
        guard let code = staticCode(bundleURL),
              SecStaticCodeCheckValidity(code, strict, nil) == errSecSuccess,
              let flags = signingFlags(code)
        else { return false }
        return flags & SecCodeSignatureFlags.adhoc.rawValue != 0
    }

    /// True when the path carries any signature at all (valid or not) — lets a test
    /// tell "never signed" apart from "signed, then invalidated".
    static func isSigned(_ bundleURL: URL) -> Bool {
        guard let code = staticCode(bundleURL) else { return false }
        return signingFlags(code) != nil
    }

    private static func staticCode(_ bundleURL: URL) -> SecStaticCode? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &code) == errSecSuccess else { return nil }
        return code
    }

    private static func signingFlags(_ code: SecStaticCode) -> UInt32? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let flags = dictionary[kSecCodeInfoFlags as String] as? UInt32
        else { return nil }
        return flags
    }
}

/// Rewrite a built launcher's stored wrapper version, simulating a bundle made by an
/// older Claude Manager — the only way to produce a stale/unsigned-era bundle, since a
/// fresh `build` always stamps `currentWrapperVersion`. Note this also breaks the
/// bundle's signature (it writes into a sealed bundle), which is exactly what a
/// pre-signing launcher looks like.
func setWrapperVersion(_ version: Int, atAppPath appPath: String) throws {
    let infoURL = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Info.plist")
    guard var info = RealClaude.plist(at: infoURL),
          var marker = info[CoreConstants.markerKey] as? [String: Any]
    else { throw Fixture.FixtureError(message: "no marker at \(appPath)") }
    marker["wrapperVersion"] = version
    info[CoreConstants.markerKey] = marker
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: infoURL)
}

/// A runner whose `codesign` (and every other tool) is stubbed as succeeding — for the
/// suites that build launchers to assert on something *other* than the signature.
/// Forking the real signer per bundle is left to `LauncherSigningTests`, which is
/// serialized precisely because those subprocesses are what a small CI runner chokes on.
func stubbedSigningRunner() -> RecordingCommandRunner {
    RecordingCommandRunner(handler: idleStub)
}

/// A runner on which no tool can be launched at all (the executable is missing) —
/// distinct from a tool that ran and failed, which is what `failingCodesignRunner`
/// models.
struct UnrunnableToolRunner: CommandRunner {
    func run(_ executable: String, _: [String]) throws -> CommandOutput {
        throw ClaudeManagerError.commandLaunchFailed(executable: executable, message: "no such tool")
    }
}

/// A runner whose `codesign` always fails, for driving `LauncherBundle`'s
/// signing-failure path. Every other tool succeeds silently.
func failingCodesignRunner() -> RecordingCommandRunner {
    RecordingCommandRunner { executable, arguments in
        if executable == CoreConstants.codesignPath {
            return CommandOutput(exitCode: 1, standardOutput: "", standardError: "test: signing refused")
        }
        return idleStub(executable, arguments)
    }
}

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
    /// Executables passed through to the real system, checked in `run` — deliberately
    /// *not* baked into `handler`, which `setHandler` replaces wholesale. A suite that
    /// swaps the handler mid-test would otherwise silently lose the passthrough and, for
    /// `codesign`, go back to building bundles that are never really signed.
    private var delegated: Set<String> = []

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

    /// Narrow (or clear) the real-system passthrough — for a test that needs to stub a
    /// tool `delegating` runs for real, e.g. making `codesign` fail on demand.
    func setDelegated(_ delegated: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        self.delegated = delegated
    }

    func run(_ executable: String, _ arguments: [String]) throws -> CommandOutput {
        lock.lock()
        _invocations.append(Invocation(executable: executable, arguments: arguments))
        let handler = handler
        let isDelegated = delegated.contains(executable)
        lock.unlock()
        if isDelegated {
            return (try? SystemCommandRunner().run(executable, arguments))
                ?? CommandOutput(exitCode: 1, standardOutput: "", standardError: "delegate failed")
        }
        return handler(executable, arguments)
    }

    /// Runner that delegates `delegated` executables to the real system and routes
    /// everything else through `stub`. The passthrough survives a later `setHandler`
    /// — see the `delegated` field.
    ///
    /// `codesign` is **not** in the default set: only the signing suites need a real
    /// signature, and forking `codesign` from every store test costs a subprocess per
    /// launcher write — enough to wedge a 3-core CI runner (`SystemCommandRunner`
    /// documents the starvation hazard). Ask for it explicitly via
    /// `makeStoreEnv(signingForReal: true)`.
    static func delegating(
        _ delegated: Set<String> = [CoreConstants.iconutilPath],
        stub: @escaping @Sendable (String, [String]) -> CommandOutput
    ) -> RecordingCommandRunner {
        let runner = RecordingCommandRunner(handler: stub)
        runner.lock.lock()
        runner.delegated = delegated
        runner.lock.unlock()
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

/// Captures the signals a store's `signalSender` is asked to deliver, for asserting
/// that stop() sends SIGKILL vs SIGTERM.
final class SignalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [Int32] = []
    /// Records `signal` and returns success (0), mimicking a delivered signal.
    func record(_ signal: Int32) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        captured.append(signal)
        return 0
    }

    var signals: [Int32] {
        lock.lock(); defer { lock.unlock() }
        return captured
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

/// A `ProfileStore` wired to temp directories and a fake real app, shared across the
/// ProfileStore suites. A specific name (not a generic `Env`) so it can be internal
/// without risking a collision in the test target.
struct StoreEnv {
    let root: URL
    let installDir: URL
    let profilesDir: URL
    let real: RealClaude
    let runner: RecordingCommandRunner
    let store: ProfileStore
    /// Per-test token so trashed launchers never collide across the shared `~/.Trash`
    /// (Swift Testing runs tests in parallel).
    let token: String
    /// Absent MDM plist paths the store is wired to, so overlay reconcile is hermetic
    /// (never reads the host's real managed-preferences). A probe asserting on the
    /// store's on-disk overlay must use these same paths.
    let managedPreferencesURLs: [URL]
    /// A **temp** stand-in for the default profile's user-data dir, so deep-link tests
    /// never touch the real `~/Library/Application Support/Claude`.
    let defaultProfileUserDataPath: String
    /// A **temp** stand-in for ShipIt's state file, so staged-update tests never read the
    /// host's real ShipIt cache. A test arms an update by writing this path + a bundle.
    let shipItStatePath: String

    func name(_ base: String) -> String {
        base + token
    }

    func display(_ base: String) -> String {
        Profile.defaultDisplayName(for: name(base))
    }

    func appPath(_ base: String) -> String {
        installDir.appendingPathComponent("\(display(base)).app").path
    }
}

/// `iconutil` runs for real (so icons are genuine `.icns`); every other tool is
/// stubbed, so no process is killed and the Dock is never restarted for real.
///
/// `signingForReal: true` additionally runs `codesign` for real against the temp
/// install dir — what the signature suites assert on. It is opt-in because a real
/// signature costs a subprocess per launcher write, and every store suite paying that
/// is enough to wedge a small CI runner.
func makeStoreEnv(
    signingForReal: Bool = false,
    stub: @escaping @Sendable (String, [String]) -> CommandOutput = idleStub
) throws -> StoreEnv {
    let fm = FileManager.default
    let root = try Fixture.makeTempDir()
    let installDir = root.appendingPathComponent("apps")
    let profilesDir = root.appendingPathComponent("profiles")
    try fm.createDirectory(at: installDir, withIntermediateDirectories: true)
    let real = try Fixture.makeFakeRealApp(in: root, iconData: Fixture.baseICNSData())
    let delegated: Set<String> = signingForReal
        ? [CoreConstants.iconutilPath, CoreConstants.codesignPath]
        : [CoreConstants.iconutilPath]
    let runner = RecordingCommandRunner.delegating(delegated, stub: stub)
    let managedPreferencesURLs = [root.appendingPathComponent("no-mdm.plist")]
    let defaultProfileUserDataPath = root.appendingPathComponent("default-profile/Claude").path
    let shipItStatePath = root.appendingPathComponent("ShipItState.plist").path
    let store = ProfileStore(
        realClaude: real,
        configuration: ProfileStoreConfiguration(
            installDirectory: installDir,
            defaultProfilesDirectory: profilesDir,
            managedPreferencesURLs: managedPreferencesURLs,
            defaultProfileUserDataPath: defaultProfileUserDataPath,
            shipItStatePath: shipItStatePath
        ),
        runner: runner,
        signalSender: { _, _ in 0 }
    )
    let token = String(UUID().uuidString.prefix(8)).lowercased().replacingOccurrences(of: "-", with: "")
    return StoreEnv(
        root: root, installDir: installDir, profilesDir: profilesDir,
        real: real, runner: runner, store: store, token: token,
        managedPreferencesURLs: managedPreferencesURLs,
        defaultProfileUserDataPath: defaultProfileUserDataPath,
        shipItStatePath: shipItStatePath
    )
}

// MARK: - Managed-config overlay test helpers

/// Seed a raw managed-config overlay the way an earlier build would have — arbitrary flat
/// keys, including ones the current model no longer writes (so their cleanup can be tested).
func seedRawOverlay(
    _ entries: [String: Bool],
    userDataPath: String,
    fileManager: FileManager = .default
) throws {
    let library = ManagedConfigWriter.configLibraryURL(forUserDataPath: userDataPath)
    try fileManager.createDirectory(at: library, withIntermediateDirectories: true)
    let appliedID = "00000000-0000-4000-8000-000000000000" // valid per isValidAppliedID
    try JSONSerialization.data(withJSONObject: ["appliedId": appliedID])
        .write(to: library.appendingPathComponent("_meta.json"))
    try JSONSerialization.data(withJSONObject: entries)
        .write(to: library.appendingPathComponent("\(appliedID).json"))
}

/// Read the raw flat overlay dict for a user-data dir (`nil` if none). Lets a test assert a
/// specific key's presence/absence, not just that a `ProfileManagedConfig` is satisfied.
func rawOverlay(_ userDataPath: String, fileManager: FileManager = .default) -> [String: Any]? {
    let library = ManagedConfigWriter.configLibraryURL(forUserDataPath: userDataPath)
    guard let metaData = fileManager.contents(atPath: library.appendingPathComponent("_meta.json").path),
          let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
          let appliedID = meta["appliedId"] as? String,
          let data = fileManager.contents(atPath: library.appendingPathComponent("\(appliedID).json").path),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return dict
}

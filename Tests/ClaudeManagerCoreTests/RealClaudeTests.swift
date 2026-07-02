import Foundation
import Testing
@testable import ClaudeManagerCore

struct RealClaudeTests {
    @Test
    func binaryAndIconURLsDerive() {
        let real = RealClaude(appURL: URL(fileURLWithPath: "/Applications/Claude.app"))
        #expect(real.binaryURL.path == "/Applications/Claude.app/Contents/MacOS/Claude")
        #expect(real.iconURL?.path == "/Applications/Claude.app/Contents/Resources/electron.icns")
        #expect(real.installDirectory.path == "/Applications")
    }

    @Test
    func readsVersionFromInfoPlist() throws {
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = try Fixture.makeFakeRealApp(in: dir, iconData: Data("x".utf8))
        #expect(real.version() == "9.9.9")
        #expect(real.binaryExists())
    }

    @Test
    func locatorResolvesByBundleIDFirst() throws {
        let target = URL(fileURLWithPath: "/Applications/Claude.app")
        let locator = RealClaudeLocator(
            bundleIDs: ["com.anthropic.claudefordesktop"],
            fallbackPaths: [],
            resolveBundleID: { $0 == "com.anthropic.claudefordesktop" ? target : nil },
            fileExists: { _ in true }
        )
        let real = try locator.locate()
        #expect(real.appURL == target)
    }

    @Test
    func locatorFallsBackToPathWhenBundleIDUnresolved() throws {
        let fallback = URL(fileURLWithPath: "/Applications/Claude.app")
        let locator = RealClaudeLocator(
            bundleIDs: ["com.anthropic.claudefordesktop"],
            fallbackPaths: [fallback],
            resolveBundleID: { _ in nil },
            fileExists: { $0 == fallback.appendingPathComponent("Contents/MacOS/Claude") }
        )
        #expect(try locator.locate().appURL == fallback)
    }

    @Test
    func locatorThrowsWhenNothingFound() {
        let locator = RealClaudeLocator(
            bundleIDs: ["x"],
            fallbackPaths: [URL(fileURLWithPath: "/nope")],
            resolveBundleID: { _ in nil },
            fileExists: { _ in false }
        )
        #expect(throws: ClaudeManagerError.self) { try locator.locate() }
    }

    @Test
    func locatorReadsExecutableAndIconFromBundle() throws {
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try Fixture.makeFakeRealApp(in: dir, iconData: Data("x".utf8))
        let appURL = dir.appendingPathComponent("Claude.app")
        let locator = RealClaudeLocator(
            bundleIDs: [],
            fallbackPaths: [appURL],
            resolveBundleID: { _ in nil },
            fileExists: { FileManager.default.fileExists(atPath: $0.path) }
        )
        let real = try locator.locate()
        #expect(real.executableName == "Claude")
        #expect(real.iconFileName == "base.icns")
    }
}

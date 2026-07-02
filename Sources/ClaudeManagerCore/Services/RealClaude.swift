import Foundation

/// The untouched, Apple-signed Claude Desktop app that every launcher wraps.
public struct RealClaude: Equatable, Sendable {
    public let appURL: URL
    public let executableName: String
    public let iconFileName: String?

    public init(
        appURL: URL,
        executableName: String = CoreConstants.defaultRealExecutableName,
        iconFileName: String? = CoreConstants.defaultRealIconFileName
    ) {
        self.appURL = appURL
        self.executableName = executableName
        self.iconFileName = iconFileName
    }

    public var binaryURL: URL {
        appURL.appendingPathComponent("Contents/MacOS/\(executableName)")
    }

    public var infoPlistURL: URL {
        appURL.appendingPathComponent("Contents/Info.plist")
    }

    public var resourcesURL: URL {
        appURL.appendingPathComponent("Contents/Resources")
    }

    /// The badge base icon (`Contents/Resources/<iconFileName>`), if known.
    public var iconURL: URL? {
        iconFileName.map { resourcesURL.appendingPathComponent($0) }
    }

    /// Directory the real app lives in — launchers are installed alongside it by
    /// default so they share Spotlight/Launchpad visibility.
    public var installDirectory: URL {
        appURL.deletingLastPathComponent()
    }

    public func binaryExists(fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: binaryURL.path)
    }

    /// `CFBundleShortVersionString` of the real app, if readable.
    public func version(fileManager: FileManager = .default) -> String? {
        Self.plist(at: infoPlistURL, fileManager: fileManager)?["CFBundleShortVersionString"] as? String
    }

    static func plist(at url: URL, fileManager: FileManager = .default) -> [String: Any]? {
        guard let data = fileManager.contents(atPath: url.path),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = object as? [String: Any]
        else { return nil }
        return dict
    }
}

/// Finds the real Claude app via LaunchServices (bundle id) with path fallbacks.
/// Every external dependency is injectable so `locate()` is fully unit-testable.
public struct RealClaudeLocator {
    public typealias BundleIDResolver = @Sendable (String) -> URL?
    public typealias ExistenceCheck = @Sendable (URL) -> Bool

    public var bundleIDs: [String]
    public var fallbackPaths: [URL]
    public var resolveBundleID: BundleIDResolver
    public var fileExists: ExistenceCheck

    public init(
        bundleIDs: [String] = CoreConstants.realClaudeBundleIDs,
        fallbackPaths: [URL] = [URL(fileURLWithPath: CoreConstants.defaultRealClaudePath)],
        resolveBundleID: @escaping BundleIDResolver = RealClaudeLocator.launchServicesResolver,
        fileExists: @escaping ExistenceCheck = { FileManager.default.fileExists(atPath: $0.path) }
    ) {
        self.bundleIDs = bundleIDs
        self.fallbackPaths = fallbackPaths
        self.resolveBundleID = resolveBundleID
        self.fileExists = fileExists
    }

    public func locate() throws -> RealClaude {
        for bundleID in bundleIDs {
            if let url = resolveBundleID(bundleID), let claude = make(appURL: url) {
                return claude
            }
        }
        for path in fallbackPaths {
            if let claude = make(appURL: path) {
                return claude
            }
        }
        throw ClaudeManagerError.realClaudeNotFound
    }

    /// Build a `RealClaude` from a candidate `.app`, reading its actual executable
    /// and icon names from Info.plist; returns `nil` if the binary is missing.
    func make(appURL: URL) -> RealClaude? {
        let info = RealClaude.plist(at: appURL.appendingPathComponent("Contents/Info.plist"))
        let executable = (info?["CFBundleExecutable"] as? String) ?? CoreConstants.defaultRealExecutableName
        let iconFile = normalizedIconFileName(info?["CFBundleIconFile"] as? String)
        let candidate = RealClaude(appURL: appURL, executableName: executable, iconFileName: iconFile)
        return fileExists(candidate.binaryURL) ? candidate : nil
    }

    /// `CFBundleIconFile` may or may not carry the `.icns` extension.
    private func normalizedIconFileName(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return CoreConstants.defaultRealIconFileName }
        return raw.hasSuffix(".icns") ? raw : raw + ".icns"
    }
}

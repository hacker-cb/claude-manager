#if canImport(AppKit)
    import AppKit

    public extension RealClaudeLocator {
        /// Resolve an app URL by bundle id through LaunchServices. Works headlessly
        /// (no window server needed) — tests inject a stub instead of this.
        static let launchServicesResolver: BundleIDResolver = { bundleID in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        }
    }
#else
    public extension RealClaudeLocator {
        static let launchServicesResolver: BundleIDResolver = { _ in nil }
    }
#endif

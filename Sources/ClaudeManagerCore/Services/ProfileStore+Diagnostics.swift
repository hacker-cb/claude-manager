import Foundation

/// Read-only aggregates over the running system: the live instance list for the
/// status view and the `Doctor` health check. Split out of `ProfileStore` to keep
/// that file within its length budget.
public extension ProfileStore {
    /// All running Claude instances across every bundle (for the status view).
    func runningInstances() -> [ClaudeInstance] {
        processProbe.allClaudeMains()
    }

    /// Health check. Shares this store's `managedConfigWriter` so the overlay/MDM
    /// checks honor the same (injectable) managed-preferences paths.
    func doctor() -> [Diagnostic] {
        Doctor(
            realClaude: realClaude,
            configuration: configuration,
            bundle: bundle,
            codeSigner: codeSigner,
            processProbe: processProbe,
            fileManager: fileManager,
            managedConfigWriter: managedConfigWriter
        ).run()
    }
}

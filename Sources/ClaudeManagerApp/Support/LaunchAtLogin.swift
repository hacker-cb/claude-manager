import ServiceManagement
import SwiftUI

/// "Launch at login", backed by `SMAppService.mainApp` (macOS 13+). The login-item
/// database is the source of truth, mirrored into published state for the toggle — we do
/// **not** persist our own bool, which would drift from a change the user makes in
/// System Settings › General › Login Items. The app is non-sandboxed, so `mainApp`
/// registers the app itself with no helper bundle. Default state is off: installing the
/// app never registers a login item silently — the user opts in.
@MainActor
final class LaunchAtLogin: ObservableObject {
    /// Registered *and* approved as a login item.
    @Published private(set) var isEnabled: Bool
    /// Registered but not yet approved by the user (macOS routes new login items through
    /// System Settings). Surfaced as a hint so an "on" toggle that isn't taking effect
    /// is explainable rather than looking broken.
    @Published private(set) var requiresApproval: Bool
    /// Last register/unregister failure for the view to show; `nil` when the last call
    /// succeeded or none has run.
    @Published private(set) var lastError: String?

    /// Present in the login-item database — enabled *or* still pending the user's approval.
    /// The single spelling of "there is a registration to act on", so the toggle, the Doctor
    /// residency check and the nudge can't drift on what counts as registered.
    var isRegistered: Bool {
        isEnabled || requiresApproval
    }

    /// Whether registering a login item is meaningful for this build. macOS only honours
    /// `SMAppService` registration for a Developer ID **signed + notarized** app, so a local
    /// build can't reliably register one — and must not: a dev build that lands in Login
    /// Items is exactly the symptom the separate dev identity exists to prevent
    /// (docs/DEVELOPMENT.md § Dev builds carry a separate identity).
    ///
    /// This type owns the answer so the rule is enforced at the choke point rather than at
    /// each call site: ``setEnabled`` refuses to register when false, and the views read
    /// this instead of re-deriving it, so a new caller can't bypass the invariant.
    let isSupported: Bool

    private let service: SMAppService

    init(service: SMAppService = .mainApp, isSupported: Bool = AppBuild.isDistribution) {
        self.service = service
        self.isSupported = isSupported
        isEnabled = service.status == .enabled
        requiresApproval = service.status == .requiresApproval
    }

    /// Register or unregister the login item, then reconcile published state with the
    /// service's real status. The request can be refused — a build macOS won't honour a
    /// registration for, or a user block in System Settings — so we never assume it took;
    /// the status read is authoritative.
    func setEnabled(_ enabled: Bool) {
        // Registering is refused in an unsupported build (see `isSupported`), but
        // *unregistering* never is: a login item left by an earlier run — or by a build
        // that shared the release's bundle id before the identity split — must always be
        // removable, so the escape hatch can't be locked behind the same gate.
        guard enabled == false || isSupported else {
            lastError = "Launch at login is available in released builds only."
            syncStatus()
            return
        }
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            lastError = nil
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        syncStatus()
    }

    /// Re-read the system status — e.g. when Settings appears, in case the user toggled
    /// the login item from System Settings while the app was running. Also drops any
    /// stale `lastError`: a fresh status read supersedes a failure from an earlier
    /// attempt the user may have since resolved out-of-band. `setEnabled` reconciles via
    /// `syncStatus` instead, so the error it just set for a failed toggle survives.
    func refresh() {
        syncStatus()
        lastError = nil
    }

    /// Reconcile the published `isEnabled` / `requiresApproval` with the service's real
    /// status, without touching `lastError`.
    private func syncStatus() {
        isEnabled = service.status == .enabled
        requiresApproval = service.status == .requiresApproval
    }
}

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
    @Published var lastError: String?

    private let service: SMAppService

    init(service: SMAppService = .mainApp) {
        self.service = service
        isEnabled = service.status == .enabled
        requiresApproval = service.status == .requiresApproval
    }

    /// Register or unregister the login item, then reconcile published state with the
    /// service's real status. The request can be refused — an unsigned dev build, or a
    /// user block in System Settings — so we never assume it took; the status read is
    /// authoritative.
    func setEnabled(_ enabled: Bool) {
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
        refresh()
    }

    /// Re-read the system status — e.g. when Settings appears, in case the user toggled
    /// the login item from System Settings while the app was running.
    func refresh() {
        isEnabled = service.status == .enabled
        requiresApproval = service.status == .requiresApproval
    }
}

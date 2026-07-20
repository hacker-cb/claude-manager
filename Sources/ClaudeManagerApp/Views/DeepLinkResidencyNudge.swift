import SwiftUI

/// A one-time nudge toward "Launch at login" when the deep-link broker is on but the app
/// isn't resident. The broker only holds `claude://` while Claude Manager runs, so a closed
/// app can let an account you open take over the scheme and stop links routing through the
/// picker. Shown at most once (a persisted flag); `Doctor`'s residency warning is the standing
/// reminder afterward, and Settings › Startup is always available.
struct DeepLinkResidencyNudge: ViewModifier {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var launchAtLogin: LaunchAtLogin
    @AppStorage("deepLinkResidencyNudged") private var nudged = false
    @State private var showNudge = false

    func body(content: Content) -> some View {
        content
            .task { evaluate() }
            .onChange(of: model.deepLinkBrokerEnabled) { _, _ in evaluate() }
            .onChange(of: launchAtLogin.isEnabled) { _, _ in evaluate() }
            .alert("Keep deep links routing to the right account?", isPresented: $showNudge) {
                Button("Enable Launch at Login") {
                    launchAtLogin.setEnabled(true)
                    nudged = true
                }
                Button("Not Now", role: .cancel) { nudged = true }
            } message: {
                Text(
                    "Claude Manager routes claude:// links only while it's running. Launch it at "
                        + "login so a link always opens in the account you pick. You can change "
                        + "this anytime in Settings › Startup."
                )
            }
    }

    /// Show the nudge once when the broker is on and the app is neither enabled nor pending
    /// approval for launch-at-login. `requiresApproval` counts as handled — the user already
    /// opted in and just needs to approve in System Settings.
    private func evaluate() {
        guard !nudged,
              model.deepLinkBrokerEnabled,
              !(launchAtLogin.isEnabled || launchAtLogin.requiresApproval)
        else { return }
        showNudge = true
    }
}

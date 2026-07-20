import ClaudeManagerCore
import SwiftUI

/// A one-time nudge toward "Launch at login" when the deep-link broker is on but the app
/// isn't resident. The broker only holds `claude://` while Claude Manager runs, so a closed
/// app can let an account you open take over the scheme and stop links routing through the
/// picker. Shown at most once (a persisted flag); `Doctor`'s residency warning is the standing
/// reminder afterward, and Settings › Startup is always available.
///
/// Every input folds into one derived `shouldNudge` (`DeepLinkResidency.shouldNudge`) that a
/// single `.onChange` tracks, so no input can be silently un-observed — the earlier
/// per-`onChange`-per-property shape forgot `requiresApproval` (issue #73). The single
/// observation is inherently bidirectional: opting into launch-at-login elsewhere (or an
/// approval landing) while the alert is open recomputes `shouldNudge` to `false` and
/// auto-dismisses it, rather than leaving a stale prompt up.
struct DeepLinkResidencyNudge: ViewModifier {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var launchAtLogin: LaunchAtLogin
    @AppStorage("deepLinkResidencyNudged") private var nudged = false
    @State private var showNudge = false

    /// `requiresApproval` counts as opted in — the user already chose launch-at-login and
    /// just needs to approve it in System Settings.
    private var shouldNudge: Bool {
        DeepLinkResidency.shouldNudge(
            nudged: nudged,
            // A dev build can't broker (it doesn't declare `claude://`) or register a login
            // item, so its broker is effectively off — never nudge toward a feature this
            // build can't provide. `canBrokerDeepLinks` folds that in at the input.
            brokerEnabled: model.deepLinkBrokerEnabled && AppBuild.canBrokerDeepLinks,
            launchAtLoginActive: launchAtLogin.isEnabled || launchAtLogin.requiresApproval
        )
    }

    func body(content: Content) -> some View {
        content
            // Seed once — `onChange` doesn't fire for the value present on the first render —
            // then track the folded predicate in both directions.
            .task { showNudge = shouldNudge }
            .onChange(of: shouldNudge) { _, show in
                // Auto-dismiss path: if the nudge was on screen and the condition just cleared
                // (the user opted into launch-at-login elsewhere, or turned the broker off),
                // persist `nudged` too — otherwise this "at most once" nudge would reappear if
                // they later opted back out. The alert buttons still set it for a tap-dismiss.
                if showNudge, !show { nudged = true }
                showNudge = show
            }
            .alert("Keep deep links routing to the right account?", isPresented: $showNudge) {
                // `nudged = true` is load-bearing under the bidirectional binding: it's what
                // stops a just-dismissed alert from immediately re-raising while conditions
                // still hold. Keep it in every button.
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
}

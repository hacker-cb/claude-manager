/// Pure policy for the one-time "turn on Launch at login" deep-link nudge, so the SwiftUI
/// modifier stays a thin driver over a unit-tested predicate (per "logic → core + a test").
public enum DeepLinkResidency {
    /// Whether to show the nudge. The broker holds `claude://` only while Claude Manager
    /// runs, so a non-resident app can lose the scheme to an account the user opens. Show it
    /// once (`nudged`), only when the broker is on and the user hasn't already opted into
    /// launch-at-login. `launchAtLoginActive` folds *enabled or pending-approval*: an item
    /// awaiting approval in System Settings counts as opted in (the user already chose it).
    public static func shouldNudge(
        nudged: Bool,
        brokerEnabled: Bool,
        launchAtLoginActive: Bool
    ) -> Bool {
        !nudged && brokerEnabled && !launchAtLoginActive
    }
}

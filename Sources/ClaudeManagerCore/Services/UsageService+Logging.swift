import Foundation
import OSLog

/// The usage pipeline's log vocabulary — the pass summary and the two renderings every line
/// shares. In its own file (like `+Identity` and `+Merge`) so the service file stays about the
/// poll logic; the call sites stay where the events happen.
extension UsageService {
    /// One `.notice` per completed pass — the trail a "why didn't it refresh?" report is read
    /// from, months later, out of `log show`. Counts and state labels only; nothing identifying.
    static func logPass(
        _ accounts: [AccountUsage],
        failures: [String: TokenProviderError],
        interactive: Bool
    ) {
        var counts: [String: Int] = [:]
        for account in accounts {
            counts[stateLabel(account.state), default: 0] += 1
        }
        let states = counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        CoreLog.usage.notice("""
        pass done: \(accounts.count, privacy: .public) account(s) [\(states, privacy: .public)], \
        \(failures.count, privacy: .public) binding failure(s), \
        interactive=\(interactive, privacy: .public)
        """)
    }

    /// The state's name for a log line — deliberately not `String(describing:)`, whose payloads
    /// (a stale date, a provider error) would bloat every summary this feeds.
    static func stateLabel(_ state: UsageState) -> String {
        switch state {
        case .fresh: "fresh"
        case .stale: "stale"
        case .loginNeeded: "loginNeeded"
        case .rateLimited: "rateLimited"
        case .noSource: "noSource"
        case .offline: "offline"
        }
    }

    /// An account uuid as logged: an 8-char prefix — enough to correlate lines, short of the
    /// identifier itself.
    static func logID(_ uuid: String) -> String {
        String(uuid.prefix(8))
    }
}

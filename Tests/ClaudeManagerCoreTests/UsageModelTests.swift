import Foundation
import Testing
@testable import ClaudeManagerCore

struct UsageModelTests {
    @Test
    func severityIsOrderedForMostSeverePick() {
        #expect(UsageSeverity.normal < UsageSeverity.warning)
        #expect(UsageSeverity.warning < UsageSeverity.critical)
        #expect([UsageSeverity.normal, .critical, .warning].max() == .critical)
    }

    @Test
    func severityParseIsLenient() {
        #expect(UsageSeverity.parse("WARNING") == .warning)
        #expect(UsageSeverity.parse("nonsense") == .normal)
        #expect(UsageSeverity.parse(nil) == .normal)
    }

    @Test
    func compactLabelClampsAnUnboundedServerLabelToTheCellItHasToFit() {
        func limit(_ kind: String, model: String? = nil) -> UsageLimit {
            UsageLimit(rawKind: kind, utilization: 0, scopeModelName: model)
        }
        // The two windows a row usually shows pass through whole.
        #expect(limit(UsageLimit.kindSession).compactLabel == "5h")
        #expect(limit(UsageLimit.kindWeeklyAll).compactLabel == "7d")
        // A scoped window stays recognizable at six characters; an unknown kind is a server
        // string of any length and must not be able to overflow a fixed-width column.
        #expect(limit(UsageLimit.kindWeeklyScoped, model: "Fable").compactLabel == "7d·Fab")
        #expect(limit("quantum_flux").compactLabel == "quantu")
        // Clamping is a width concession only — the tooltip and VoiceOver keep the full label.
        #expect(limit(UsageLimit.kindWeeklyScoped, model: "Fable").shortLabel == "7d·Fable")
    }

    @Test
    func extraUsageDisplayUtilizationPrefersServerThenDividesGuardingZero() {
        func extra(used: Int, limit: Int?, util: Double?) -> ExtraUsage {
            ExtraUsage(
                isEnabled: true,
                usedMinor: used,
                limitMinor: limit,
                utilization: util,
                currency: "USD"
            )
        }
        #expect(extra(used: 4200, limit: 100_000, util: 0.042).displayUtilization == 0.042) // server wins
        #expect(extra(used: 5000, limit: 10000, util: nil).displayUtilization == 0.5) // used ÷ cap
        #expect(extra(used: 5000, limit: nil, util: nil).displayUtilization == nil) // no cap → no bar
        #expect(extra(used: 5000, limit: 0, util: nil)
            .displayUtilization == 5000) // zero cap guarded, no crash
    }

    @Test
    func displaySeverityEscalatesOnServerFlagButNeverCalmsDown() {
        func limit(_ utilization: Double, _ severity: UsageSeverity) -> UsageLimit {
            UsageLimit(
                rawKind: "weekly_all", utilization: utilization, severity: severity, isActive: true
            )
        }
        // Our own thresholds when the server has nothing to add.
        #expect(limit(0.10, .normal).displaySeverity == .normal)
        #expect(limit(0.75, .normal).displaySeverity == .warning)
        #expect(limit(0.90, .normal).displaySeverity == .critical)
        // The server escalates something we don't model — a policy or an unknown limit kind.
        #expect(limit(0.10, .warning).displaySeverity == .warning)
        #expect(limit(0.10, .critical).displaySeverity == .critical)
        #expect(limit(0.80, .critical).displaySeverity == .critical)
        // …but a server "normal" can never calm a bar we already consider hot — which is the live
        // case: the API reports `normal` well past 70%.
        #expect(limit(0.95, .normal).displaySeverity == .critical)
        #expect(limit(0.76, .normal).displaySeverity == .warning)
    }

    @Test
    func accountLabelPrefersEmailAndNeverFallsBackToTheUUID() {
        #expect(AccountIdentity(uuid: "u", email: "a@b.co", displayName: "Ann").accountLabel == "a@b.co")
        #expect(AccountIdentity(uuid: "u", displayName: "Ann").accountLabel == "Ann")
        // Unnamed until /profile answers — nil, so the UI omits the slot rather than showing a uuid.
        #expect(AccountIdentity(uuid: "u").accountLabel == nil)
        #expect(AccountIdentity(uuid: "u", email: "").accountLabel == nil)
    }

    @Test
    func accountIdentityIsKeyedByUUID() {
        let a = AccountIdentity(uuid: "u1", email: "x@y")
        #expect(a.id == "u1")
        let set: Set = [a, AccountIdentity(uuid: "u1", email: "different")]
        // Hashable/Equatable fold on the whole value, so these are distinct entries;
        // the dedup *key* is `uuid` (used explicitly by the resolver), not Set identity.
        #expect(set.count == 2)
    }
}

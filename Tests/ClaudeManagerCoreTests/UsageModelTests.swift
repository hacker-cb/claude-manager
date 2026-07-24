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
    func scopedWeeklyBarShownForMaxTeamAndUnknownPlan() {
        #expect(AccountIdentity(uuid: "a", subscriptionType: "max").showsScopedWeeklyLimit)
        #expect(AccountIdentity(uuid: "a", subscriptionType: "team").showsScopedWeeklyLimit)
        #expect(AccountIdentity(uuid: "a", subscriptionType: nil).showsScopedWeeklyLimit)
        #expect(!AccountIdentity(uuid: "a", subscriptionType: "pro").showsScopedWeeklyLimit)
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

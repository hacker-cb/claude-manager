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
    func accountIdentityIsKeyedByUUID() {
        let a = AccountIdentity(uuid: "u1", email: "x@y")
        #expect(a.id == "u1")
        let set: Set = [a, AccountIdentity(uuid: "u1", email: "different")]
        // Hashable/Equatable fold on the whole value, so these are distinct entries;
        // the dedup *key* is `uuid` (used explicitly by the resolver), not Set identity.
        #expect(set.count == 2)
    }
}

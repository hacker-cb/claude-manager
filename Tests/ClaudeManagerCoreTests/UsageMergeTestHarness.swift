import Foundation
import Testing
@testable import ClaudeManagerCore

/// Builders for the `UsageService.merge` suites.
///
/// In their own file, and **internal** rather than private, because the fold's tests no longer fit
/// one file under the 500-line limit and an extension in another file cannot see a `private`
/// member. `capturedAt` stays on the type itself — an extension cannot hold a stored property.
extension UsageMergeTests {
    func snapshot(_ utilization: Double) -> UsageSnapshot {
        UsageSnapshot(
            limits: [UsageLimit(rawKind: UsageLimit.kindSession, utilization: utilization, isActive: true)],
            capturedAt: capturedAt
        )
    }

    func account(
        uuid: String,
        email: String? = nil,
        snapshot: UsageSnapshot?,
        state: UsageState = .fresh,
        bindingIDs: [String]
    ) -> AccountUsage {
        AccountUsage(
            identity: AccountIdentity(uuid: uuid, email: email),
            snapshot: snapshot,
            state: state,
            bindingIDs: bindingIDs
        )
    }
}

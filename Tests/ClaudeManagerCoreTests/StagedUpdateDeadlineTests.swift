import Foundation
import Testing
@testable import ClaudeManagerCore

/// Claude restarts the default profile by itself once an update has been pending long
/// enough, and it picks a moment nobody is watching. These cover the estimate that turns
/// that into something the user was warned about.
struct StagedUpdateDeadlineTests {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    @Test
    func measuresTheWaitAndWhatIsLeftOfTheWindow() {
        let deadline = StagedUpdateDeadline(firstSeen: epoch)
        let tenHoursIn = epoch.addingTimeInterval(10 * 3600)
        #expect(deadline.waited(asOf: tenHoursIn) == 10 * 3600)
        #expect(deadline.remaining(asOf: tenHoursIn) == 62 * 3600)
        #expect(deadline.earliestForcedRestart == epoch.addingTimeInterval(72 * 3600))
    }

    @Test
    func aClockThatWentBackwardsIsNotANegativeWait() {
        // A record written by another machine's clock, or a system time correction, must not
        // produce "waiting -3 h" in a user-facing string.
        let deadline = StagedUpdateDeadline(firstSeen: epoch)
        #expect(deadline.waited(asOf: epoch.addingTimeInterval(-3 * 3600)) == 0)
    }

    @Test
    func remainingBottomsOutAtZeroOnceThePointHasPassed() {
        // The restart defers while the machine is in use, so "past the window" is a normal
        // state that can last a long time — it must read as zero, not as a negative.
        let deadline = StagedUpdateDeadline(firstSeen: epoch)
        #expect(deadline.remaining(asOf: epoch.addingTimeInterval(100 * 3600)) == 0)
    }

    @Test
    func approachesOnlyNearTheEndOfTheWindow() {
        let deadline = StagedUpdateDeadline(firstSeen: epoch)
        let lead = StagedUpdateDeadline.warningLead
        #expect(!deadline.isApproaching(asOf: epoch.addingTimeInterval(60 * 3600), lead: lead))
        #expect(deadline.isApproaching(asOf: epoch.addingTimeInterval(69 * 3600), lead: lead))
        // …and stays true afterwards: a deferred restart still hasn't happened.
        #expect(deadline.isApproaching(asOf: epoch.addingTimeInterval(200 * 3600), lead: lead))
    }

    @Test
    func honoursAShortenedEnforcementWindow() {
        // The policy validates as `int().gt(0).lte(72)`, so a deployment can shorten it.
        let deadline = StagedUpdateDeadline(firstSeen: epoch, enforcementHours: 8)
        #expect(deadline.earliestForcedRestart == epoch.addingTimeInterval(8 * 3600))
        #expect(deadline.isApproaching(asOf: epoch.addingTimeInterval(5 * 3600), lead: 4 * 3600))
    }

    @Test
    func refusesAWindowThePolicyItselfRefuses() {
        // Zero or negative would put the estimate permanently in the past and warn forever.
        #expect(StagedUpdateDeadline(firstSeen: epoch, enforcementHours: 0).enforcementHours == 1)
        #expect(StagedUpdateDeadline(firstSeen: epoch, enforcementHours: -5).enforcementHours == 1)
    }

    // MARK: - Recording the sighting

    @Test
    func firstSightingIsStampedOnce() {
        let first = StagedUpdateDeadline.recordSighting(of: "9.9.10", into: [:], now: epoch)
        #expect(first == ["9.9.10": epoch])
        // A later refresh must NOT re-stamp it — that would hold the wait at zero forever and
        // the warning would never fire.
        let later = StagedUpdateDeadline.recordSighting(
            of: "9.9.10", into: first, now: epoch.addingTimeInterval(50 * 3600)
        )
        #expect(later == ["9.9.10": epoch])
    }

    @Test
    func onlyTheCurrentVersionIsKept() {
        // The record is a fact about the pending update, not a log of every Claude release.
        let existing = ["9.9.8": epoch, "9.9.9": epoch.addingTimeInterval(3600)]
        let updated = StagedUpdateDeadline.recordSighting(
            of: "9.9.10", into: existing, now: epoch.addingTimeInterval(7200)
        )
        #expect(updated == ["9.9.10": epoch.addingTimeInterval(7200)])
    }

    @Test
    func aNewerStagedVersionStartsItsOwnWait() {
        let old = ["9.9.9": epoch]
        let updated = StagedUpdateDeadline.recordSighting(
            of: "9.9.10", into: old, now: epoch.addingTimeInterval(80 * 3600)
        )
        #expect(updated["9.9.9"] == nil)
        #expect(updated["9.9.10"] == epoch.addingTimeInterval(80 * 3600))
    }

    @Test
    func nothingStagedClearsTheRecord() {
        // So a version staged again later — a rollback, a re-download — is a fresh wait, and
        // the caller's notification ledgers are pruned along with it.
        #expect(StagedUpdateDeadline.recordSighting(of: nil, into: ["9.9.9": epoch], now: epoch).isEmpty)
    }

    // MARK: - The diagnostic

    @Test
    func saysNothingUntilTheRestartIsClose() {
        let deadline = StagedUpdateDeadline(firstSeen: epoch)
        let row = Doctor.stagedUpdateDeadlineDiagnostic(
            stagedVersion: "1.32885.1", deadline: deadline, now: epoch.addingTimeInterval(3600)
        )
        #expect(row == nil, "most waits end long before the window — they should be silent")
    }

    @Test
    func warnsWithTheWaitAndAnEstimate() throws {
        let deadline = StagedUpdateDeadline(firstSeen: epoch)
        let row = try #require(Doctor.stagedUpdateDeadlineDiagnostic(
            stagedVersion: "1.32885.1", deadline: deadline, now: epoch.addingTimeInterval(70 * 3600)
        ))
        #expect(row.severity == .warning)
        #expect(row.title.contains("waiting 70 h"))
        #expect(row.title.contains("about 2 h"))
        #expect(row.title.contains("the default profile may restart itself"))
        #expect(row.detail?.contains("Apply to all profiles") == true)
    }

    @Test
    func pastTheWindowItSaysSoWithoutInventingATime() throws {
        let deadline = StagedUpdateDeadline(firstSeen: epoch)
        let row = try #require(Doctor.stagedUpdateDeadlineDiagnostic(
            stagedVersion: "1.32885.1", deadline: deadline, now: epoch.addingTimeInterval(90 * 3600)
        ))
        #expect(row.title.contains("at any time now"))
        #expect(!row.title.contains("about 0 h"))
    }
}

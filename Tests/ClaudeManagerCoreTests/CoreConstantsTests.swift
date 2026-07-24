import Testing
@testable import ClaudeManagerCore

struct CoreConstantsTests {
    @Test
    func placeholderMarketingVersionIsNotADistributionBuild() {
        // The project.yml dev placeholder must read as a non-distribution build so the
        // updater stays dormant locally.
        #expect(!CoreConstants.isDistributionBuild(marketingVersion: CoreConstants.devMarketingVersion))
        #expect(!CoreConstants.isDistributionBuild(marketingVersion: "0.0.0"))
    }

    @Test
    func realSemverIsADistributionBuild() {
        // A build number of 1 (first CI run) must NOT disable updates — only the marketing
        // placeholder does. Any real tag version is a distribution build.
        #expect(CoreConstants.isDistributionBuild(marketingVersion: "0.1.0"))
        #expect(CoreConstants.isDistributionBuild(marketingVersion: "1.2.3"))
    }

    @Test
    func wrapperVersionsBelowTheSigningFloorAreUnrunnable() {
        // Below v3 the bundle carries no signature, so macOS refuses to execute it —
        // "unrunnable", not merely "stale".
        #expect(CoreConstants.wrapperVersionIsUnrunnable(1))
        #expect(CoreConstants.wrapperVersionIsUnrunnable(2))
        #expect(!CoreConstants.wrapperVersionIsUnrunnable(CoreConstants.minimumRunnableWrapperVersion))
        #expect(!CoreConstants.wrapperVersionIsUnrunnable(CoreConstants.currentWrapperVersion))
    }

    @Test
    func theRunnableFloorNeverOutrunsTheCurrentFormat() {
        // A floor above the current format would mark every freshly built launcher as
        // unrunnable the moment it is created.
        #expect(CoreConstants.minimumRunnableWrapperVersion <= CoreConstants.currentWrapperVersion)
        // …and an unrunnable launcher is always stale too, so the rebuild affordance the
        // error tells the user to use is actually offered.
        #expect(CoreConstants.wrapperVersionIsStale(CoreConstants.minimumRunnableWrapperVersion - 1))
    }
}

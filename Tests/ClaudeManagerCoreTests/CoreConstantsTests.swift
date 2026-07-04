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
}

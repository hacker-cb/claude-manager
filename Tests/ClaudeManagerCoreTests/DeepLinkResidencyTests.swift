import Testing
@testable import ClaudeManagerCore

struct DeepLinkResidencyTests {
    @Test
    func nudgesOnlyWhenBrokerOnAndNotOptedInAndNotYetNudged() {
        // The single case that should nudge: broker on, not opted into launch-at-login, and
        // not shown before.
        #expect(DeepLinkResidency.shouldNudge(nudged: false, brokerEnabled: true, launchAtLoginActive: false))
    }

    @Test
    func suppressedOnceNudged() {
        #expect(!DeepLinkResidency.shouldNudge(nudged: true, brokerEnabled: true, launchAtLoginActive: false))
    }

    @Test
    func suppressedWhenBrokerOff() {
        #expect(!DeepLinkResidency.shouldNudge(
            nudged: false,
            brokerEnabled: false,
            launchAtLoginActive: false
        ))
    }

    @Test
    func suppressedWhenAlreadyOptedIntoLaunchAtLogin() {
        // `launchAtLoginActive` is enabled *or* pending approval — either suppresses the nudge.
        #expect(!DeepLinkResidency.shouldNudge(nudged: false, brokerEnabled: true, launchAtLoginActive: true))
    }
}

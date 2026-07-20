import Foundation
import Testing
@testable import ClaudeManagerCore

/// Records what the forwarder asked its injected effects to do, and feeds a scripted pid
/// sequence back. An `actor` so the `@Sendable` effect closures can mutate it race-free;
/// every probe consumes the next scripted value (default `nil` == "still not running").
private actor ForwarderProbe {
    private var pidScript: [Int32?]
    private(set) var probeCalls = 0
    private let launchResult: DeepLinkForwarder.LaunchResult
    private(set) var launchCalls = 0
    private let deliverResult: DeepLinkDeliveryFailure?
    private(set) var deliverCalls = 0
    private(set) var deliveredPIDs: [Int32] = []
    private(set) var releaseCalls = 0
    private(set) var sleeps: [Duration] = []

    init(
        pidScript: [Int32?],
        launchResult: DeepLinkForwarder.LaunchResult = .started,
        deliverResult: DeepLinkDeliveryFailure? = nil
    ) {
        self.pidScript = pidScript
        self.launchResult = launchResult
        self.deliverResult = deliverResult
    }

    func nextPID() -> Int32? {
        defer { probeCalls += 1 }
        guard !pidScript.isEmpty else { return nil }
        return pidScript.removeFirst()
    }

    func launch() -> DeepLinkForwarder.LaunchResult {
        launchCalls += 1
        return launchResult
    }

    func deliver(_ pid: Int32) -> DeepLinkDeliveryFailure? {
        deliverCalls += 1
        deliveredPIDs.append(pid)
        return deliverResult
    }

    func release() {
        releaseCalls += 1
    }

    func recordSleep(_ duration: Duration) {
        sleeps.append(duration)
    }
}

private let testURL = URL(string: "claude://claude.ai/magic-link?code=abc")!

private func makeForwarder(
    _ probe: ForwarderProbe,
    pollAttempts: Int = 3,
    pollInterval: Duration = .zero,
    settle: Duration = .zero
) -> DeepLinkForwarder {
    DeepLinkForwarder(
        pollAttempts: pollAttempts,
        pollInterval: pollInterval,
        settle: settle,
        probePID: { await probe.nextPID() },
        launch: { await probe.launch() },
        release: { await probe.release() },
        deliver: { _, pid in await probe.deliver(pid) },
        sleep: { await probe.recordSleep($0) }
    )
}

struct DeepLinkForwarderTests {
    @Test
    func runningInstanceIsDeliveredWithoutLaunchingOrSleeping() async {
        let probe = ForwarderProbe(pidScript: [123])
        let outcome = await makeForwarder(probe).forward(testURL)

        #expect(outcome == .delivered)
        #expect(await probe.probeCalls == 1)
        #expect(await probe.launchCalls == 0)
        #expect(await probe.deliveredPIDs == [123])
        #expect(await probe.sleeps.isEmpty)
        #expect(await probe.releaseCalls == 0) // never launched → never holds a slot
    }

    @Test
    func runningInstanceTccDenialMapsToDeliveryFailed() async {
        let probe = ForwarderProbe(pidScript: [123], deliverResult: .notPermitted)
        let outcome = await makeForwarder(probe).forward(testURL)

        #expect(outcome == .deliveryFailed(.notPermitted))
        #expect(await probe.launchCalls == 0)
    }

    @Test
    func sendFailedCodeIsPreservedInTheOutcome() async {
        let probe = ForwarderProbe(pidScript: [123], deliverResult: .sendFailed(code: 17))
        let outcome = await makeForwarder(probe).forward(testURL)

        #expect(outcome == .deliveryFailed(.sendFailed(code: 17)))
    }

    @Test
    func coldLaunchPollsThenSettlesThenDelivers() async {
        // Initial probe nil → launch; poll: nil once, then pid 42.
        let probe = ForwarderProbe(pidScript: [nil, nil, 42])
        let forwarder = makeForwarder(
            probe, pollAttempts: 3, pollInterval: .milliseconds(1), settle: .milliseconds(2)
        )
        let outcome = await forwarder.forward(testURL)

        #expect(outcome == .delivered)
        #expect(await probe.launchCalls == 1)
        #expect(await probe.probeCalls == 3) // initial + 2 poll probes
        #expect(await probe.deliveredPIDs == [42])
        // One poll-interval wait (nil probe) then the settle before delivering.
        #expect(await probe.sleeps == [.milliseconds(1), .milliseconds(2)])
        #expect(await probe.releaseCalls == 1) // started launch → released after deliver
    }

    @Test
    func failedLaunchShortCircuitsWithoutPollingOrDelivering() async {
        let probe = ForwarderProbe(pidScript: [nil], launchResult: .failed)
        let outcome = await makeForwarder(probe).forward(testURL)

        #expect(outcome == .launchFailed)
        #expect(await probe.probeCalls == 1) // only the initial probe, no poll loop
        #expect(await probe.deliverCalls == 0)
        #expect(await probe.releaseCalls == 0) // nothing acquired
        #expect(await probe.sleeps.isEmpty)
    }

    @Test
    func instanceThatNeverAppearsGivesUpAfterTheBoundAndReleases() async {
        let probe = ForwarderProbe(pidScript: [nil]) // then always nil
        let forwarder = makeForwarder(probe, pollAttempts: 3)
        let outcome = await forwarder.forward(testURL)

        #expect(outcome == .neverAppeared)
        #expect(await probe.probeCalls == 4) // initial + exactly pollAttempts probes
        #expect(await probe.deliverCalls == 0)
        #expect(await probe.sleeps.count == 3) // one wait per empty poll iteration
        #expect(await probe.releaseCalls == 1) // a .started launch is released even on give-up
    }

    @Test
    func alreadyInFlightLaunchPollsButNeverReleasesTheSlot() async {
        // Another launch owns the slot: poll for it, deliver, but don't release (not ours).
        let probe = ForwarderProbe(pidScript: [nil, 99], launchResult: .alreadyInFlight)
        let outcome = await makeForwarder(probe).forward(testURL)

        #expect(outcome == .delivered)
        #expect(await probe.launchCalls == 1)
        #expect(await probe.deliveredPIDs == [99])
        #expect(await probe.releaseCalls == 0) // never acquired → never releases someone else's
    }
}

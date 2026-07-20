import Testing
@testable import ClaudeManagerCore

struct AsyncPollTests {
    /// Yields a scripted sequence of probe results and counts probe + sleep calls, so a test
    /// can assert the exact loop shape (how many probes ran, how many sleeps between them).
    private actor Probe {
        private let results: [Int32?]
        private(set) var probeCalls = 0
        private(set) var sleepCalls = 0

        init(_ results: [Int32?]) {
            self.results = results
        }

        func probe() -> Int32? {
            defer { probeCalls += 1 }
            guard probeCalls < results.count else { return nil }
            return results[probeCalls]
        }

        func recordSleep() {
            sleepCalls += 1
        }
    }

    @Test
    func returnsFirstNonNilAndStopsProbing() async {
        let probe = Probe([nil, nil, 42, 99])
        let value = await AsyncPoll.firstNonNil(
            attempts: 10,
            interval: .milliseconds(1),
            sleep: { _ in await probe.recordSleep() },
            probe: { await probe.probe() }
        )
        #expect(value == 42)
        #expect(await probe.probeCalls == 3) // nil, nil, 42 — stops on the hit, never reaches 99
        #expect(await probe.sleepCalls == 2) // one sleep after each miss, none after the hit
    }

    @Test
    func returnsNilAfterExhaustingTheBudget() async {
        let probe = Probe([nil, nil, nil])
        let value = await AsyncPoll.firstNonNil(
            attempts: 3,
            interval: .milliseconds(1),
            sleep: { _ in await probe.recordSleep() },
            probe: { await probe.probe() }
        )
        #expect(value == nil)
        #expect(await probe.probeCalls == 3) // exactly `attempts` probes
        #expect(await probe.sleepCalls == 3) // a sleep after every miss, including the last
    }

    @Test
    func hitOnFirstProbeNeverSleeps() async {
        let probe = Probe([7])
        let value = await AsyncPoll.firstNonNil(
            attempts: 5,
            interval: .milliseconds(1),
            sleep: { _ in await probe.recordSleep() },
            probe: { await probe.probe() }
        )
        #expect(value == 7)
        #expect(await probe.probeCalls == 1)
        #expect(await probe.sleepCalls == 0)
    }

    @Test
    func zeroAttemptsProbesNothing() async {
        let probe = Probe([42])
        let value = await AsyncPoll.firstNonNil(
            attempts: 0,
            interval: .milliseconds(1),
            sleep: { _ in await probe.recordSleep() },
            probe: { await probe.probe() }
        )
        #expect(value == nil)
        #expect(await probe.probeCalls == 0)
        #expect(await probe.sleepCalls == 0)
    }
}

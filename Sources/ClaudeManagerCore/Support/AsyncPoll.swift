import Foundation

/// Bounded async polling: call `probe` up to `attempts` times, sleeping `interval` between
/// misses, and return its first non-nil result — or `nil` once the budget is spent. `sleep`
/// is injected so tests drive it instantly and each caller keeps its own clock.
///
/// The single home for the "wait until a freshly `open -n`'d Claude instance is observable"
/// loop shared by the deep-link forwarder's pid poll and the toolbar `openReal` launch guard
/// (#38), so the two can't drift. Pure control flow with every effect injected, so the whole
/// loop — probe count, sleep count, early stop — runs deterministically in headless tests.
public enum AsyncPoll {
    public static func firstNonNil<Value: Sendable>(
        attempts: Int,
        interval: Duration,
        sleep: @Sendable (Duration) async -> Void,
        probe: @Sendable () async -> Value?
    ) async -> Value? {
        for _ in 0 ..< attempts {
            if let value = await probe() { return value }
            await sleep(interval)
        }
        return nil
    }
}

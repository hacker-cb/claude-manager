import Darwin
import Foundation

/// Process-lifecycle timing primitives shared by every stop path: send a signal and
/// poll until the process exits (`stopProcess`), and the generic suspend-and-recheck
/// loop underneath it (`poll`). Kept in one place so stop cadence, force-escalation,
/// cancellation, and the poll loop have a single home — `stop` / `stopDefault` differ
/// only in which pid they read and which "is it gone" probe they pass.
extension ProfileStore {
    /// Signal `pid` (SIGTERM, or SIGKILL when `force`) and poll `isGone` until the process
    /// exits or the budget elapses, mapping the result to a `StopOutcome`. The caller has
    /// already resolved a live `pid`, so the outcome is `.stopped` or `.stillRunning`.
    func stopProcess(
        pid: Int32,
        force: Bool,
        pollInterval: TimeInterval,
        maxPolls: Int,
        isGone: () -> Bool
    ) async -> StopOutcome {
        _ = signalSender(pid, force ? SIGKILL : SIGTERM)
        let stopped = await poll(interval: pollInterval, maxPolls: maxPolls, isGone)
        return stopped ? .stopped : .stillRunning(pid: pid)
    }

    /// Poll `condition` up to `maxPolls` times, suspending `interval` between checks.
    ///
    /// Suspends with `Task.sleep`, not `Thread.sleep`: a stubborn process can keep us
    /// waiting up to `pollInterval * maxPolls` (~10s by default), and this runs off the
    /// main actor on the shared cooperative pool, so suspending keeps that thread free.
    /// Checks `condition` once before the first sleep and once after the last, and returns
    /// true as soon as it holds. Cancellation stops the wait early: a cancelled
    /// `Task.sleep` throws and we break out rather than busy-spinning the rest of the
    /// budget. `interval` is clamped only to keep a negative value out of `Duration`; a
    /// zero or tiny interval still returns near-immediately, bounded by the `maxPolls` cap.
    func poll(interval: TimeInterval, maxPolls: Int, _ condition: () -> Bool) async -> Bool {
        if condition() { return true }
        let duration = Duration.seconds(max(0, interval))
        for _ in 0 ..< maxPolls {
            do {
                try await Task.sleep(for: duration)
            } catch {
                break // cancelled — stop waiting
            }
            if condition() { return true }
        }
        return condition()
    }
}

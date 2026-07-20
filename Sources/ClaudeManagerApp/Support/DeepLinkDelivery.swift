import CoreServices // AE* Apple-event types/constants + AEDeterminePermissionToAutomateTarget
import Foundation

/// Delivers a `claude://` deep link to a **specific** Claude instance by sending it the
/// same Apple event macOS/LaunchServices uses to open a URL — a `GURL`/`GURL`
/// (`kInternetEventClass`/`kAEGetURL`) event addressed to that process's pid. Electron's
/// `app.on('open-url')` handles it and routes the link internally (the account "sorts out"
/// which window/mode to open it in).
///
/// Why a raw Apple event rather than `open`: every managed profile's Claude runs the real,
/// signed binary, so after the launcher `exec`s it they **all share bundle id
/// `com.anthropic.claudefordesktop`**. `open`/bundle-id addressing therefore can't tell
/// two running instances apart — but a pid can. And Claude only reads deep links from the
/// `open-url` event (it does *not* scan `argv` for the scheme), so `open -n … --args <url>`
/// silently drops the link; the Apple event is the one channel that actually lands.
///
/// TCC: sending an Apple event to another app needs a one-time Automation grant
/// ("Claude Manager" → "Claude"); the app ships the `com.apple.security.automation.apple-events`
/// entitlement and an `NSAppleEventsUsageDescription`. All profiles share the target bundle
/// id, so a single grant covers every account.
enum DeepLinkDelivery {
    /// FourCharCode `'GURL'` — both the `kInternetEventClass` and the `kAEGetURL` id.
    private static let gurl = AEEventClass(0x4755_524C)
    /// FourCharCode `'----'` — `keyDirectObject`, where the URL string rides.
    private static let directObject = AEKeyword(0x2D2D_2D2D)

    enum Failure: Error, Equatable {
        /// The user hasn't granted (or has denied) Automation control of Claude.
        case notPermitted
        /// The target process is gone (quit between the pid probe and the send).
        case targetGone
        /// Any other Apple-event failure (`OSStatus`).
        case sendFailed(code: Int)
    }

    /// Deliver `url` to the Claude instance with process id `pid`. Throws `Failure` so the
    /// caller can distinguish a TCC denial (actionable) from a transient failure.
    static func send(_ url: URL, toPID pid: pid_t) throws {
        let target = NSAppleEventDescriptor(processIdentifier: pid)

        // Determine (and, if undecided, prompt for) Automation permission *first*. This is the
        // deterministic signal — a `.noReply` GURL send returns "ok" even when TCC has silently
        // blocked it, so without this a denied hand-off would look like a success and the link
        // would just vanish. `askUserIfNeeded: true` surfaces the one-time consent prompt.
        let permission = target.aeDesc.map {
            AEDeterminePermissionToAutomateTarget(
                $0,
                AEEventClass(typeWildCard),
                AEEventID(typeWildCard),
                true
            )
        } ?? OSStatus(errAEEventNotPermitted)
        switch permission {
        case noErr:
            break
        case OSStatus(errAEEventNotPermitted):
            Log.deepLink.error("automation to pid \(pid, privacy: .public) not permitted (TCC)")
            throw Failure.notPermitted
        case OSStatus(procNotFound):
            throw Failure.targetGone
        default:
            Log.deepLink
                .error(
                    "automation check for pid \(pid, privacy: .public) failed: OSStatus \(permission, privacy: .public)"
                )
            throw Failure.sendFailed(code: Int(permission))
        }

        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: gurl,
            eventID: AEEventID(gurl),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(NSAppleEventDescriptor(string: url.absoluteString), forKeyword: directObject)
        do {
            // .noReply: fire-and-forget — Claude doesn't answer a GURL. Permission is already
            // settled above, so this send only fails for a transient reason now.
            _ = try event.sendEvent(options: [.noReply], timeout: 5)
            Log.deepLink
                .info(
                    "GURL delivered to pid \(pid, privacy: .public): \(url.logDescription, privacy: .public)"
                )
        } catch let error as NSError {
            if error.code == -1743 { throw Failure.notPermitted } // errAEEventNotPermitted
            Log.deepLink.error("GURL to pid \(pid, privacy: .public) failed: \(error.code, privacy: .public)")
            throw Failure.sendFailed(code: error.code)
        }
    }
}

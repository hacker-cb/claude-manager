import Foundation

/// What the window's single update control says for the **two** updaters behind it.
///
/// Two of them, and they are not alike: Claude's updates are this app's own business —
/// fetched, verified and installed here, which is why `ClaudeUpdateState` is a state machine —
/// while Claude Manager's belong to Sparkle, which owns everything past "a release exists".
/// One control speaks for both anyway, because from the window's side they are the same
/// question: *is there something new, and what would pressing it do?*
///
/// The rules live here rather than in the view for the usual reason — they are decisions, and
/// decisions are what a test can hold still.
public enum UpdateNews {
    /// Whether either updater has anything to report. False is what takes the control out of
    /// the toolbar entirely: a permanent button for "nothing to do" is one more thing between
    /// the user and the ones that act.
    public static func hasNews(claude: ClaudeUpdateState, manager: ManagerUpdateState) -> Bool {
        claude != .idle || manager != .idle
    }

    /// The version to print beside the icon, or nil to show the icon alone.
    ///
    /// A prepared build earns it — either app's. That is the state which waits indefinitely,
    /// where nothing at all happens until someone presses, and a bare arrow is easy to walk
    /// past for days. Every other state either moves on its own (a download finishes, an
    /// install completes) or is answered by opening the panel, and a toolbar that grows a
    /// version string for each of them is a toolbar that reflows while you look at it.
    ///
    /// **Exactly one, or none.** With both apps holding a prepared build, printing either
    /// number is worse than printing none: two versions side by side read as one that changed,
    /// and a single one leaves the reader to guess whose it is. The panel is where each release
    /// gets its name, and Claude's is listed first there — so an unlabelled arrow is the honest
    /// shape for "more than one thing is waiting".
    public static func buttonLabel(claude: ClaudeUpdateState, manager: ManagerUpdateState) -> String? {
        let claudeVersion: String? = if case let .ready(verified) = claude {
            verified.version
        } else { nil }
        let managerVersion = manager.isWaitingForAPress ? manager.version : nil
        let waiting = [claudeVersion, managerVersion].compactMap(\.self)
        return waiting.count == 1 ? waiting[0] : nil
    }

    /// The tooltip, which is also the accessibility label: every piece of news, in one line,
    /// in the order the panel lists them.
    ///
    /// `lastSuccess` reaches `ClaudeUpdateState.statusLine` and matters only for `.idle`, which
    /// this never prints — an idle updater contributes nothing rather than "last checked 4 h
    /// ago", which is a fact for the Settings row and noise beside a release someone is about
    /// to install.
    public static func help(
        claude: ClaudeUpdateState,
        manager: ManagerUpdateState,
        lastSuccess: Date?,
        now: Date = Date()
    ) -> String {
        var lines: [String] = []
        if claude != .idle {
            lines.append(claude.statusLine(lastSuccess: lastSuccess, now: now))
        }
        if manager != .idle {
            lines.append(manager.statusLine)
        }
        return lines.joined(separator: " ")
    }
}

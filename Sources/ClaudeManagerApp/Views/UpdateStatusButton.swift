import AppKit
import ClaudeManagerCore
import Sparkle
import SwiftUI

/// The one place an update is offered in the window — either update: a toolbar button saying
/// where the two updaters stand, and a popover carrying the sentences behind them.
///
/// **Two updaters, one control.** Claude's updates are this app's own work — fetched, verified
/// and installed here, which is why they have a state machine. Claude Manager's belong to
/// Sparkle, which owns everything past "a release exists" and says so in a modal window that,
/// once dismissed, takes the news with it. From the window's side both are the same question —
/// *is there something new, and what would pressing it do?* — so they share a control rather
/// than growing a second one that means almost the same thing.
///
/// Deliberately not a notification and not a nightly job: installing Claude closes every
/// profile the user has open, so it happens when they say so and while they are looking at it.
/// Downloading and verifying happen on their own beforehand, which is why the button is usually
/// an instant action rather than a wait.
///
/// **A toolbar item rather than the full-width strip this used to be.** The strip hung off the
/// split view's `.safeAreaInset`, which for a `ScrollView` is a *content inset*, not a margin:
/// the detail page scrolled underneath it, and a `.quaternary`-tinted background is not opaque,
/// so the page's own heading and controls showed through the offer as if the two had been
/// printed over each other. A strip also gets cut in half by the sidebar divider — its sentence
/// ends up in one column and its button in the other. In the toolbar the offer takes no layout
/// from the page at all, and its longest states — a verification failure's reason, the "this
/// closes every profile" warning — get a popover to be legible in rather than one clipped line.
struct UpdateStatusButton: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var managerUpdate: ManagerUpdateWatcher
    /// Sparkle's updater, for the one thing this view asks of it: open the update window.
    private let updater: SPUUpdater
    /// Whether that window can be opened at all right now — the same gate the menu item uses.
    @StateObject private var updaterReadiness: UpdaterReadiness
    @State private var showingDetails = false

    init(updater: SPUUpdater) {
        self.updater = updater
        _updaterReadiness = StateObject(wrappedValue: UpdaterReadiness(updater: updater))
    }

    var body: some View {
        // Stated here as well as in `RootView`, which leaves the item out when there is no
        // news: a `Button` whose label renders nothing is still a button, so a toolbar item
        // that outlives the state change by a frame would be an invisible, clickable control
        // opening an empty panel. `EmptyView` has nothing to click.
        if UpdateNews.hasNews(claude: model.claudeUpdateState, manager: managerUpdate.state) {
            button
        }
    }

    private var button: some View {
        Button { showingDetails = true } label: { indicator }
            .help(helpText)
            .accessibilityLabel(helpText)
            // Opening the popover is the safe half of every state: it says what would happen and
            // nothing more. That is what lets the install button sit inside it without a
            // confirmation dialog of its own — reaching it takes a deliberate press on a control
            // that does nothing, and the sentence above it spells the cost out. The same
            // reasoning the menu bar's submenu rests on (`MenuBarContent.claudeUpdateItems`).
            .popover(isPresented: $showingDetails) {
                details
                    .padding(16)
                    .frame(width: 320)
            }
            // An open panel is rendered from a state the updater keeps moving: a download that
            // finishes swaps an empty action row for "Close profiles and install", under a
            // cursor that was aimed at neither. So a change of *case* closes the panel and the
            // press has to be made again, against what the state actually is now. Keyed on the
            // case rather than the state: progress arrives many times a second, and every one
            // of those is a change to `.downloading`'s payload.
            .onChange(of: phase) { showingDetails = false }
    }

    /// Both states' cases with their payloads dropped — the shape of the panel, without the
    /// numbers that move inside it.
    ///
    /// Sparkle's side counts now. It used to only ever *add* a section whose button opens a
    /// window; with background downloads it also rewrites one in place — a finished download
    /// turns "Update…" into a prominent "Install and Relaunch" that quits and restarts the
    /// app, exactly under a cursor that was aimed at the harmless one.
    private var phase: String {
        let claude = switch model.claudeUpdateState {
        case .idle: "idle"
        case .available: "available"
        case .downloading: "downloading"
        case .ready: "ready"
        case .installing: "installing"
        case .failed: "failed"
        }
        let manager = switch managerUpdate.state {
        case .idle: "idle"
        case .available: "available"
        case .downloaded: "downloaded"
        }
        return claude + "/" + manager
    }

    // MARK: - The button itself

    /// What the toolbar shows with the popover shut — the whole of what a passing glance gets.
    @ViewBuilder private var indicator: some View {
        switch model.claudeUpdateState {
        case .idle:
            // Reached whenever the news is the *manager's* — Sparkle found a release while
            // Claude is current. Same two arrows as Claude's own states mean: hollow for a
            // release that exists, filled for one on disk waiting to be let in, with its
            // version beside it since nothing else is competing for the space.
            if let version = versionLabel {
                Label(version, systemImage: "arrow.down.circle.fill").labelStyle(.titleAndIcon)
            } else if managerUpdate.state.isWaitingForAPress {
                Image(systemName: "arrow.down.circle.fill")
            } else {
                Image(systemName: "arrow.down.circle")
            }
        case .available:
            Image(systemName: "arrow.down.circle")
        case let .downloading(_, received, total):
            if let total, total > 0 {
                // Determinate where the server said how big it is: with the popover shut this
                // button is the only sign of a transfer that can run for minutes, and a
                // spinner would say only that *something* is happening.
                ProgressView(value: Double(received), total: Double(total))
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            } else {
                ProgressView().controlSize(.small)
            }
        case .ready:
            // A prepared build carries its version in the button — unless the *other* updater
            // is holding one too, where `UpdateNews.buttonLabel` answers nil. An empty title is
            // not the same as none (`Label` still lays that `Text` and its spacing out), so the
            // absence drops to the bare icon.
            if let version = versionLabel {
                Label(version, systemImage: "arrow.down.circle.fill").labelStyle(.titleAndIcon)
            } else {
                Image(systemName: "arrow.down.circle.fill")
            }
        case .installing:
            ProgressView().controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    /// The version to print beside the icon, when exactly one release is waiting on a press.
    private var versionLabel: String? {
        UpdateNews.buttonLabel(claude: model.claudeUpdateState, manager: managerUpdate.state)
    }

    /// The tooltip, which is also the accessibility label: every updater with something to
    /// say, in the order the panel lists them, spelled in the core beside the states it
    /// describes rather than a second time here.
    private var helpText: String {
        let line = UpdateNews.help(
            claude: model.claudeUpdateState,
            manager: managerUpdate.state,
            lastSuccess: model.lastClaudeUpdateSuccess
        )
        guard case let .downloading(_, received, total) = model.claudeUpdateState,
              let total, total > 0
        else { return line }
        // The transfer's own figures, which `statusLine` has no room for and which are the
        // reason to hover a progress indicator in the first place.
        return line + " " + Self.progressText(received: received, total: total)
    }

    // MARK: - The popover

    /// One section per updater with something to say, in a fixed order: Claude first, because
    /// its states are the ones that move on their own and the ones whose button costs the most.
    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.claudeUpdateState != .idle { claudeDetails }
            if model.claudeUpdateState != .idle, managerUpdate.state != .idle { Divider() }
            managerDetails
        }
    }

    /// What Sparkle has, and the one press that acts on it.
    @ViewBuilder private var managerDetails: some View {
        switch managerUpdate.state {
        case .idle:
            EmptyView()
        case let .available(version):
            detail("Claude Manager \(version) is available.") {
                Text("It has not been fetched yet. Updating replaces this app and relaunches "
                    + "it; profiles that are open keep running — they are Claude, not this.")
            } actions: {
                Button("Update…") {
                    act {
                        // Sparkle's window is modal and opens wherever the app is; the press
                        // often comes with another app frontmost (this is a menu-bar app),
                        // where cooperative activation can leave the dialog behind it. Forceful
                        // on purpose, and warning-free — see #31, and `CheckForUpdatesView`,
                        // which opens the same flow from the menu.
                        NSApp.activate(ignoringOtherApps: true)
                        updater.checkForUpdates()
                    }
                }
                // `checkForUpdates()` returns without a word while a session is in progress — a
                // background download, another window already up — so an enabled button there
                // is a press that does nothing. Same gate as the menu item's.
                .disabled(!updaterReadiness.canCheckForUpdates)
            }
        case let .downloaded(version):
            detail("Claude Manager \(version) is ready to install.") {
                Text("It was fetched in the background and checked by Sparkle. Installing "
                    + "relaunches this app; profiles that are open keep running, and the "
                    + "update goes in by itself the next time Claude Manager quits.")
            } actions: {
                // No `canCheckForUpdates` gate here: this presses Sparkle's own staged-install
                // handler rather than starting a check, and it is exactly the session that
                // handler belongs to.
                Button("Install and Relaunch") { act { managerUpdate.installStagedUpdate() } }
                    .buttonStyle(.borderedProminent)
                    // Never while Claude's own swap is in flight. `installClaudeUpdate` runs in
                    // *this* process: it closes every open profile, replaces
                    // `/Applications/Claude.app`, and reopens the set it closed. Relaunching
                    // Claude Manager in the middle of that leaves the swap half-done and the
                    // profiles closed with nothing alive to reopen them — the same reason every
                    // other control that could disturb an install is gated on this.
                    .disabled(model.claudeUpdateState.blocksProfileActivity)
            }
        }
    }

    @ViewBuilder private var claudeDetails: some View {
        switch model.claudeUpdateState {
        case .idle:
            EmptyView()
        case let .available(update):
            // Reached both before a download starts *and* after one is interrupted — a slept
            // laptop, a dropped connection — so it must not claim to be downloading. It is
            // not necessarily brief either: the resume waits for the next scheduled check,
            // which is why there is a button to ask for it now.
            detail("Claude \(update.version) is available.") {
                Text("It has not been downloaded yet. The next scheduled check picks it up on "
                    + "its own, or fetch it now — downloading closes nothing.")
            } actions: {
                Button("Download") { act { model.checkForClaudeUpdateNow() } }
            }
        case let .downloading(version, received, total):
            detail("Downloading Claude \(version)…") {
                if let total, total > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: Double(received), total: Double(total))
                        Text(Self.progressText(received: received, total: total))
                            .monospacedDigit()
                    }
                } else {
                    Text("The server did not say how big it is; this finishes when it finishes.")
                }
            }
        case let .ready(verified):
            detail("Claude \(verified.version) is ready to install.") {
                Text("Every open profile will be closed and reopened. A profile with a session "
                    + "still working will refuse to close, and the installed app will be left "
                    + "as it is.")
            } actions: {
                // Prominent so it is findable, but deliberately *not* `.defaultAction`:
                // Return is pressed absent-mindedly, and this button closes every open
                // profile. Reaching it takes two deliberate presses, as the menu bar's
                // submenu does.
                Button("Close profiles and install") {
                    act { Task { await model.installClaudeUpdate() } }
                }
                .buttonStyle(.borderedProminent)
            }
        case let .installing(version):
            detail("Installing Claude \(version)…") {
                Text("Profiles are closing; the same set reopens once the swap is done.")
            }
        case let .failed(reason):
            detail("Claude update failed.") {
                Text(reason)
            } actions: {
                // Through the same entry point as every other trigger, so repeated clicks
                // cannot start a second check beside the first — and so a retry that fails
                // again says so, rather than clearing the state and looking like a success.
                Button("Try again") { act { model.checkForClaudeUpdateNow() } }
            }
        }
    }

    /// One popover body: a heading, the sentence under it, and whatever there is to press.
    private func detail(
        _ headline: String,
        @ViewBuilder body: () -> some View,
        @ViewBuilder actions: () -> some View = { EmptyView() }
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(headline)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            body()
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); actions() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Run a button's action with the popover closed first, and on the next turn of the loop.
    ///
    /// Closing it is the point: every action here changes the state the popover is rendered
    /// from, so one left open would redraw into a different sentence under the cursor —
    /// and the install, which closes every profile, would do it behind a panel still offering
    /// to start it.
    ///
    /// The hop is the other half. `checkForClaudeUpdateNow` can answer *synchronously* with an
    /// alert — "already working on it", an unreadable installed version — and an alert raised
    /// in the same transaction as a dismissing popover is the classic way to have it swallowed
    /// on macOS: the press would then look like it did nothing, which is the one outcome
    /// `ClaudeUpdateAnnouncement` exists to prevent.
    private func act(_ action: @escaping () -> Void) {
        showingDetails = false
        Task { @MainActor in
            // The yield is the hop. A `Task` created on the main actor is scheduled rather
            // than run inline, but its first resumption can still land in the same drain of
            // the main actor's queue that is dismissing the popover — which is the window
            // this is here to step over. Yielding puts the continuation behind whatever is
            // already queued, so the dismissal's transaction commits first.
            await Task.yield()
            action()
        }
    }

    /// `142 MB of 335 MB`, formatted the way the Finder would.
    ///
    /// The formatter is built once: progress arrives many times a second during a 335 MB
    /// transfer, and each one re-renders this view.
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static func progressText(received: Int64, total: Int64) -> String {
        let format = byteFormatter
        return "\(format.string(fromByteCount: received)) of \(format.string(fromByteCount: total))"
    }
}

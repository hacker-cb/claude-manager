import ClaudeManagerCore
import SwiftUI

/// The one place a Claude update is offered, in the window: a toolbar button saying where the
/// updater stands, and a popover carrying the sentence behind it.
///
/// Deliberately not a notification and not a nightly job: installing closes every profile the
/// user has open, so it happens when they say so and while they are looking at it. Downloading
/// and verifying happen on their own beforehand, which is why the button is usually an instant
/// action rather than a wait.
///
/// **A toolbar item rather than the full-width strip this used to be.** The strip hung off the
/// split view's `.safeAreaInset`, which for a `ScrollView` is a *content inset*, not a margin:
/// the detail page scrolled underneath it, and a `.quaternary`-tinted background is not opaque,
/// so the page's own heading and controls showed through the offer as if the two had been
/// printed over each other. A strip also gets cut in half by the sidebar divider — its sentence
/// ends up in one column and its button in the other. In the toolbar the offer takes no layout
/// from the page at all, and its longest states — a verification failure's reason, the "this
/// closes every profile" warning — get a popover to be legible in rather than one clipped line.
struct ClaudeUpdateStatusButton: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingDetails = false

    var body: some View {
        // Stated here as well as in `RootView`, which leaves the item out for `.idle`: a
        // `Button` whose label renders nothing is still a button, so a toolbar item that
        // outlives the state change by a frame would be an invisible, clickable control
        // opening an empty panel. `EmptyView` has nothing to click.
        if case .idle = model.claudeUpdateState {
            EmptyView()
        } else {
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

    /// The state's case with its payload dropped — what the panel's shape depends on.
    private var phase: String {
        switch model.claudeUpdateState {
        case .idle: "idle"
        case .available: "available"
        case .downloading: "downloading"
        case .ready: "ready"
        case .installing: "installing"
        case .failed: "failed"
        }
    }

    // MARK: - The button itself

    /// What the toolbar shows with the popover shut — the whole of what a passing glance gets.
    @ViewBuilder private var indicator: some View {
        switch model.claudeUpdateState {
        case .idle:
            // Never rendered: `RootView` leaves the item out entirely for `.idle` rather than
            // parking a control for "nothing to do" among the four that act.
            EmptyView()
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
        case let .ready(verified):
            // The one state that carries its version in the button. It is also the only one
            // that waits indefinitely — nothing moves until someone presses — and a bare arrow
            // is easy to walk past for days.
            Label(verified.version, systemImage: "arrow.down.circle.fill")
                .labelStyle(.titleAndIcon)
        case .installing:
            ProgressView().controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    /// The tooltip, which is also the accessibility label: the same sentence the Settings row
    /// and the menu bar show, spelled once in the core beside the state machine it describes.
    private var helpText: String {
        let line = model.claudeUpdateState.statusLine(lastSuccess: model.lastClaudeUpdateSuccess)
        guard case let .downloading(_, received, total) = model.claudeUpdateState,
              let total, total > 0
        else { return line }
        // The transfer's own figures, which `statusLine` has no room for and which are the
        // reason to hover a progress indicator in the first place.
        return line + " " + Self.progressText(received: received, total: total)
    }

    // MARK: - The popover

    @ViewBuilder private var details: some View {
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
        Task { @MainActor in action() }
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

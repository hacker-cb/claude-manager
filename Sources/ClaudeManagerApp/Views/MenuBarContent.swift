import AppKit
import ClaudeManagerCore
import Sparkle
import SwiftUI

struct MenuBarContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    /// The app-scoped Sparkle updater (see ClaudeManagerApp) — shared, never re-created.
    let updater: SPUUpdater

    var body: some View {
        if model.realClaude == nil {
            Text("Claude.app not found")
        } else {
            nowRows
            claudeUpdateItems
            // Profiles — the default profile first, then each clone, as one uniform list.
            // The default keeps its own person glyph (filled when running, mirroring the
            // clones' filled/empty circle) so it reads as a peer, not a special case.
            Button {
                Task { await model.openReal() }
            } label: {
                // No " — running" text: the filled/hollow glyph already carries that, and
                // repeating it in words pushed the usage figure further out of alignment.
                Label(
                    "Default profile" + usageSuffix(TokenBinding.defaultID),
                    systemImage: model.primaryProfile?.isRunning == true
                        ? "person.crop.circle.fill" : "person.crop.circle"
                )
                .accessibilityLabel(rowAccessibilityLabel(
                    "Default profile",
                    isRunning: model.primaryProfile?.isRunning == true,
                    bindingID: TokenBinding.defaultID
                ))
            }
            .disabled(model.claudeUpdateState.blocksProfileActivity)

            if model.profiles.isEmpty {
                Text("No launchers yet")
            } else {
                ForEach(model.profiles) { managed in
                    Button {
                        Task { await model.open(managed.profile) }
                    } label: {
                        Label(
                            managed.profile.displayName + usageSuffix(managed.profile.id),
                            systemImage: managed.isRunning ? "circle.fill" : "circle"
                        )
                        .accessibilityLabel(rowAccessibilityLabel(
                            managed.profile.displayName,
                            isRunning: managed.isRunning,
                            bindingID: managed.profile.id
                        ))
                    }
                    .disabled(model.claudeUpdateState.blocksProfileActivity)
                }
            }

            // Stop — every running profile, the default profile included.
            let runningClones = model.profiles.filter(\.isRunning)
            let defaultRunning = model.primaryProfile?.isRunning == true
            if defaultRunning || !runningClones.isEmpty {
                Divider()
                Menu("Stop") {
                    if defaultRunning {
                        Button("Default profile") {
                            Task { await model.stopDefaultProfile(force: false) }
                        }
                    }
                    ForEach(runningClones) { managed in
                        Button(managed.profile.displayName) {
                            Task { await model.stop(managed.profile, force: false) }
                        }
                    }
                }
            }

            let behind = model.profiles.filter(\.claudeUpdateAvailable)
            if !behind.isEmpty {
                Menu("Restart to Update") {
                    ForEach(behind) { managed in
                        Button(
                            "\(managed.profile.displayName) — v\(managed.availableClaudeVersion ?? "")"
                        ) {
                            Task { await model.restart(managed.profile) }
                        }
                    }
                }
                .disabled(model.claudeUpdateState.blocksProfileActivity)
            }
        }

        Divider()
        Button("Open Claude Manager") {
            openWindow(id: WindowID.main)
            // Forceful on purpose: this fires from the menu-bar extra while another app is
            // frontmost, where cooperative `NSApp.activate()` may leave the window behind it.
            // Warning-free on current SDKs (Apple softened the deprecation to a future
            // placeholder) — see #31 for why this isn't migrated to `activate()`.
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Refresh") { Task { await model.refresh() } }
        // Gated like every other item that needs Claude: with the app missing there is no
        // version to compare a release against, and the item would answer a press with a
        // second banner about an unreadable *version* beside the one saying Claude.app was
        // not found — and send the user to Re-detect, which cannot conjure a missing app.
        if model.realClaude != nil {
            Button("Check for Claude Updates…") { checkForClaudeUpdates() }
        }
        CheckForUpdatesView(updater: updater)
        Divider()
        Button("Quit Claude Manager") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// The answer, at the top of the menu: which profile to take work to, per mode.
    ///
    /// The menu is where this question is actually asked most of the time — it needs no window
    /// and no Dock icon — so the page's headline lives here as two rows that open the profile
    /// they name. The menu is rebuilt on every open, so what they say is as current as a ticker
    /// would make it.
    ///
    /// Only where the two modes can differ: on a plan reporting no per-model window they would be
    /// two rows with one answer between them.
    @ViewBuilder
    private var nowRows: some View {
        if model.usageTrackingEnabled, !model.limitsAccounts.isEmpty {
            let now = Date()
            let modes: [WorkMode] = model.limitsHasScopedWindows
                ? WorkMode.allCases
                : [model.limitsMode]
            ForEach(modes, id: \.self) { mode in
                nowRow(mode: mode, now: now)
            }
            Divider()
        }
    }

    @ViewBuilder
    private func nowRow(mode: WorkMode, now: Date) -> some View {
        let overview = model.limitsOverview(mode: mode, now: now)
        let label = model.limitsModeLabel(mode)
        if let leader = overview.leader, let entry = model.limitsProfiles(of: leader.account).first {
            Button {
                open(entry)
            } label: {
                Label(
                    "\(label) → \(model.limitsAccountName(leader.account))"
                        + "  ·  \(UsageOverview.reason(for: leader, now: now))",
                    systemImage: "arrow.right.circle"
                )
            }
            .disabled(model.claudeUpdateState.blocksProfileActivity)
        } else {
            // Nil is a real answer, and a menu row that silently vanished when the fleet ran out
            // would read as the feature being broken rather than as the fleet being spent.
            Button {} label: {
                Label("\(label) → nobody right now", systemImage: "arrow.right.circle")
            }
            .disabled(true)
        }
    }

    private func open(_ entry: ProfileEntry) {
        switch entry {
        case .primary: Task { await model.openReal() }
        case let .clone(managed): Task { await model.open(managed.profile) }
        }
    }

    /// Ask for Claude's update from the menu bar, with a window open to answer in.
    ///
    /// The window comes first deliberately. Every answer a check can give is presented there
    /// — "up to date", a failure, the download's progress, the Install button itself — and
    /// `presentInfo` writes to an alert the window owns, so from a closed one this would be a
    /// menu item whose result surfaces hours later, beside whatever the user is doing by
    /// then. Activation is forceful for the same reason `Open Claude Manager` above is: this
    /// fires from the menu-bar extra while another app is frontmost.
    private func checkForClaudeUpdates() {
        openWindow(id: WindowID.main)
        NSApp.activate(ignoringOtherApps: true)
        model.checkForClaudeUpdateNow()
    }

    /// A trailing `  ·  7d 54% · resets in 3h 10m` for a profile row, or "" when tracking is off
    /// or there's no binding limit yet — so a menu row shows its own worst limit at a glance,
    /// together with how long until it lets go. The menu is rebuilt each time it opens, so the
    /// countdown here is current without a ticker.
    /// The running/stopped state is carried only by the filled/hollow SF Symbol glyph, which
    /// VoiceOver reads identically — so spell it out for assistive tech here, keeping the visible
    /// row text uncluttered (the glyph is the sighted cue).
    private func rowAccessibilityLabel(_ name: String, isRunning: Bool, bindingID: String) -> String {
        "\(name), \(isRunning ? "running" : "not running")\(usageSuffix(bindingID))"
    }

    private func usageSuffix(_ bindingID: String) -> String {
        guard model.usageTrackingEnabled else { return "" }
        // One clock for the whole row. The menu is rebuilt each time it opens, so reading it here is
        // as current as a ticker would be — but reading it *twice* is not: the gate below and the
        // phrase it admits would then be answering slightly different questions, and across the
        // window's boundary that reintroduces the permanent "resetting…" the gate exists to stop.
        let now = Date()
        // No account for this binding at all: a profile already signed out when the app launched
        // has no snapshot to carry forward, so its bare failure is the only thing that can explain
        // the blank. Only a sign-out, though — the other ways to land here are permanent, normal
        // states (see `UsageAccessory.attention`), and this row stays silent for them as it always
        // did.
        guard let usage = model.usage(forBinding: bindingID) else {
            let failure = model.usageFailure(forBinding: bindingID)
            return UsagePresentation.attentionNote(usage: nil, failure: failure)
                .map { "  ·  \($0)" } ?? ""
        }
        // A snapshot is kept for the detail pane even when it has stopped moving (signed out,
        // offline, rate-limited, or simply stale). Quoting that percentage here — beside a live
        // countdown, with no room to qualify it — would read as current, so say the state instead.
        guard usage.isQuotableNow else { return "  ·  \(UsagePresentation.stateNote(usage, now: now))" }
        guard let limit = usage.displayLimit else { return "" }
        var suffix = "  ·  \(UsageFormat.limitSummary(limit))"
        // Same gate as the pane and the sidebar tooltip: an elapsed window would print a permanent
        // "resetting…" here too.
        let resets = UsagePresentation.showsReset(limit.resetsAt, now: now)
            ? UsageFormat.resets(limit.resetsAt, now: now)
            : nil
        if let resets { suffix += " · \(resets)" }
        return suffix
    }

    /// Claude's own update, in the menu bar.
    ///
    /// A submenu rather than a one-click item, for the same reason the staged-update entry
    /// below is one: installing closes and reopens every open profile, interrupting live
    /// sessions, and that must never fire from a single stray click. A menu cannot present a
    /// `.confirmationDialog`, so opening the submenu and choosing the explicit item *is* the
    /// confirmation.
    @ViewBuilder
    private var claudeUpdateItems: some View {
        switch model.claudeUpdateState {
        case .idle:
            // No divider either: an unconditional one opens the menu with a stray separator
            // above the first real item.
            EmptyView()
        case let .available(update):
            // What a dropped connection or a slept laptop leaves behind: a build exists and
            // nothing is fetching it until the next scheduled check, hours away. A single
            // click is safe here — this downloads, it does not close anybody's session.
            Button {
                checkForClaudeUpdates()
            } label: {
                Label("Download Claude \(update.version)", systemImage: "arrow.down.circle")
            }
            Divider()
        case .failed:
            // The reason itself stays in the window's banner: a menu row is one line, and a
            // verification failure does not fit in one line.
            Button {
                checkForClaudeUpdates()
            } label: {
                Label("Claude update failed — check again", systemImage: "exclamationmark.triangle.fill")
            }
            Divider()
        case let .downloading(version, _, _):
            // Disabled Button, not a bare Label: an item with no action still looks
            // selectable in a menu.
            Button {} label: {
                Label("Downloading Claude \(version)…", systemImage: "arrow.down.circle")
            }
            .disabled(true)
            Divider()
        case let .installing(version):
            Button {} label: {
                Label("Installing Claude \(version)…", systemImage: "arrow.down.circle.fill")
            }
            .disabled(true)
            Divider()
        case let .ready(verified):
            Menu {
                Button("Close profiles and install") {
                    Task { await model.installClaudeUpdate() }
                }
            } label: {
                Label("Update Claude to \(verified.version)…", systemImage: "arrow.down.circle.fill")
            }
            Divider()
        }
    }
}

/// The status-bar item's label: the stack glyph, plus the worst limit across all accounts
/// (`7d 54%`) when usage tracking has data. `Label` gives the menu-bar icon + text; a plain
/// `Image` keeps just the glyph when there's nothing to show.
///
/// The accessibility label is pinned to the app name: the closure form of `MenuBarExtra` has no
/// title string, so without this VoiceOver would announce the usage summary (or the SF Symbol's
/// derived name) and the status item would no longer be identifiable by name.
struct MenuBarLabel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        content
            .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder private var content: some View {
        if let summary = model.menuBarUsageSummary {
            Label(summary, systemImage: "square.stack.3d.up.fill")
        } else {
            Image(systemName: "square.stack.3d.up.fill")
        }
    }

    private var accessibilityText: String {
        guard let summary = model.menuBarUsageSummary else { return "Claude Manager" }
        return "Claude Manager — \(summary) used"
    }
}

import AppKit
import ClaudeManagerCore
import Sparkle
import SwiftUI

struct MenuBarContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    /// The app-scoped Sparkle updater (see ClaudeManagerApp) — shared, never re-created.
    let updater: SPUUpdater
    @EnvironmentObject private var managerUpdate: ManagerUpdateWatcher

    var body: some View {
        if model.realClaude == nil {
            Text("Claude.app not found")
        } else {
            // The answer rows sit inside this branch on purpose, and a review asked why: the
            // ranking is information, so why withhold it while the app is missing? Because every
            // one of these rows *is* its button — the launchers `exec` that binary, so with it
            // gone there is nowhere to send the work the row recommends. This menu in that state
            // is a diagnostic, and a confident "take Fable work to Alice" above the line saying
            // Claude.app was not found makes the state less legible rather than more. The page
            // answers differently because it is a report rather than a two-row answer: it keeps
            // the account on screen with its figures and marks the profile unopenable.
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
        // Also refreshes usage, which is what makes the rows above reachable at all under
        // "Manually only": nothing polls then, so after every launch `usageByBinding` is empty
        // and the answers stay hidden with no windowless way to fill them. Interactive, because
        // this is a user gesture — the one path allowed to raise the keychain prompt — and the
        // service's own 60s floor keeps a mashed menu from hammering the API.
        Button("Refresh") {
            Task { await model.refreshAfterLocating() }
        }
        // Gated like every other item that needs Claude: with the app missing there is no
        // version to compare a release against, and the item would answer a press with a
        // second notice about an unreadable *version* beside the banner saying Claude.app was
        // not found — and send the user to Re-detect, which cannot conjure a missing app.
        if model.realClaude != nil {
            Button("Check for Claude Updates…") { checkForClaudeUpdates() }
        }
        CheckForUpdatesView(updater: updater)
        // The staged build's own item, and the reason it has to exist: with background
        // downloads on, `ManagerUpdateWatcher` takes Sparkle's install over so its modal
        // reminder stops interrupting — which leaves the window's toolbar as the only place
        // that says so, and this app is used for days at a time with no window open. One
        // press, named for what it does: the relaunch is this app's alone, and profiles that
        // are open are Claude's processes, untouched by it.
        if case let .downloaded(version) = managerUpdate.state {
            Button("Install Claude Manager \(version) and Relaunch") {
                managerUpdate.installStagedUpdate()
            }
            // Gated on `isBusy`, so a Claude download as well as a swap: both run in *this*
            // process, and a relaunch either loses a third-of-a-gigabyte transfer with no
            // resume data or leaves the swap half-done with every profile closed and nothing
            // alive to reopen them.
            .disabled(model.claudeUpdateState.isBusy)
        }
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
        if model.usageTrackingEnabled {
            if model.limitsAccounts.isEmpty {
                // Say it rather than vanish — the same rule the rows themselves follow when the
                // ranking has no leader, applied one state further out. The page spells both of
                // these cases out; the menu used to show nothing at all, and it is the surface
                // with no other way to find out, since a menu-bar-only session has no window to
                // open and no banner to read.
                Text(nothingToRankNote)
            } else {
                let now = Date()
                let modes: [WorkMode] = model.limitsHasScopedWindows
                    ? WorkMode.allCases
                    : [model.limitsEffectiveMode]
                ForEach(modes, id: \.self) { mode in
                    nowRow(mode: mode, now: now)
                }
            }
            Divider()
        }
    }

    /// Which of the two empty states this is. Refreshing fixes one of them and cannot touch the
    /// other, so telling a signed-out fleet to Refresh would send it round the same loop — the
    /// distinction the page's own empty state draws, in one line's worth of room.
    private var nothingToRankNote: String {
        guard let blocking = model.limitsBlockingFailures.first else {
            return "Where to work: no usage read yet"
        }
        return "Where to work: \(blocking)"
    }

    @ViewBuilder
    private func nowRow(mode: WorkMode, now: Date) -> some View {
        let overview = model.limitsOverview(mode: mode, now: now)
        let label = model.limitsModeLabel(mode)
        // The two questions are asked separately on purpose. Folded into one `if let` chain, a
        // leader whose profiles could not be resolved fell into the else and announced an
        // exhausted fleet — reporting "nobody" where a recommendation actually existed.
        if let leader = overview.leader {
            let entries = model.limitsProfiles(of: leader.account)
            let text = "\(label) → \(model.limitsAccountName(leader.account))"
                + "  ·  \(UsageOverview.reason(for: leader, now: now))"
            if entries.count == 1, let entry = entries.first {
                Button { open(entry) } label: {
                    Label(text, systemImage: "arrow.right.circle")
                }
                .disabled(model.claudeUpdateState.blocksProfileActivity)
            } else if entries.count > 1 {
                // A login several launchers share: the ranking chose the *account*, and which
                // window to open it in is the person's call — taking the first silently activated
                // an arbitrary workspace.
                Menu {
                    ForEach(entries) { entry in
                        Button(profileName(entry)) { open(entry) }
                    }
                } label: {
                    Label(text, systemImage: "arrow.right.circle")
                }
                .disabled(model.claudeUpdateState.blocksProfileActivity)
            } else {
                Button {} label: { Label(text, systemImage: "arrow.right.circle") }
                    .disabled(true)
            }
        } else {
            // Nil is a real answer, and a menu row that silently vanished when the fleet ran out
            // would read as the feature being broken rather than as the fleet being spent.
            Button {} label: {
                Label("\(label) → nobody right now", systemImage: "arrow.right.circle")
            }
            .disabled(true)
        }
    }

    private func profileName(_ entry: ProfileEntry) -> String {
        switch entry {
        case .primary: "Default profile"
        case let .clone(managed): managed.profile.displayName
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
            // The reason itself stays in the window's toolbar popover: a menu row is one line,
            // and a verification failure does not fit in one line.
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

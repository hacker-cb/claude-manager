import ClaudeManagerCore
import SwiftUI

struct ProfileDetailView: View {
    @EnvironmentObject private var model: AppModel
    let managed: ManagedProfile
    @Binding var editor: EditorRoute?

    @State private var showRemoveDialog = false

    private var profile: Profile {
        managed.profile
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if managed.claudeUpdateAvailable { restartBanner }
                if model.needsRestartToApply(managed) { applyEditsBanner }
                if managed.needsRebuild { rebuildBanner }
                Divider()
                actions
                if model.usageTrackingEnabled {
                    Divider()
                    UsageDetailSection(
                        usage: model.usage(forBinding: profile.id),
                        failure: model.usageFailure(forBinding: profile.id),
                        isRefreshing: model.isRefreshingUsage,
                        onRefresh: { Task { await model.refreshUsage(interactive: true) } }
                    )
                }
                Divider()
                details
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(profile.displayName)
        .confirmationDialog(
            "Remove \(profile.displayName)?",
            isPresented: $showRemoveDialog,
            titleVisibility: .visible
        ) {
            Button("Move Launcher to Trash (keep login)") {
                Task { await model.removeProfile(profile, purgeProfile: false) }
            }
            Button("Move to Trash and Delete Profile Data", role: .destructive) {
                Task { await model.removeProfile(profile, purgeProfile: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The launcher goes to the Trash. Deleting profile data removes this profile's login and settings — irreversible."
            )
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            BadgePreview(label: profile.label, color: profile.color, size: 88)
            VStack(alignment: .leading, spacing: 6) {
                Text(profile.displayName).font(.title2).bold()
                // The Anthropic login this launcher holds — or that it holds none. Identity, not
                // statistics, so it sits with the name rather than inside the Usage section, where
                // it read as a detail of the numbers and was easy to miss.
                if let account = UsagePresentation.accountLine(
                    usage: model.usage(forBinding: profile.id),
                    failure: model.usageFailure(forBinding: profile.id)
                ) {
                    Text(account).font(.callout).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                HStack(spacing: 8) {
                    StatusDot(isRunning: managed.isRunning)
                    Text(managed
                        .isRunning ? "Running (pid \(managed.pid.map(String.init) ?? "?"))" : "Stopped")
                        .foregroundStyle(.secondary)
                    if let size = managed.diskSize {
                        Text("· \(size)").foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
            }
            Spacer()
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                Task { await model.open(profile) }
            } label: {
                Label(managed.isRunning ? "Activate" : "Open", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)

            if managed.isRunning {
                Button { Task { await model.stop(profile, force: false) } } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                Button { Task { await model.stop(profile, force: true) } } label: {
                    Label("Force", systemImage: "bolt.fill")
                }
            }

            Spacer()

            Button { editor = .edit(profile) } label: { Label("Edit", systemImage: "pencil") }
            Menu {
                if managed.isRunning {
                    Button("Restart") { Task { await model.restart(profile) } }
                }
                Button("Rebuild Launcher") { Task { await model.rebuild(profile) } }
                Button("Reveal Profile Data in Finder") { model.revealProfileData(profile) }
                Button("Reveal Launcher in Finder") { model.revealLauncher(profile) }
                Divider()
                Button("Remove…", role: .destructive) { showRemoveDialog = true }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    /// Shown when the live instance is on an older Claude than the app now on disk —
    /// Claude.app updated in place. Offers a one-click restart onto the new version.
    private var restartBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.clockwise")
                .foregroundStyle(.blue)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Restart to update").font(.callout).bold()
                Text("Running \(managed.runningClaudeVersion ?? "an older build") — "
                    + "Claude \(managed.availableClaudeVersion ?? "") is installed. "
                    + "Restart to move this profile onto the new version.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Restart") { Task { await model.restart(profile) } }
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Shown when this profile's launcher was rewritten — edited or rebuilt — while the
    /// instance now running was already up. The rewrite landed on disk; what it cannot
    /// reach is a live process, which keeps the name and Dock tile it launched with. So the
    /// nudge asks for the one thing that does apply it, and the banner retires itself once
    /// the pid changes (see `AppModel.needsRestartToApply`).
    private var applyEditsBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .foregroundStyle(.blue)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Restart to apply").font(.callout).bold()
                Text("This launcher changed while the profile was open. The running window keeps "
                    + "the name and icon it started with until you restart it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Restart") { Task { await model.restart(profile) } }
                .buttonStyle(.borderedProminent)
            // Dismissible, like the Dock-refresh banner: a rewrite mid-session is not urgent,
            // and without this the only way to clear it is to end a session the user may be
            // in the middle of. It clears the sidebar mark with it, and unlike the Dock
            // refresh that is not a dead end — Restart stays on this pane and in the
            // context menu, so the remedy is always one click away.
            Button { model.dismissRestartNudge(profile) } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
            .help("Dismiss — the window keeps its old name and icon until you restart it")
        }
        .padding(12)
        .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Shown when the launcher was built by an older wrapper — offers a one-click rebuild.
    /// Available while running: the live process does not execute out of the bundle, so the
    /// rebuild lands either way and the profile then shows "Restart to apply". Gating it on
    /// running is what used to put a wrapper bump out of reach of an always-open profile.
    ///
    /// Two severities behind one banner: a launcher predating ad-hoc signing is refused
    /// execution by macOS, so it gets error styling and "won't launch" wording, while a
    /// merely-dated one keeps the soft "update available" nudge. Wording the first as
    /// optional is how a user ends up with launchers that flash in the Dock and die.
    private var rebuildBanner: some View {
        let unrunnable = managed.isUnrunnable
        let tint: Color = unrunnable ? .red : .orange
        return HStack(spacing: 10) {
            Image(systemName: unrunnable ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath")
                .foregroundStyle(tint)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(unrunnable ? "Won't launch" : "Update available").font(.callout).bold()
                Text(unrunnable
                    ? "This launcher is unsigned, and macOS refuses to run unsigned apps — "
                    + "it appears in the Dock and quits. Rebuild to fix it."
                    : "Built by an older version of Claude Manager. "
                    + "Rebuild to apply the latest launcher improvements.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Rebuild") { Task { await model.rebuild(profile) } }
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private var details: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 10) {
            detailRow("Badge", value: "\(profile.label)  ·  \(profile.color.displayName)")
            detailRow(
                "Profile data",
                value: PathUtils.abbreviatingHome(profile.profilePath),
                reveal: { model.revealProfileData(profile) }
            )
            detailRow(
                "Launcher",
                value: PathUtils.abbreviatingHome(profile.appPath),
                reveal: { model.revealLauncher(profile) }
            )
            detailRow("Bundle ID", value: profile.bundleID)
        }
    }

    private func detailRow(_ label: String, value: String, reveal: (() -> Void)? = nil) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            HStack(spacing: 6) {
                Text(value)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let reveal {
                    Button(action: reveal) { Image(systemName: "arrow.right.circle") }
                        .buttonStyle(.borderless)
                        .help("Reveal in Finder")
                }
            }
        }
    }
}

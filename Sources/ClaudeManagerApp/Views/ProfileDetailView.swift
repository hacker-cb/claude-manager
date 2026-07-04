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
                if managed.needsRebuild { rebuildBanner }
                Divider()
                actions
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
                "The launcher goes to the Trash. Deleting profile data removes this account's login and settings — irreversible."
            )
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            BadgePreview(label: profile.label, color: profile.color, size: 88)
            VStack(alignment: .leading, spacing: 6) {
                Text(profile.displayName).font(.title2).bold()
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
                    .disabled(managed.isRunning)
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

    /// Shown when the launcher was built by an older wrapper — offers a one-click
    /// rebuild. Disabled while running (the core refuses to rewrite a live bundle).
    private var rebuildBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Update available").font(.callout).bold()
                Text("Built by an older version of Claude Manager. "
                    + (managed.isRunning ? "Stop it first, then rebuild " : "Rebuild ")
                    + "to apply the latest launcher improvements.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Rebuild") { Task { await model.rebuild(profile) } }
                .buttonStyle(.borderedProminent)
                .disabled(managed.isRunning)
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
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

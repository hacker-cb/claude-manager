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
                Button("Regenerate Icon") { Task { await model.regenerateIcon(profile) } }
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

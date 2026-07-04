import ClaudeManagerCore
import SwiftUI

struct ProfileListView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selection: ManagedProfile.ID?

    var body: some View {
        List(selection: $selection) {
            ForEach(model.profiles) { managed in
                ProfileRow(managed: managed)
                    .tag(managed.id)
            }
        }
        .overlay {
            if model.profiles.isEmpty, model.realClaude != nil {
                ContentUnavailableView {
                    Label("No launchers yet", systemImage: "square.stack.3d.up.slash")
                } description: {
                    Text("Create one to run another Claude account side by side.")
                }
            }
        }
    }
}

struct ProfileRow: View {
    @EnvironmentObject private var model: AppModel
    let managed: ManagedProfile

    var body: some View {
        HStack(spacing: 10) {
            BadgeChip(
                label: managed.profile.label,
                color: managed.profile.color,
                height: 22,
                style: model.badgeStyle
            )
            .frame(width: 44, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(managed.profile.displayName)
                    .font(.body)
                    .lineLimit(1)
                Text(PathUtils.abbreviatingHome(managed.profile.profilePath))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    if managed.claudeUpdateAvailable {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.blue)
                            .help(
                                "Claude \(managed.availableClaudeVersion ?? "update") available — restart to update"
                            )
                    }
                    if managed.needsRebuild {
                        Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help("Update available — rebuild the launcher")
                    }
                    StatusDot(isRunning: managed.isRunning)
                }
                if let size = managed.diskSize {
                    Text(size).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Open") { Task { await model.open(managed.profile) } }
            if managed.isRunning {
                Button("Stop") { Task { await model.stop(managed.profile, force: false) } }
                Button("Restart") { Task { await model.restart(managed.profile) } }
            }
            Button("Rebuild Launcher") { Task { await model.rebuild(managed.profile) } }
                .disabled(managed.isRunning)
            Divider()
            Button("Reveal Profile Data in Finder") { model.revealProfileData(managed.profile) }
            Button("Reveal Launcher in Finder") { model.revealLauncher(managed.profile) }
        }
    }
}

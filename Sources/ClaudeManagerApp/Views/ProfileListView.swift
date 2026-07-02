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
            BadgeChip(label: managed.profile.label, color: managed.profile.color, height: 22)
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
                StatusDot(isRunning: managed.isRunning)
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
            }
            Divider()
            Button("Reveal Profile Data in Finder") { model.revealProfileData(managed.profile) }
            Button("Reveal Launcher in Finder") { model.revealLauncher(managed.profile) }
        }
    }
}

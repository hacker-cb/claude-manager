import ClaudeManagerCore
import SwiftUI

struct ProfileListView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selection: ProfileEntry.ID?

    var body: some View {
        List(selection: $selection) {
            ForEach(model.profileEntries) { entry in
                ProfileEntryRow(entry: entry)
                    .tag(entry.id)
            }
            // The default-profile row keeps the list from ever being empty, so the
            // "create a launcher" nudge is an inline, non-selectable hint below it rather
            // than a full-list overlay that would float over the default row.
            if model.profiles.isEmpty, model.realClaude != nil {
                Text("Create a launcher to run another Claude profile side by side.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
                    .listRowBackground(Color.clear)
            }
        }
    }
}

/// Dispatches a `ProfileEntry` row to its presentation: the default profile gets a reduced,
/// non-editable row; a clone keeps the full `ProfileRow`.
struct ProfileEntryRow: View {
    let entry: ProfileEntry

    var body: some View {
        switch entry {
        case let .primary(status):
            PrimaryProfileRow(status: status)
        case let .clone(managed):
            ProfileRow(managed: managed)
        }
    }
}

/// The default profile as a sidebar row — a peer of `ProfileRow` but without a badge, disk
/// size, or edit/rebuild affordances, since the untouched real app has no launcher to manage.
struct PrimaryProfileRow: View {
    @EnvironmentObject private var model: AppModel
    let status: PrimaryProfileStatus

    var body: some View {
        HStack(spacing: 10) {
            // Sized to the clone rows' BadgeChip (22pt tall, 44pt-wide column) so every
            // profile row is the same height and the leading marks line up vertically.
            Image(systemName: "person.crop.circle")
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text("Default profile")
                    .font(.body)
                    .lineLimit(1)
                // The Anthropic login, once usage has learned it — that is what identifies an
                // account to a person. Until then (tracking off, or no pass yet) fall back to
                // what the row can always say for itself.
                Text(model.usage(forBinding: TokenBinding.defaultID)?.identity.accountLabel
                    ?? "Your primary Claude — no launcher")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                StatusDot(isRunning: status.isRunning)
                UsageSidebarIndicator(usage: model.usage(forBinding: TokenBinding.defaultID))
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button(status.isRunning ? "Activate" : "Open") { Task { await model.openReal() } }
                .disabled(model.isApplyingStagedUpdate)
            if status.isRunning {
                Button("Stop") { Task { await model.stopDefaultProfile(force: false) } }
            }
            Divider()
            Button("Reveal Claude.app in Finder") { model.revealRealClaude() }
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
                // The login this launcher holds, not where its data lives: launcher names are
                // whatever the user typed, so the email is the thing that says *which account*
                // this row is. The path stays as the fallback — and in the detail pane, which
                // is where you go when you actually want the directory.
                Text(model.usage(forBinding: managed.profile.id)?.identity.accountLabel
                    ?? PathUtils.abbreviatingHome(managed.profile.profilePath))
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
                    // Two different messages behind one badge: an unsigned launcher does
                    // not start at all (macOS refuses it), so it must not read as the
                    // optional "update available" nudge a merely-dated one gets.
                    if managed.isUnrunnable {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .help("Won't launch — this launcher is unsigned. Rebuild it to fix.")
                    } else if managed.needsRebuild {
                        Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help("Update available — rebuild the launcher")
                    }
                    StatusDot(isRunning: managed.isRunning)
                }
                UsageSidebarIndicator(usage: model.usage(forBinding: managed.profile.id))
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

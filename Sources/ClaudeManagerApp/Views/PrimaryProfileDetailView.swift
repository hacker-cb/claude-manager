import ClaudeManagerCore
import SwiftUI

/// Detail pane for the default profile — the untouched real Claude run without a launcher.
/// A peer of `ProfileDetailView`, but deliberately reduced: the default profile has no
/// launcher to edit, rebuild, or remove, and its updates are owned by Claude's own updater.
struct PrimaryProfileDetailView: View {
    @EnvironmentObject private var model: AppModel

    private var status: PrimaryProfileStatus? {
        model.primaryProfile
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
        .navigationTitle("Default profile")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            // 88×88 to match the clone pane's BadgePreview, so both detail headers are the
            // same height and their titles / status lines line up.
            Image(systemName: "person.crop.circle")
                .resizable()
                .scaledToFit()
                .frame(width: 88, height: 88)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("Default profile").font(.title2).bold()
                HStack(spacing: 8) {
                    StatusDot(isRunning: status?.isRunning ?? false)
                    Text(runningLabel).foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            Spacer()
        }
    }

    private var runningLabel: String {
        guard let status, status.isRunning else { return "Stopped" }
        return "Running (pid \(status.pid.map(String.init) ?? "?"))"
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                Task { await model.openReal() }
            } label: {
                Label(status?.isRunning == true ? "Activate" : "Open", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isApplyingStagedUpdate)

            if status?.isRunning == true {
                Button { Task { await model.stopDefaultProfile(force: false) } } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                Button { Task { await model.stopDefaultProfile(force: true) } } label: {
                    Label("Force", systemImage: "bolt.fill")
                }
            }

            Spacer()
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Text("Version")
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Text(model.realClaudeVersion ?? "unknown")
                        .textSelection(.enabled)
                }
                GridRow {
                    Text("Location")
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    HStack(spacing: 6) {
                        Text(PathUtils.abbreviatingHome(model.realClaude?.appURL.path ?? "—"))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if model.realClaude != nil {
                            Button { model.revealRealClaude() } label: {
                                Image(systemName: "arrow.right.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Reveal in Finder")
                        }
                    }
                }
            }
            Text("This is your primary Claude profile, launched without a Claude Manager "
                + "launcher. Its updates are managed by Claude's own updater — there's nothing "
                + "to edit or rebuild here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

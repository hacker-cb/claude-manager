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

/// The one sidebar row layout, shared by the default profile and every clone — which used to be
/// two literal `HStack`s free to drift apart. Everything that differs between them is a parameter;
/// what's left is the geometry, and geometry is exactly the part that has to agree across rows.
///
/// Three columns, all rigid: a 44pt leading mark carrying presence, a flexible identity column
/// that truncates, and one fixed-width usage cell. Nothing conditional sits *between* two things
/// that must line up — the launcher flag rides after a truncating title, where it can never
/// disturb the figures on the right. The trailing side used to be a `VStack(alignment: .trailing)`
/// of a status dot, a usage block and a disk size, which agreed on their right edge and on nothing
/// else; a column has to agree on the edge the eye reads from.
struct SidebarProfileRow<Leading: View>: View {
    let name: String
    /// The Anthropic login — what actually says *which account* a row is. Absent until the first
    /// usage pass learns it.
    let account: String?
    let isRunning: Bool
    let usage: AccountUsage?
    /// nil for the default profile, which has no launcher that could be broken or out of date.
    let attention: LauncherAttention?
    @ViewBuilder let leading: Leading

    var body: some View {
        HStack(spacing: 10) {
            leading
                // Presence rides the leading mark: running is a property of the profile, not a
                // statistic, and while it sat on the trailing side there was no single column
                // there to align. Anchored to the 44pt column rather than to the badge itself —
                // a `BadgeChip` is as wide as its label, so hanging the dot off the chip would
                // put it at a different x in every row, which is the defect being fixed. The halo
                // keeps an 8pt mark legible wherever it lands: a saturated badge corner, the row
                // background, or the accent fill of a selected row.
                .frame(width: 44, alignment: .center)
                .overlay(alignment: .bottomTrailing) {
                    StatusDot(isRunning: isRunning)
                        .padding(1.5)
                        .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(name).font(.body).lineLimit(1)
                    if let attention { AttentionGlyph(attention: attention) }
                }
                if let account {
                    Text(account)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 6)
            UsageAccessory(usage: usage)
        }
        // A row with no login yet is exactly as tall as one that has it: `accountLabel` arrives
        // asynchronously on the first usage pass and disappears wholesale when tracking is turned
        // off, so without a floor the list would resize under the pointer with no user action.
        .frame(minHeight: 32)
        .padding(.vertical, 2)
        // Deliberately *not* `.accessibilityElement(children: .combine)`, tempting as one spoken
        // row is: `.help` is accessibility-backed on macOS, so combining the children discards
        // theirs and every tooltip in the row — the usage figure's reset countdown, the launcher
        // flag's explanation, running/stopped — silently stops appearing on hover. The parts stay
        // separate elements and each carries its own label.
    }
}

/// The single launcher flag a row has room for, painted from the precedence core decides
/// (`ManagedProfile.attention`). One mark, never two: an unsigned launcher that also has a Claude
/// update pending says only the thing that stops it from starting.
struct AttentionGlyph: View {
    let attention: LauncherAttention

    var body: some View {
        Image(systemName: symbol)
            .font(.caption)
            .foregroundStyle(tint)
            .help(note)
            .accessibilityLabel(note)
    }

    private var symbol: String {
        switch attention {
        case .unrunnable: "exclamationmark.triangle.fill"
        case .rebuildAvailable: "arrow.triangle.2.circlepath.circle.fill"
        case .claudeUpdate: "arrow.clockwise.circle.fill"
        }
    }

    private var tint: Color {
        switch attention {
        case .unrunnable: .red
        case .rebuildAvailable: .orange
        case .claudeUpdate: .blue
        }
    }

    /// Two different messages behind these marks: an unsigned launcher does not start at all
    /// (macOS refuses it), so it must not read as the optional "update available" nudge a merely
    /// dated one gets.
    private var note: String {
        switch attention {
        case .unrunnable: "Won't launch — this launcher is unsigned. Rebuild it to fix."
        case .rebuildAvailable: "Update available — rebuild the launcher"
        case let .claudeUpdate(version): "Claude \(version ?? "update") available — restart to update"
        }
    }
}

/// The default profile as a sidebar row — a peer of `ProfileRow` but without a badge or
/// edit/rebuild affordances, since the untouched real app has no launcher to manage.
struct PrimaryProfileRow: View {
    @EnvironmentObject private var model: AppModel
    let status: PrimaryProfileStatus

    private var usage: AccountUsage? {
        model.usage(forBinding: TokenBinding.defaultID)
    }

    var body: some View {
        SidebarProfileRow(
            name: "Default profile",
            // The Anthropic login, once usage has learned it, and nothing else. This line used to
            // fall back to a sentence about the row ("Your primary Claude — no launcher"), which
            // made the default the only row carrying a subtitle when tracking is off — reading as
            // an inconsistency rather than as help. The detail pane still explains the row.
            account: usage?.identity.accountLabel,
            isRunning: status.isRunning,
            usage: usage,
            attention: nil
        ) {
            // Sized to the clone rows' BadgeChip (22pt) so every row's leading mark lines up.
            Image(systemName: "person.crop.circle")
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
                .foregroundStyle(.secondary)
        }
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
        SidebarProfileRow(
            name: managed.profile.displayName,
            // The login this launcher holds, not where its data lives: launcher names are whatever
            // the user typed, so the email is the thing that says which account this row is. The
            // profile directory used to stand in when no login was known, but a path answers a
            // different question than the neighbouring rows' subtitles do — it lives in the detail
            // pane and the context menu, which is where you go when you actually want it.
            account: model.usage(forBinding: managed.profile.id)?.identity.accountLabel,
            isRunning: managed.isRunning,
            usage: model.usage(forBinding: managed.profile.id),
            attention: managed.attention
        ) {
            BadgeChip(
                label: managed.profile.label,
                color: managed.profile.color,
                height: 22,
                style: model.badgeStyle
            )
        }
        // No disk size here: a figure consulted about once a month held a permanent third line and
        // was the widest thing in the trailing stack. It stays in the detail pane's header.
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

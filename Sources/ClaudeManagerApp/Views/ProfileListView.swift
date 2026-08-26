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
    let isRunning: Bool
    let usage: AccountUsage?
    /// Why this binding's token couldn't be read. Needed alongside `usage` because a profile that
    /// was already signed out when the app launched never produces an account at all — see
    /// `UsageAccessory.failure`.
    let failure: TokenProviderError?
    /// Empty for the default profile, which has no launcher that could be broken or out of date.
    let attentions: [LauncherAttention]
    @ViewBuilder let leading: Leading

    /// The Anthropic login this row holds — or, where it holds none, that fact. Decided in core and
    /// shared with both detail-pane headers, which ask the same question of the same binding.
    private var subtitle: String? {
        UsagePresentation.accountLine(usage: usage, failure: failure)
    }

    var body: some View {
        HStack(spacing: 10) {
            leading
                // Presence rides the leading mark: running is a property of the profile, not a
                // statistic, and while it sat on the trailing side there was no single column
                // there to align. Anchored to the 44pt column rather than to the badge itself —
                // a `BadgeChip` is as wide as its label, so hanging the dot off the chip would
                // put it at a different x in every row, which is the defect being fixed.
                //
                // No opaque disc behind it, tempting as one is for legibility: the stopped state
                // is a *hollow* ring whose interior is meant to be whatever the row is painted
                // with, and filling that interior turns it back into the solid disc that means
                // running — collapsing the shape channel this row introduces and leaving green
                // vs grey as the only difference again.
                .frame(width: 44, alignment: .center)
                .overlay(alignment: .bottomTrailing) { StatusDot(isRunning: isRunning) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(name).font(.body).lineLimit(1)
                    ForEach(attentions, id: \.self) { AttentionGlyph(attention: $0) }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 6)
            UsageAccessory(usage: usage, failure: failure)
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

/// One launcher flag, painted from the marks core decides (`ManagedProfile.attentions`).
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
        case .claudeUpdate, .restartToApply: "arrow.clockwise.circle.fill"
        }
    }

    /// Red and amber survive a selected row; blue does not — the selection fill *is* the accent
    /// colour, so an informational blue glyph on the row the user just clicked is blue on blue.
    /// The restart nudge takes a hierarchical style instead, for the same reason `UsageAccessory`
    /// refuses `.accentColor` one column over; the glyph's own shape carries which mark it is.
    private var tint: AnyShapeStyle {
        switch attention {
        case .unrunnable: AnyShapeStyle(Color.red)
        case .rebuildAvailable: AnyShapeStyle(Color.orange)
        case .claudeUpdate, .restartToApply: AnyShapeStyle(.secondary)
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
        case .restartToApply: "Rewritten while open — restart to apply the new name and icon"
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
            isRunning: status.isRunning,
            usage: usage,
            failure: model.usageFailure(forBinding: TokenBinding.defaultID),
            attentions: []
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
                .disabled(model.claudeUpdateState.isBusy)
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
            // The login this launcher holds, not where its data lives: launcher names are whatever
            // the user typed, so the email is the thing that says which account this row is. The
            // profile directory used to stand in when no login was known, but a path answers a
            // different question than the neighbouring rows' subtitles do — it lives in the detail
            // pane and the context menu, which is where you go when you actually want it.
            name: managed.profile.displayName,
            isRunning: managed.isRunning,
            usage: model.usage(forBinding: managed.profile.id),
            failure: model.usageFailure(forBinding: managed.profile.id),
            // The restart nudge is app-held state (a pid observed at write time), so it is
            // appended here rather than decided in `attentions`. Without it the mark lives
            // only in the detail pane, and after a batch rebuild the user would have to open
            // every profile in turn to find which ones were rewritten live.
            attentions: managed.attentions
                + (model.needsRestartToApply(managed) ? [.restartToApply] : [])
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
            Divider()
            Button("Reveal Profile Data in Finder") { model.revealProfileData(managed.profile) }
            Button("Reveal Launcher in Finder") { model.revealLauncher(managed.profile) }
        }
    }
}

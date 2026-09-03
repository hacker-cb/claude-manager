import ClaudeManagerCore
import SwiftUI

/// The Limits page — the window's first row and the one it opens on.
///
/// It answers one question, "where should work go now", and everything on it is that answer at a
/// different resolution: the cards say who, the timeline says why and for how long, the list says
/// what the rest of the fleet looks like. The decision itself is `UsageOverview`'s, in the core;
/// this paints it.
struct LimitsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if !model.usageTrackingEnabled {
                trackingOff
            } else if model.limitsAccounts.isEmpty {
                nothingRead
            } else {
                // One ticker for the page, as the detail pane does: every relative time on it —
                // "resets in 3d 12h", "updated 4 min ago" — is derived from `now` at render, and
                // without this they freeze at whatever the last usage pass drew.
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    board(now: context.date)
                }
            }
        }
        .navigationTitle("Limits")
        // Keyed on the master switch, not fired once. Turning tracking on while this page is
        // already the visible one otherwise left every lane empty: a plain `.task` does not re-run
        // for a state change, and under "Manually only" no poll follows to fill it either — so
        // the history sat in `usage.db` unread until the user navigated away and back.
        .task(id: model.usageTrackingEnabled) {
            // The page owns the first load: the poll fills this in afterwards, but a window
            // opened between two ticks would otherwise draw an empty timeline for half an hour.
            await model.loadLimitsSeries()
        }
    }

    private func board(now: Date) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(now: now)
                LimitsAnswerCards(now: now)
                Divider()
                LimitsTimeline(now: now)
                Divider()
                LimitsAccountList(now: now)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Header

    private func header(now: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Where to work now").font(.title2).bold()
            if let age = freshness(now: now) {
                Text(age).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            // Only where the two modes can actually differ. On a plan reporting no per-model
            // window they count the same windows, and a toggle between two identical answers is
            // a control that does nothing.
            if model.limitsHasScopedWindows {
                Picker("Work", selection: $model.limitsMode) {
                    ForEach(WorkMode.allCases, id: \.self) { mode in
                        Text(model.limitsModeLabel(mode)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Button {
                Task { await model.refreshUsage(interactive: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(model.isRefreshingUsage)
            .help("Refresh usage")
        }
    }

    /// How old the figures behind the answer are — the oldest of them, since the page speaks for
    /// the fleet and a single stale account is what would make its ranking wrong.
    ///
    /// Only accounts the ranking actually reads. A signed-out profile keeps its last snapshot
    /// indefinitely and `assess` answers before ever looking at it, so counting those made the
    /// header say "as of 3 weeks ago" over figures every ranked account had refreshed a minute
    /// earlier.
    private func freshness(now: Date) -> String? {
        let captured = model.limitsAccounts
            .filter { $0.state == .fresh }
            .compactMap(\.snapshot?.capturedAt)
        guard let oldest = captured.min() else { return nil }
        return "as of \(UsageFormat.age(oldest, now: now))"
    }

    // MARK: - Empty states

    private var trackingOff: some View {
        ContentUnavailableView {
            Label("Usage tracking is off", systemImage: "chart.bar.xaxis")
        } description: {
            Text("Turn on Settings → Usage → Track plan usage to see which profile to work in.")
        } actions: {
            SettingsLink { Text("Open Settings") }
        }
    }

    /// Nothing to rank. Two very different reasons land here, and only one of them is fixed by
    /// the button: a fleet that has simply not been read yet, and one where every profile is
    /// signed out or has never been opened. Telling the second to Refresh sends them back to this
    /// same screen, so it says what actually needs doing instead.
    @ViewBuilder
    private var nothingRead: some View {
        let blocking = model.limitsBlockingFailures
        ContentUnavailableView {
            Label(
                blocking.isEmpty ? "No usage read yet" : "No account to rank",
                systemImage: "chart.bar.xaxis"
            )
        } description: {
            if blocking.isEmpty {
                Text("Refresh to fetch each profile's plan usage.")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(blocking, id: \.self) { Text($0) }
                }
            }
        } actions: {
            Button("Refresh") { Task { await model.refreshUsage(interactive: true) } }
                .disabled(model.isRefreshingUsage)
        }
    }
}

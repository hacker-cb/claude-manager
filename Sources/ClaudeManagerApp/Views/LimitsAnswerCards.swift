import ClaudeManagerCore
import SwiftUI

/// The answer, one card per mode — and the card is where the page stops being a report and
/// becomes something you can act on: it carries the button that opens the profile it names.
///
/// Both cards are always shown where the modes can differ, rather than only the selected one. The
/// question "and what about my other work?" is the one a single card provokes, and answering it
/// by making someone toggle back and forth costs more room than showing both.
struct LimitsAnswerCards: View {
    @EnvironmentObject private var model: AppModel
    let now: Date

    var body: some View {
        if model.limitsHasScopedWindows {
            HStack(alignment: .top, spacing: 12) {
                ForEach(WorkMode.allCases, id: \.self) { mode in
                    LimitsAnswerCard(mode: mode, now: now)
                }
            }
        } else {
            LimitsAnswerCard(mode: model.limitsMode, now: now)
        }
    }
}

/// One mode's answer: who to work in, why, and who follows.
struct LimitsAnswerCard: View {
    @EnvironmentObject private var model: AppModel
    let mode: WorkMode
    let now: Date

    private var overview: UsageOverview {
        model.limitsOverview(mode: mode, now: now)
    }

    private var isSelected: Bool {
        model.limitsMode == mode
    }

    var body: some View {
        let overview = overview
        VStack(alignment: .leading, spacing: 8) {
            Text(model.limitsModeLabel(mode).uppercased())
                .font(.caption2).bold()
                .foregroundStyle(.secondary)
            if let leader = overview.leader {
                answer(leader)
            } else {
                noAnswer(overview)
            }
            let rest = chain(overview)
            if !rest.isEmpty {
                Text(rest).font(.caption).foregroundStyle(.tertiary).lineLimit(2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.25))
        )
        // The card is the affordance for its own mode: reading one and then hunting for the
        // toggle to act on it is a step the card can absorb.
        .contentShape(Rectangle())
        .onTapGesture { model.limitsMode = mode }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(model.limitsModeLabel(mode)): \(answerSummary(overview))")
    }

    // MARK: - With an answer

    private func answer(_ leader: UsageCandidate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(model.limitsAccountName(leader.account))
                    .font(.title3).bold()
                    .lineLimit(1)
                Spacer(minLength: 8)
                openButtons(for: leader)
            }
            Text(UsageOverview.reason(for: leader, now: now))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One button for a login with one profile; a menu for a login several launchers share, since
    /// the account is the thing being recommended and only the person knows which window they
    /// want it in.
    @ViewBuilder
    private func openButtons(for leader: UsageCandidate) -> some View {
        let entries = model.limitsProfiles(of: leader.account)
        if entries.count == 1, let entry = entries.first {
            Button(verb(entry)) { open(entry) }
                .disabled(model.claudeUpdateState.blocksProfileActivity)
        } else if entries.count > 1 {
            Menu("Open") {
                ForEach(entries) { entry in
                    Button("\(name(entry)) — \(verb(entry).lowercased())") { open(entry) }
                }
            }
            .fixedSize()
            .disabled(model.claudeUpdateState.blocksProfileActivity)
        } else {
            // The default account keeps its place in the ranking while Claude.app cannot be
            // located — during an update's bundle swap, or after the app is moved — but its
            // sidebar row is gone, so there is nothing to open. Say that, rather than printing a
            // recommendation beside empty space.
            Text("unavailable").font(.caption).foregroundStyle(.tertiary)
                .help("Claude.app was not found, so this profile cannot be opened right now.")
        }
    }

    // MARK: - Without one

    /// Nil is a real answer, and this is where it is said out loud rather than dressed up as the
    /// least-bad row: the fleet is gated, stale or signed out, and the useful thing left to say
    /// is when any of it comes back.
    private func noAnswer(_ overview: UsageOverview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nobody right now").font(.title3).bold().foregroundStyle(.secondary)
            Text(returnNote(overview))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func returnNote(_ overview: UsageOverview) -> String {
        guard let soonest = overview.soonestReturn else {
            return "No profile can be recommended from what has been read."
        }
        let who = overview.candidates
            .first { $0.freesAt == soonest }
            .map { model.limitsAccountName($0.account) }
        let clock = UsageFormat.compactDuration(soonest.timeIntervalSince(now))
        guard let who else { return "The first window frees in \(clock)." }
        return "\(who) frees first, in \(clock)."
    }

    // MARK: - The rest of the fleet

    /// The order after the leader, as names — the "and then?" the card would otherwise provoke.
    ///
    /// Only accounts work could actually go to. Listing the ranking's tail unfiltered put "then
    /// Alice → Bob" directly beneath "Nobody right now", offering three addresses one line after
    /// saying there were none — and named signed-out and exhausted accounts as the next option
    /// even when there was a leader.
    private func chain(_ overview: UsageOverview) -> String {
        let names = overview.candidates
            .filter(\.canLead)
            .dropFirst(overview.leader == nil ? 0 : 1)
            .prefix(3)
            .map { model.limitsAccountName($0.account) }
        guard !names.isEmpty else { return "" }
        return "then \(names.joined(separator: " → "))"
    }

    private func answerSummary(_ overview: UsageOverview) -> String {
        guard let leader = overview.leader else { return returnNote(overview) }
        return "\(model.limitsAccountName(leader.account)), \(UsageOverview.reason(for: leader, now: now))"
    }

    // MARK: - Acting on it

    private func name(_ entry: ProfileEntry) -> String {
        switch entry {
        case .primary: "Default profile"
        case let .clone(managed): managed.profile.displayName
        }
    }

    private func verb(_ entry: ProfileEntry) -> String {
        switch entry {
        case let .primary(status): status.isRunning ? "Activate" : "Open"
        case let .clone(managed): managed.isRunning ? "Activate" : "Open"
        }
    }

    private func open(_ entry: ProfileEntry) {
        switch entry {
        case .primary: Task { await model.openReal() }
        case let .clone(managed): Task { await model.open(managed.profile) }
        }
    }
}

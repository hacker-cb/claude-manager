import ClaudeManagerCore
import SwiftUI

/// The fleet in ranked order, with every window it has.
///
/// The order *is* the answer — the same ranking the cards read their leader from — so this is the
/// place someone checks the recommendation rather than takes it on trust: the bars beside each row
/// are what the decision was made from.
struct LimitsAccountList: View {
    @EnvironmentObject private var model: AppModel
    let now: Date

    /// Minimums that fit the narrowest window the app supports. At its 760pt floor the 240pt
    /// sidebar and 48pt of page padding leave roughly 470pt here, and the previous set already
    /// totalled 510 before spacing — so the last column was clipped, inside a `ScrollView` that
    /// only scrolls vertically and could not reach it. These total 364, which leaves room for the
    /// conditional sixth below.
    private let columns = [
        GridItem(.flexible(minimum: 104), alignment: .topLeading),
        GridItem(.flexible(minimum: 62), alignment: .topLeading),
        GridItem(.flexible(minimum: 62), alignment: .topLeading),
        GridItem(.flexible(minimum: 62), alignment: .topLeading),
        GridItem(.flexible(minimum: 74), alignment: .topLeading)
    ]

    /// A window Anthropic has started reporting that this build has no column for.
    ///
    /// The ranking counts every limit in a snapshot, known kind or not, so an unrecognised one
    /// can be exactly what gates an account — and the list whose whole job is to expose the
    /// decision's inputs was the one place it could not be seen. The column appears only when
    /// there is something to put in it, which on today's payloads is never.
    private let otherColumn = GridItem(.flexible(minimum: 62), alignment: .topLeading)

    var body: some View {
        let rows = model.limitsOverview(mode: model.limitsMode, now: now).candidates
        let showsOther = rows.contains { !($0.account.snapshot?.otherLimits ?? []).isEmpty }
        VStack(alignment: .leading, spacing: 10) {
            Text("Every account").font(.headline)
            LazyVGrid(
                columns: showsOther ? columns + [otherColumn] : columns,
                alignment: .leading,
                spacing: 12
            ) {
                heading("Account")
                heading("Session, 5h")
                heading("Week, all models")
                heading("Week, per-model")
                if showsOther { heading("Other") }
                heading("Week resets")
                ForEach(rows) { row in
                    let retained = row.account.state != .fresh
                    account(row)
                    window(row.account.snapshot?.session, counted: true, retained: retained)
                    window(row.account.snapshot?.weeklyAll, counted: true, retained: retained)
                    scoped(row, retained: retained)
                    if showsOther { others(row, retained: retained) }
                    resets(row)
                }
            }
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
    }

    // MARK: - Who

    private func account(_ row: UsageCandidate) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(model.limitsAccountName(row.account))
                .font(.callout).bold()
                .lineLimit(1)
            Text(UsageOverview.stateLabel(for: row, now: now))
                .font(.caption2)
                .foregroundStyle(row.canLead ? Color.accentColor : .secondary)
            // An account waiting on a person keeps its last snapshot indefinitely, and this row
            // draws that snapshot's bars — while the header's age deliberately skips it, because
            // the ranking never reads it. So the figures beside "Needs you" had no date on them
            // anywhere. Every other state says its own age; this is the one that could not.
            if let age = retainedAge(row) {
                Text(age).font(.caption2).foregroundStyle(.tertiary)
            }
            // Every profile on this login, so a shared account says which windows it means.
            if row.account.bindingIDs.count > 1 {
                Text("shared with \(row.account.bindingIDs.count) profiles")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Windows

    /// One window as a bar plus its figure. `counted: false` dims the column rather than hiding
    /// it — the row stays the same shape in both modes, and a window that is simply not being
    /// counted right now is still a fact about the account.
    /// The age of figures whose chip does not already carry it.
    ///
    /// Every state that retains a snapshot indefinitely needs this, not just the ones waiting on
    /// a person: `.offline` and `.rateLimited` print their condition and no age at all, and this
    /// row draws their bars at whatever they last said. `.stale` is the exception — its chip *is*
    /// "As of 3h ago" — and repeating that directly beneath it says one thing twice.
    private func retainedAge(_ row: UsageCandidate) -> String? {
        switch row.account.state {
        case .fresh, .stale: return nil
        case .loginNeeded, .noSource, .offline, .rateLimited:
            guard let capturedAt = row.account.snapshot?.capturedAt else { return nil }
            return "figures as of \(UsageFormat.age(capturedAt, now: now))"
        }
    }

    @ViewBuilder
    private func window(_ limit: UsageLimit?, counted: Bool, retained: Bool = false) -> some View {
        if let limit {
            let cell = VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(UsageFormat.percent(limit.utilization))
                        .font(.caption).bold().monospacedDigit()
                    Text(limit.shortLabel).font(.caption2).foregroundStyle(.secondary)
                }
                UsageBar(fraction: limit.utilization, height: 5, level: limit.displaySeverity)
            }
            .opacity(counted ? (retained ? 0.55 : 1) : 0.4)
            // Branched rather than passed an empty string: `.help("")` attaches a tooltip with
            // nothing in it to the great majority of these cells.
            if let help = helpText(counted: counted, retained: retained) {
                cell.help(help)
            } else {
                cell
            }
        } else {
            Text("—").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func helpText(counted: Bool, retained: Bool) -> String? {
        guard counted else { return "Not counted for \(model.limitsModeLabel(model.limitsMode))" }
        return retained ? "The last figures read before this account stopped reporting." : nil
    }

    @ViewBuilder
    private func stack(_ windows: [UsageLimit], counted: Bool, retained: Bool) -> some View {
        if windows.isEmpty {
            Text("—").font(.caption).foregroundStyle(.tertiary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(windows.enumerated()), id: \.offset) { _, limit in
                    window(limit, counted: counted, retained: retained)
                }
            }
        }
    }

    private func scoped(_ row: UsageCandidate, retained: Bool) -> some View {
        stack(
            row.account.snapshot?.weeklyScoped ?? [],
            counted: model.limitsMode == .scopedModel,
            retained: retained
        )
    }

    /// Always counted: `countedLimits` filters the snapshot's whole list, and an unknown kind is
    /// neither weekly-scoped nor excluded by either mode.
    private func others(_ row: UsageCandidate, retained: Bool) -> some View {
        stack(row.account.snapshot?.otherLimits ?? [], counted: true, retained: retained)
    }

    // MARK: - When

    /// The clock time under the countdown — but only where there is one to give.
    ///
    /// `UsageFormat.resets` spells an absolute time beyond a day and returns a *relative* phrase
    /// under it, which stripped of its "resets " prefix read as a word-for-word repeat of the
    /// countdown directly above it.
    private func absoluteReset(_ resetsAt: Date) -> String? {
        guard resetsAt.timeIntervalSince(now) >= 24 * 3600 else { return nil }
        return UsageFormat.resets(resetsAt, now: now)?
            .replacingOccurrences(of: "resets ", with: "")
    }

    /// The weekly reset an account still has on record when the ranking never got as far as
    /// reading one.
    ///
    /// `weeklyResetsAt` is nil by construction for a candidate that needs a person or has no
    /// figures at all — `assess` answers before it looks at the snapshot. But a profile signed
    /// out an hour ago keeps a retained snapshot whose weekly window carries a perfectly good
    /// date three days out, and this is the one surface whose stated job is to expose the
    /// decision's inputs. Dimmed, because nothing measured against it.
    private func retainedReset(_ row: UsageCandidate) -> Date? {
        guard row.weeklyResetsAt == nil,
              let resetsAt = row.account.snapshot?.weeklyAll?.resetsAt, resetsAt > now
        else { return nil }
        return resetsAt
    }

    private func countdown(_ resetsAt: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("in \(UsageFormat.compactDuration(resetsAt.timeIntervalSince(now)))")
                .font(.caption).bold().monospacedDigit()
            if let absolute = absoluteReset(resetsAt) {
                Text(absolute).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func resets(_ row: UsageCandidate) -> some View {
        // The clock the ranking actually measured against, not a window's own field — the two
        // can differ, and showing the other one would explain a pace nobody computed.
        if let resetsAt = row.weeklyResetsAt, resetsAt > now {
            countdown(resetsAt)
        } else if let retained = retainedReset(row) {
            countdown(retained)
                .opacity(0.55)
                .help("From the last figures read. Nothing was measured against this.")
        } else {
            // The tooltip used to say a reset had not been reported, which is only one of the two
            // ways to arrive here — and the wrong one for an account whose snapshot the ranking
            // declined to read at all.
            Text("unknown").font(.caption).foregroundStyle(.tertiary)
                .help(
                    row.account.snapshot == nil
                        ? "Nothing has been read for this account yet."
                        : "No weekly reset still ahead was reported for this account."
                )
        }
    }
}

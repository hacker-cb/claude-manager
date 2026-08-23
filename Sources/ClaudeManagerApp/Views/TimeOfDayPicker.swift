import SwiftUI

/// Picks a time of day, stored as **minutes since midnight**.
///
/// `DatePicker` is the native control for this, and it works on a `Date` — which for a
/// time-of-day is a wrong type carrying a date nobody set. Binding through minutes keeps the
/// stored preference legible (`defaults read` shows `240`, not a timestamp from whichever day
/// the user happened to open Settings) and keeps the window free of any date at all: it
/// repeats daily, so a stored day would be misleading the moment it passed.
struct TimeOfDayPicker: View {
    @Binding var minutes: Int

    var body: some View {
        DatePicker(
            "",
            selection: Binding(
                get: { Self.date(fromMinutes: minutes) },
                set: { minutes = Self.minutes(from: $0) }
            ),
            displayedComponents: .hourAndMinute
        )
        .labelsHidden()
        .datePickerStyle(.field)
    }

    /// A reference day carries the time — any day will do, since only the time is read back.
    ///
    /// Built from **hour/minute components**, not by adding elapsed minutes to midnight: on a
    /// DST transition day those differ. Adding 240 minutes to midnight lands on 05:00 rather
    /// than 04:00 across a spring-forward, so the picker would show a window the user never
    /// set — and persist the shifted value the moment they touched it.
    private static func date(fromMinutes minutes: Int) -> Date {
        let calendar = Calendar.current
        let hour = minutes / 60
        let minute = minutes % 60
        // Find a day on which this time actually exists. On a spring-forward day the skipped
        // hour has no representation, and `Calendar.date(from:)` does not return nil for it —
        // it *normalises* 02:30 to 03:30, so a naive fallback never runs and the picker shows
        // (then persists) an hour the user never chose. Checking that the components round-trip
        // is what catches that; a DST shift happens twice a year, so the next day always works.
        for dayOffset in 0 ... 2 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: Date()) else { continue }
            var components = calendar.dateComponents([.year, .month, .day], from: day)
            components.hour = hour
            components.minute = minute
            guard let candidate = calendar.date(from: components) else { continue }
            let readBack = calendar.dateComponents([.hour, .minute], from: candidate)
            if readBack.hour == hour, readBack.minute == minute { return candidate }
        }
        return calendar.startOfDay(for: Date())
    }

    private static func minutes(from date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}

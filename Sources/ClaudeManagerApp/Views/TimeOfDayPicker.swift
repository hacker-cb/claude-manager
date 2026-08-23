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
        var components = calendar.dateComponents([.year, .month, .day], from: Date())
        components.hour = minutes / 60
        components.minute = minutes % 60
        // A time that doesn't exist on this date (the skipped hour) has no representation;
        // midnight is the honest fallback rather than a silently shifted one.
        return calendar.date(from: components) ?? calendar.startOfDay(for: Date())
    }

    private static func minutes(from date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}

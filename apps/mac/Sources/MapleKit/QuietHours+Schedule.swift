import Foundation

/// Quiet hours (MF-224): when someone's own weekly schedule silences notifications on every device.
/// The same logic as the server's quiet-hours.ts and the web app's, checked against the same cases
/// (protocol/quiet-hours-cases.json). Each window starts on its `days` (0 Sunday) at `start` minutes
/// after midnight in the schedule's time zone; an `end` at or before `start` runs into the next day.
extension Wire.QuietHours {
    /// Whether `date` falls inside one of the windows.
    public func isQuiet(at date: Date) -> Bool {
        guard !windows.isEmpty, let zone = TimeZone(identifier: timeZone) else { return false }
        let here = Self.wallClock(zone, date)
        return Self.minutesLeft(windows, day: here.day, minute: here.minute) > 0
    }

    /// When the quiet that covers `date` ends, following windows that run straight into one another;
    /// nil when it isn't quiet. Across a DST change it's the real moment the wall clock reads the end.
    public func quietUntil(_ date: Date) -> Date? {
        guard !windows.isEmpty, let zone = TimeZone(identifier: timeZone) else { return nil }
        var at = date.timeIntervalSince1970
        for hop in 0..<16 {
            let here = Self.wallClock(zone, Date(timeIntervalSince1970: at))
            let left = Self.minutesLeft(windows, day: here.day, minute: here.minute)
            if left == 0 { return hop == 0 ? nil : Date(timeIntervalSince1970: at) }
            let wallEnd = (at / 60).rounded(.down) * 60 + Double(left * 60)
            var end = wallEnd
            for _ in 0..<2 {
                let offset = zone.secondsFromGMT(for: Date(timeIntervalSince1970: end))
                end = wallEnd - Double(offset - here.offset)
            }
            at = max(end, at + 60)
        }
        return Date(timeIntervalSince1970: at) // Quiet around the clock: the furthest we looked.
    }

    private static func wallClock(_ zone: TimeZone, _ date: Date) -> (day: Int, minute: Int, offset: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        return ((parts.weekday ?? 1) - 1, (parts.hour ?? 0) * 60 + (parts.minute ?? 0), zone.secondsFromGMT(for: date))
    }

    /// Wall-clock minutes left in the windows that cover `day`/`minute`: the longest, or 0 when none does.
    private static func minutesLeft(_ windows: [Wire.QuietWindow], day: Int, minute: Int) -> Int {
        var left = 0
        let yesterday = (day + 6) % 7
        for window in windows {
            let start = Int(window.start), end = Int(window.end)
            let days = Set(window.days.map(Int.init))
            if end > start {
                if days.contains(day), minute >= start, minute < end { left = max(left, end - minute) }
            } else {
                if days.contains(day), minute >= start { left = max(left, 1440 - minute + end) }
                if days.contains(yesterday), minute < end { left = max(left, end - minute) }
            }
        }
        return left
    }
}

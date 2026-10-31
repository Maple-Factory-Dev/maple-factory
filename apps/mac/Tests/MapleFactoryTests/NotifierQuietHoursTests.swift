import Foundation
import Testing
import MapleKit
@testable import MapleFactory

/// Quiet hours (MF-224): the Mac's banners are off inside a window and on outside it.
@MainActor struct NotifierQuietHoursTests {
    /// Weeknights 22:00–07:00 and weekdays 09:00–17:00, in Toronto.
    static let schedule = Wire.QuietHours(timeZone: "America/Toronto", windows: [
        .init(days: [0, 1, 2, 3, 4], start: 22 * 60, end: 7 * 60),
        .init(days: [1, 2, 3, 4, 5], start: 9 * 60, end: 17 * 60),
    ])
    private static func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    private func withNotifier(_ body: (Notifier) -> Void) {
        let notifier = Notifier()
        let (enabled, snoozed) = (notifier.enabled, notifier.snoozedUntil)
        defer { notifier.enabled = enabled; notifier.snoozedUntil = snoozed; notifier.quietHours = nil }
        notifier.enabled = true
        notifier.snoozedUntil = nil
        body(notifier)
    }

    @Test func offInsideAWindowOnOutside() {
        withNotifier { notifier in
            notifier.quietHours = Self.schedule
            #expect(!notifier.isOn(at: Self.date("2026-10-28T16:00:00Z"))) // Wed noon: work hours
            #expect(!notifier.isOn(at: Self.date("2026-10-29T03:00:00Z"))) // Wed 11 PM: a weeknight
            #expect(notifier.isOn(at: Self.date("2026-10-28T22:00:00Z"))) // Wed 6 PM: between
            #expect(notifier.isOn(at: Self.date("2026-10-31T16:00:00Z"))) // Sat noon: the weekend
        }
    }

    @Test func noScheduleNeverQuiet() {
        withNotifier { notifier in
            #expect(notifier.isOn(at: Self.date("2026-10-29T03:00:00Z")))
            #expect(notifier.quietUntil == nil)
        }
    }

    @Test func statusSaysUntilWhen() {
        withNotifier { notifier in
            // Quiet around the clock, so whenever the test runs the bell says when it ends.
            notifier.quietHours = .init(timeZone: "UTC", windows: [.init(days: [0, 1, 2, 3, 4, 5, 6], start: 0, end: 1439),
                                                                  .init(days: [0, 1, 2, 3, 4, 5, 6], start: 1439, end: 0)])
            #expect(!notifier.isOn)
            #expect(notifier.bellIcon == "bell.slash")
            #expect(notifier.statusText.hasPrefix("Quiet hours until "))
            notifier.quietHours = nil
            #expect(notifier.isOn)
            #expect(notifier.statusText == "Notifications on")
        }
    }
}

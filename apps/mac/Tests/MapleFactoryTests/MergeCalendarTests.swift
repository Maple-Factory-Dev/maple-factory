import Foundation
import MapleKit
import Testing
@testable import MapleFactory

/// MF-343: the year-of-merges calendar's weeks, shades, streaks and month labels.
struct MergeCalendarTests {
    private static let cal = MergeCalendarModel.calendar

    /// `counts` from `start` on, one per day.
    private func days(from start: String, _ counts: [Int]) -> [Wire.StatsCalendarDay] {
        let f = DateFormatter()
        f.calendar = Self.cal
        f.timeZone = Self.cal.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let first = f.date(from: start)!
        return counts.enumerated().map { i, n in .init(day: f.string(from: Self.cal.date(byAdding: .day, value: i, to: first)!), merges: UInt32(n)) }
    }

    @Test func weeksRunSundayToSaturdayWithTodayLast() {
        // 2025-11-02 is a Sunday; 365 days run to Sunday 2026-11-01: 52 whole weeks and a one-day week.
        let m = MergeCalendarModel(days(from: "2025-11-02", Array(repeating: 0, count: 365)))
        #expect(m.weeks.count == 53)
        #expect(m.weeks.allSatisfy { $0.count == 7 })
        #expect(m.weeks[0][0]?.day == "2025-11-02")
        #expect(m.weeks[0][6]?.day == "2025-11-08")
        #expect(m.weeks[52][0]?.day == "2026-11-01")
        #expect(m.weeks[52][1...].allSatisfy { $0 == nil })
    }

    @Test func aMidweekStartIsPaddedSoRowsStayWeekdays() {
        let m = MergeCalendarModel(days(from: "2026-10-28", [1, 2, 3])) // Wed, Thu, Fri
        #expect(m.weeks.count == 1)
        #expect(m.weeks[0][0...2].allSatisfy { $0 == nil })
        #expect(m.weeks[0][3]?.day == "2026-10-28")
        #expect(m.weeks[0][5]?.merges == 3)
    }

    @Test func anAllZeroYearIsBlank() {
        let m = MergeCalendarModel(days(from: "2025-11-02", Array(repeating: 0, count: 365)))
        #expect(m.weeks.joined().compactMap { $0 }.allSatisfy { $0.level == 0 })
        #expect(m.total == 0 && m.longestStreak == 0 && m.currentStreak == 0 && m.busiest == nil)
    }

    @Test func aSingleBusyDayGetsTheDarkestShade() {
        var counts = Array(repeating: 0, count: 365)
        counts[100] = 7
        let m = MergeCalendarModel(days(from: "2025-11-02", counts))
        let lit = m.weeks.joined().compactMap { $0 }.filter { $0.level > 0 }
        #expect(lit.count == 1 && lit[0].level == 4)
        #expect(m.busiest?.merges == 7)
        #expect(MergeCalendar.describe(lit[0]).hasPrefix("7 merges on "))
    }

    @Test func shadesScaleToTheNinetiethPercentileNotTheOutlier() {
        // Busy days 1…9 and one 50: the cap is 9, so 50 doesn't wash 1–9 out to the palest shade.
        let counts = Array(1...9) + [50]
        #expect(MergeCalendarModel.cap(counts) == 9)
        #expect(counts.map { MergeCalendarModel.level($0, cap: 9) } == [1, 1, 1, 2, 2, 2, 3, 3, 4, 4])
        #expect(MergeCalendarModel.level(0, cap: 9) == 0)
        #expect(MergeCalendarModel.level(1, cap: 1) == 1) // a year of single merges stays one shade
    }

    @Test func streaks() {
        // Longest run 4; the current run is 2 and survives today having no merge yet.
        let m = MergeCalendarModel(days(from: "2026-10-18", [1, 1, 1, 1, 0, 2, 0, 0, 1, 0, 0, 3, 1, 0]))
        #expect(m.longestStreak == 4)
        #expect(m.currentStreak == 2)
        let broken = MergeCalendarModel(days(from: "2026-10-18", [1, 1, 0, 0]))
        #expect(broken.currentStreak == 0)
        let today = MergeCalendarModel(days(from: "2026-10-18", [0, 1, 1, 1]))
        #expect(today.currentStreak == 3)
        #expect(m.total == 11)
    }

    @Test func monthLabelsSitOverTheFirstWeekStartingInTheMonth() {
        let m = MergeCalendarModel(days(from: "2025-11-02", Array(repeating: 0, count: 365)), locale: Locale(identifier: "en_US"))
        #expect(m.months.first?.name == "Nov")
        #expect(m.months.first?.week == 0)
        // Week 4 starts Sun 30 Nov; week 5 starts Sun 7 Dec: the first week that starts in December.
        #expect(m.months.first { $0.name == "Dec" }?.week == 5)
        #expect(m.months.first { $0.name == "Jan" }?.week == 9) // Sun 4 Jan 2026
        #expect(m.months.count == 12) // the November that starts in the last week is left off: it would clip
        #expect(m.months.last?.name == "Oct")
        #expect(zip(m.months, m.months.dropFirst()).allSatisfy { $1.week - $0.week >= 4 })
    }

    @Test func aMonthSqueezedInAtTheStartIsDropped() {
        // Starts Sun 26 Oct: October has one week before November's label, so it's left out.
        let m = MergeCalendarModel(days(from: "2025-10-26", Array(repeating: 0, count: 371)), locale: Locale(identifier: "en_US"))
        #expect(m.months.first?.name == "Nov")
        #expect(m.months.first?.week == 1)
    }

    @Test func theSampleIsAYearEndingToday() {
        let sample = Wire.StatsCalendarDay.sample()
        #expect((365...371).contains(sample.count))
        let m = MergeCalendarModel(sample)
        #expect(m.weeks[0][0] != nil)
        #expect(m.total > 0)
    }
}

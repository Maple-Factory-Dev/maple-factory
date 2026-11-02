import MapleKit
import SwiftUI

/// The last year's merges as a calendar (MF-343): one column per week, one row per weekday, each day
/// shaded by how busy it was. Pure, so MergeCalendarTests runs it on fixtures.
struct MergeCalendarModel: Equatable {
    struct Day: Equatable {
        let day: String
        let date: Date
        let merges: Int
        let level: Int
    }

    /// Week columns, Sunday first; a slot is nil before the first day or after today.
    let weeks: [[Day?]]
    /// The week a month's label sits over, and its short name.
    let months: [(week: Int, name: String)]
    let total: Int
    let longestStreak: Int
    let currentStreak: Int
    let busiest: Day?
    /// The count that gets the darkest shade (see `cap`).
    let cap: Int

    static func == (a: Self, b: Self) -> Bool {
        a.weeks == b.weeks && a.months.map(\.week) == b.months.map(\.week) && a.months.map(\.name) == b.months.map(\.name)
            && a.total == b.total && a.longestStreak == b.longestStreak && a.currentStreak == b.currentStreak && a.cap == b.cap
    }

    /// Days are calendar dates, so they're worked out in UTC whatever the zone they were counted in.
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init(_ days: [Wire.StatsCalendarDay], locale: Locale = .current) {
        let parsed = days.compactMap { d in Self.parser.date(from: d.day).map { (d.day, $0, Int(d.merges)) } }
        let counts = parsed.map(\.2)
        let cap = Self.cap(counts)
        self.cap = cap
        let all = parsed.map { Day(day: $0.0, date: $0.1, merges: $0.2, level: Self.level($0.2, cap: cap)) }

        var weeks: [[Day?]] = []
        if let first = all.first {
            let lead = Self.calendar.component(.weekday, from: first.date) - 1
            let slots: [Day?] = Array(repeating: nil, count: lead) + all
            weeks = stride(from: 0, to: slots.count, by: 7).map { i in
                let week = Array(slots[i..<min(i + 7, slots.count)])
                return week + Array(repeating: nil, count: 7 - week.count)
            }
        }
        self.weeks = weeks

        // A month's label goes over the first week that starts in it; one squeezed in at the very
        // start (under three weeks before the next) or at the very end is dropped so labels never overlap or clip.
        let symbols: [String] = {
            var c = Calendar(identifier: .gregorian)
            c.locale = locale
            return c.shortMonthSymbols
        }()
        var months: [(Int, String)] = []
        var lastMonth = -1
        for (w, week) in weeks.enumerated() {
            guard let day = week.compactMap({ $0 }).first else { continue }
            let month = Self.calendar.component(.month, from: day.date)
            if month != lastMonth {
                months.append((w, symbols[month - 1]))
                lastMonth = month
            }
        }
        if months.count > 1, months[1].0 - months[0].0 < 3 { months.removeFirst() }
        // Likewise a month that only just started in the last week or two: its label would run off the end.
        if months.count > 1, let last = months.last, weeks.count - last.0 < 3 { months.removeLast() }
        self.months = months.map { (week: $0.0, name: $0.1) }

        total = counts.reduce(0, +)
        var longest = 0, run = 0
        for n in counts {
            run = n > 0 ? run + 1 : 0
            longest = max(longest, run)
        }
        longestStreak = longest
        // Today with no merge yet doesn't break the streak: it counts back from yesterday then.
        var current = 0
        for (i, n) in counts.enumerated().reversed() {
            if n > 0 { current += 1 } else if i == counts.count - 1 { continue } else { break }
        }
        currentStreak = current
        busiest = all.filter { $0.merges > 0 }.max { $0.merges < $1.merges || ($0.merges == $1.merges && $0.day > $1.day) }
    }

    /// The 90th percentile of the days with any merge: shades scale linearly up to it, so one huge
    /// day doesn't wash the rest out to the palest shade.
    static func cap(_ counts: [Int]) -> Int {
        let busy = counts.filter { $0 > 0 }.sorted()
        guard !busy.isEmpty else { return 0 }
        return busy[min(busy.count - 1, Int((Double(busy.count - 1) * 0.9).rounded()))]
    }

    /// 0 for no merges, else 1–4 along the way to `cap`.
    static func level(_ n: Int, cap: Int) -> Int {
        guard n > 0 else { return 0 }
        guard cap > 1 else { return 1 }
        return 1 + min(3, 3 * (n - 1) / (cap - 1))
    }
}

/// The maple ramp for the calendar's five levels (C1: maple colours, not GitHub's greens): bare branch,
/// then pale gold through orange to a deep maple red.
enum MapleShade {
    static let levels: [Color] = [
        Theme.fill,
        Color(light: 0xF7DC9C, dark: 0x5A3E1C),
        Color(light: 0xF2A957, dark: 0x9A5A22),
        Color(light: 0xE0662E, dark: 0xD86A2E),
        Color(light: 0xB3301E, dark: 0xFF8E52),
    ]
}

/// "PRs merged in the last year": the calendar card under the stat tiles.
struct MergeCalendar: View {
    let days: [Wire.StatsCalendarDay]
    @State private var hovered: String?

    /// Headless: hover a day as the pointer would (`YYYY-MM-DD`).
    static let demo = Notification.Name("MergeCalendar.demo")

    private static let gap: CGFloat = 3
    private static let labelWidth: CGFloat = 28

    var body: some View {
        let model = MergeCalendarModel(days)
        StatsCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(model.total) PRs merged in the last year")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    Text(readout(model))
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(hovered == nil ? Theme.textFaint : Theme.text)
                }
                grid(model, cell: width > 0 ? cellSize(model, width: width) : 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                footer(model)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.demo)) { note in
            hovered = (note.object as? [String])?.first
        }
    }

    /// The card's inner width, so the cells grow or shrink to fill it (narrow layout included).
    @State private var width: CGFloat = 0

    private func cellSize(_ model: MergeCalendarModel, width: CGFloat) -> CGFloat {
        let n = CGFloat(max(1, model.weeks.count))
        return max(6, min(16, (width - Self.labelWidth - Self.gap * (n - 1)) / n))
    }

    private func grid(_ model: MergeCalendarModel, cell: CGFloat) -> some View {
        let step = cell + Self.gap
        return VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topLeading) {
                ForEach(model.months, id: \.week) { m in
                    Text(m.name)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textFaint)
                        .fixedSize()
                        .offset(x: Self.labelWidth + CGFloat(m.week) * step)
                }
            }
            .frame(height: 12, alignment: .topLeading)
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: Self.gap) {
                    ForEach(0..<7, id: \.self) { d in
                        Text(d % 2 == 1 ? Calendar.current.shortWeekdaySymbols[d] : "")
                            .font(.system(size: 9.5))
                            .foregroundStyle(Theme.textFaint)
                            .frame(height: cell)
                    }
                }
                .frame(width: Self.labelWidth, alignment: .leading)
                HStack(alignment: .top, spacing: Self.gap) {
                    ForEach(model.weeks.indices, id: \.self) { w in
                        VStack(spacing: Self.gap) {
                            ForEach(0..<7, id: \.self) { d in
                                if let day = model.weeks[w][d] {
                                    RoundedRectangle(cornerRadius: max(2, cell * 0.22))
                                        .fill(MapleShade.levels[day.level])
                                        .overlay(RoundedRectangle(cornerRadius: max(2, cell * 0.22)).strokeBorder(hovered == day.day ? Theme.text.opacity(0.7) : .clear, lineWidth: 1))
                                        .frame(width: cell, height: cell)
                                        .contentShape(Rectangle())
                                        .onHover { inside in
                                            if inside { hovered = day.day } else if hovered == day.day { hovered = nil }
                                        }
                                        .help(Self.describe(day))
                                } else {
                                    Color.clear.frame(width: cell, height: cell)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func footer(_ model: MergeCalendarModel) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) { facts(model); Spacer(minLength: 12); legend(model) }
            VStack(alignment: .leading, spacing: 8) { facts(model); legend(model) }
        }
    }

    private func facts(_ model: MergeCalendarModel) -> some View {
        HStack(spacing: 18) {
            fact("Longest streak", "\(model.longestStreak) \(model.longestStreak == 1 ? "day" : "days")")
            fact("Current streak", "\(model.currentStreak) \(model.currentStreak == 1 ? "day" : "days")")
            if let b = model.busiest { fact("Busiest day", "\(b.merges) on \(Self.shortDate(b.date))") }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(label).foregroundStyle(Theme.textMuted)
            Text(value).foregroundStyle(Theme.text).monospacedDigit()
        }
        .font(.system(size: 11.5))
        .fixedSize()
    }

    private func legend(_ model: MergeCalendarModel) -> some View {
        HStack(spacing: 3) {
            Text("Less").padding(.trailing, 3)
            ForEach(MapleShade.levels.indices, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2.5).fill(MapleShade.levels[i]).frame(width: 11, height: 11)
            }
            Text("More").padding(.leading, 3)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(Theme.textFaint)
        .fixedSize()
    }

    private func readout(_ model: MergeCalendarModel) -> String {
        if let h = hovered, let day = model.weeks.joined().compactMap({ $0 }).first(where: { $0.day == h }) { return Self.describe(day) }
        let active = model.weeks.joined().compactMap { $0 }.filter { $0.merges > 0 }.count
        return "\(active) \(active == 1 ? "day" : "days") with a merge"
    }

    /// "7 merges on Saturday, Oct 31".
    static func describe(_ day: MergeCalendarModel.Day) -> String {
        let n = day.merges == 0 ? "No merges" : "\(day.merges) \(day.merges == 1 ? "merge" : "merges")"
        return "\(n) on \(day.date.formatted(Date.FormatStyle(timeZone: MergeCalendarModel.calendar.timeZone).weekday(.wide).month(.abbreviated).day()))"
    }

    private static func shortDate(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(timeZone: MergeCalendarModel.calendar.timeZone).month(.abbreviated).day())
    }
}

extension Wire.StatsCalendarDay {
    /// A year of merges with a working week's shape: quiet weekends, a slow start that picks up, a few
    /// big days and a holiday gap, ending today.
    static func sample(today: Date = Date()) -> [Wire.StatsCalendarDay] {
        let cal = MergeCalendarModel.calendar
        let local = Calendar.current.dateComponents([.year, .month, .day], from: today)
        let end = cal.date(from: local) ?? today
        let start = cal.date(byAdding: .day, value: -(cal.component(.weekday, from: end) - 1 + 52 * 7), to: end)!
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        var out: [Wire.StatsCalendarDay] = []
        var i = 0
        var d = start
        while d <= end {
            let weekday = cal.component(.weekday, from: d)
            let weekend = weekday == 1 || weekday == 7
            let ramp = 0.25 + 0.75 * Double(i) / 371
            let noise = Double((i * 37 + 11) % 17) / 17
            var n = weekend ? (noise > 0.8 ? 1 : 0) : Int((ramp * 6 * noise + (noise > 0.55 ? 1 : 0)).rounded())
            if (i * 53) % 97 == 3 { n += 7 } // a big day now and then
            if (180..<192).contains(i) { n = 0 } // a fortnight off
            out.append(.init(day: f.string(from: d), merges: UInt32(max(0, n))))
            d = cal.date(byAdding: .day, value: 1, to: d)!
            i += 1
        }
        return out
    }
}

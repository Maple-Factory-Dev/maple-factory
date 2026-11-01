import MapleKit
import SwiftUI

/// Settings › Notifications › Quiet hours: your weekly schedule when nothing notifies you, kept on the
/// factory so every device you're signed in on follows it. Each change is sent straight away.
struct QuietHoursSection: View {
    @Environment(FactoryClient.self) private var client
    private let notifier = Notifier.shared

    static let maxWindows = 7
    /// The first window a new schedule gets: weeknights, 10 PM to 7 AM.
    static let firstWindow = Wire.QuietWindow(days: [0, 1, 2, 3, 4], start: 22 * 60, end: 7 * 60)
    /// What Add Window adds after that: weekdays, 9 to 5.
    static let nextWindow = Wire.QuietWindow(days: [1, 2, 3, 4, 5], start: 9 * 60, end: 17 * 60)

    var body: some View {
        let schedule = client.quietHours
        SettingsSection("Quiet hours", caption: "Applies on all your devices: no banners or pings during these hours. Snoozing stays on this Mac.",
                        accessory: schedule == nil ? nil : AnyView(addButton(schedule!))) {
            SettingsToggle("Quiet hours", detail: schedule.map(summary), isOn: Binding(
                get: { schedule != nil },
                set: { on in client.setQuietHours(on ? .init(timeZone: TimeZone.current.identifier, windows: [Self.firstWindow]) : nil) }
            ))
            if let schedule {
                ForEach(Array(schedule.windows.enumerated()), id: \.offset) { index, window in
                    QuietWindowRow(window: window, canDelete: schedule.windows.count > 1) { changed in
                        var next = schedule
                        if let changed { next.windows[index] = changed } else { next.windows.remove(at: index) }
                        client.setQuietHours(next)
                    }
                }
                SettingsPicker("Time zone", detail: "The windows' times are in this zone, wherever you are.", selection: Binding(
                    get: { schedule.timeZone },
                    set: { zone in var next = schedule; next.timeZone = zone; client.setQuietHours(next) }
                )) {
                    ForEach(Self.zones(including: schedule.timeZone), id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ")).tag($0) }
                }
                SettingsValueRow("Now", value: notifier.quietUntil.map { "Quiet until \(Notifier.untilText($0))" } ?? "Not quiet")
            }
        }
    }

    private func addButton(_ schedule: Wire.QuietHours) -> some View {
        Button("Add Window") {
            var next = schedule
            next.windows.append(schedule.windows.isEmpty ? Self.firstWindow : Self.nextWindow)
            client.setQuietHours(next)
        }
        .disabled(schedule.windows.count >= Self.maxWindows)
    }

    private func summary(_ schedule: Wire.QuietHours) -> String {
        let n = schedule.windows.count
        return "\(n) window\(n == 1 ? "" : "s"), \(schedule.timeZone.replacingOccurrences(of: "_", with: " "))"
    }

    /// Every zone macOS knows, with the schedule's own first if it's an odd one.
    static func zones(including zone: String) -> [String] {
        let known = TimeZone.knownTimeZoneIdentifiers
        return known.contains(zone) ? known : [zone] + known
    }
}

/// One window: its days as chips, its start and end, and a delete button.
struct QuietWindowRow: View {
    let window: Wire.QuietWindow
    let canDelete: Bool
    /// The window as changed; nil: deleted.
    let change: (Wire.QuietWindow?) -> Void

    private static let letters = ["S", "M", "T", "W", "T", "F", "S"]
    private static let names = Calendar(identifier: .gregorian).weekdaySymbols

    var body: some View {
        SettingsBlock(spacing: 8) {
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    ForEach(0..<7, id: \.self) { day in dayChip(UInt16(day)) }
                }
                Spacer(minLength: 8)
                time(\.start)
                Text("to").foregroundStyle(Theme.textMuted)
                time(\.end)
                Button { change(nil) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .disabled(!canDelete)
                    .help(canDelete ? "Delete this window" : "Turn quiet hours off to remove the last window")
            }
            if let note { Text(note).font(SettingsKit.caption).foregroundStyle(Theme.textMuted) }
        }
    }

    private var note: String? {
        if window.days.isEmpty { return "Pick at least one day." }
        if window.start == window.end { return "Starts and ends at the same time: pick a different end." }
        if window.end < window.start { return "Runs past midnight into the next morning." }
        return nil
    }

    private func dayChip(_ day: UInt16) -> some View {
        let on = window.days.contains(day)
        return Button {
            var next = window
            next.days = on ? next.days.filter { $0 != day } : (next.days + [day]).sorted()
            // A window needs a day and a length; the server refuses one without, so hold it here until it has.
            if !next.days.isEmpty { change(next) }
        } label: {
            Text(Self.letters[Int(day)])
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .foregroundStyle(on ? Color.white : Theme.textMuted)
                .background(Circle().fill(on ? Color.accentColor : Theme.stroke.opacity(0.6)))
        }
        .buttonStyle(.plain)
        .help(Self.names[Int(day)])
    }

    /// A time picker for `start` or `end`, as minutes after midnight (shown in UTC so no zone shifts it).
    private func time(_ key: WritableKeyPath<Wire.QuietWindow, UInt16>) -> some View {
        DatePicker("", selection: Binding(
            get: { Date(timeIntervalSince1970: Double(window[keyPath: key]) * 60) },
            set: { date in
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = .gmt
                let parts = calendar.dateComponents([.hour, .minute], from: date)
                var next = window
                next[keyPath: key] = UInt16((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
                if next.start != next.end { change(next) }
            }
        ), displayedComponents: .hourAndMinute)
        .labelsHidden()
        .environment(\.timeZone, .gmt)
        .fixedSize()
    }
}

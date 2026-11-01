import MapleKit
import SwiftUI
import UIKit

struct NotificationsRoute: Hashable {}

/// Settings › Notifications: whether this iPhone gets the factory's pushes, your other registered phones,
/// and your quiet hours (the Mac's QuietHoursSection, the same schedule on every device).
struct NotificationSettingsView: View {
    @Environment(FactoryStore.self) private var store
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Form {
            thisPhone
            let others = store.pushDevices.filter { $0.id != store.pushDeviceID }
            if !others.isEmpty {
                Section {
                    ForEach(others, id: \.id) { device in
                        LabeledContent(device.environment == .sandbox ? "iPhone (development)" : "iPhone", value: "Last seen \(Self.ago(device.lastSeen))")
                            .swipeActions { Button("Remove", role: .destructive) { store.removePushDevice(device.id) } }
                            .accessibilityIdentifier("pushDevice.\(device.id)")
                    }
                } header: { Text("Other devices") } footer: { Text("Swipe to remove a phone you no longer use.") }
            }
            QuietHoursForm()
        }
        .navigationTitle("Notifications")
        .task(id: phase) { await refreshStatus() }
    }

    @ViewBuilder private var thisPhone: some View {
        Section {
            LabeledContent("Permission") {
                switch store.notificationStatus {
                case .allowed: Text("Allowed")
                case .notAsked: Text("Not asked")
                case .off:
                    Button("Off · Open Settings") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
            }
            .accessibilityIdentifier("pushPermission")
            LabeledContent("Registration", value: registration)
                .accessibilityIdentifier("pushRegistration")
            if let error = store.pushError, store.status != .demo {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("This iPhone")
        } footer: {
            Text("Pushes come when a task needs you: a raised hand, a question, an approval, a review or a mention. The factory sends them only once an admin turns on mobile notifications in Settings › General.")
        }
    }

    private var registration: String {
        guard let id = store.pushDeviceID, let device = store.pushDevices.first(where: { $0.id == id }) else { return "Not registered" }
        let env = device.environment == .sandbox ? "sandbox" : "production"
        return "Registered · \(env) · seen \(Self.ago(device.lastSeen))"
    }

    private func refreshStatus() async {
        guard store.status != .demo else { return }
        store.notificationStatus = await AppDelegate.notificationStatus()
    }

    static func ago(_ ms: UInt64) -> String {
        RelativeDateTimeFormatter().localizedString(for: Date(timeIntervalSince1970: Double(ms) / 1000), relativeTo: Date())
    }
}

/// Quiet hours, as the Mac's QuietHoursSection: a toggle, up to 7 windows, and the schedule's time zone.
/// Each change is sent straight away (`quietHours.set`).
private struct QuietHoursForm: View {
    @Environment(FactoryStore.self) private var store

    static let maxWindows = 7
    /// The first window a new schedule gets: weeknights, 10 PM to 7 AM.
    static let firstWindow = Wire.QuietWindow(days: [0, 1, 2, 3, 4], start: 22 * 60, end: 7 * 60)
    /// What Add Window adds after that: weekdays, 9 to 5.
    static let nextWindow = Wire.QuietWindow(days: [1, 2, 3, 4, 5], start: 9 * 60, end: 17 * 60)

    var body: some View {
        let schedule = store.quietHours
        Section {
            Toggle("Quiet hours", isOn: Binding(
                get: { schedule != nil },
                set: { on in store.setQuietHours(on ? .init(timeZone: TimeZone.current.identifier, windows: [Self.firstWindow]) : nil) }
            ))
            .accessibilityIdentifier("quietHoursToggle")
            if let schedule {
                ForEach(Array(schedule.windows.enumerated()), id: \.offset) { index, window in
                    QuietWindowEditor(window: window, index: index) { changed in
                        var next = schedule
                        next.windows[index] = changed
                        store.setQuietHours(next)
                    }
                    .deleteDisabled(schedule.windows.count <= 1)
                }
                .onDelete { offsets in
                    var next = schedule
                    next.windows.remove(atOffsets: offsets)
                    if !next.windows.isEmpty { store.setQuietHours(next) }
                }
                Button("Add Window") {
                    var next = schedule
                    next.windows.append(schedule.windows.isEmpty ? Self.firstWindow : Self.nextWindow)
                    store.setQuietHours(next)
                }
                .disabled(schedule.windows.count >= Self.maxWindows)
                Picker("Time zone", selection: Binding(
                    get: { schedule.timeZone },
                    set: { zone in var next = schedule; next.timeZone = zone; store.setQuietHours(next) }
                )) {
                    ForEach(Self.zones(including: schedule.timeZone), id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ")).tag($0) }
                }
                .pickerStyle(.navigationLink)
                LabeledContent("Now", value: schedule.isQuiet(at: Date()) ? "Quiet" : "Not quiet")
            }
        } header: {
            Text("Quiet hours")
        } footer: {
            Text("Applies on all your devices: no pushes or banners during these hours. Swipe a window to delete it.")
        }
    }

    static func zones(including zone: String) -> [String] {
        let known = TimeZone.knownTimeZoneIdentifiers
        return known.contains(zone) ? known : [zone] + known
    }
}

/// One window: day chips, then its start and end.
private struct QuietWindowEditor: View {
    let window: Wire.QuietWindow
    let index: Int
    let change: (Wire.QuietWindow) -> Void

    private static let letters = ["S", "M", "T", "W", "T", "F", "S"]
    private static let names = Calendar(identifier: .gregorian).weekdaySymbols

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(0..<7, id: \.self) { day in dayChip(UInt16(day)) }
            }
            HStack {
                time(\.start)
                Text("to").foregroundStyle(.secondary)
                time(\.end)
                Spacer()
            }
            if window.end < window.start {
                Text("Runs past midnight into the next morning.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quietWindow.\(index)")
    }

    private func dayChip(_ day: UInt16) -> some View {
        let on = window.days.contains(day)
        return Button {
            var next = window
            next.days = on ? next.days.filter { $0 != day } : (next.days + [day]).sorted()
            // The server refuses a window with no days, so the last one stays on.
            if !next.days.isEmpty { change(next) }
        } label: {
            Text(Self.letters[Int(day)])
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .foregroundStyle(on ? Color.white : Color.secondary)
                .background(Circle().fill(on ? Color.accentColor : Color.secondary.opacity(0.18)))
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Self.names[Int(day)])
        .accessibilityValue(on ? "On" : "Off")
    }

    /// Minutes after midnight, shown in UTC so no zone shifts them.
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
    }
}

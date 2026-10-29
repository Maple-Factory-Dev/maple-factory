import SwiftUI

/// Snooze, resume or turn off this Mac's banners: the bell's menu, and the Inbox and Needs a hand rows' too.
struct NotificationMenu: View {
    var body: some View {
        let notifier = Notifier.shared
        Button("Snooze 30 Minutes") { notifier.snooze(for: 30 * 60) }
        Button("Snooze 1 Hour") { notifier.snooze(for: 60 * 60) }
        Button("Snooze 4 Hours") { notifier.snooze(for: 4 * 60 * 60) }
        Button("Snooze Until Tomorrow, 9 AM") { notifier.snooze(until: Notifier.tomorrowMorning) }
        Divider()
        if notifier.isOn {
            Button("Turn Off Notifications") { notifier.turnOff() }
        } else {
            Button("Resume Notifications") { notifier.resume() }
        }
    }
}

extension Notifier {
    var bellIcon: String { isOn ? "bell" : "bell.slash" }

    /// "Notifications on", "Snoozed until 3:40 PM", or "Notifications off".
    var statusText: String {
        if !enabled { return "Notifications off" }
        if isSnoozed, let snoozedUntil { return "Snoozed until \(Notifier.untilText(snoozedUntil))" }
        return "Notifications on"
    }

    static func untilText(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        return Calendar.current.isDateInToday(date) ? time : "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time)"
    }
}

/// The sidebar header's bell.
struct NotificationBell: View {
    var body: some View {
        let notifier = Notifier.shared
        Menu {
            NotificationMenu()
        } label: {
            Image(systemName: notifier.bellIcon)
                .font(.system(size: 13))
                .foregroundStyle(notifier.isOn ? Theme.textMuted : Theme.State.awaitingApproval)
                .frame(width: 28, height: 44)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(notifier.statusText)
    }
}

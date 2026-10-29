import AppKit
import Foundation
import OSLog
import UserNotifications

/// macOS banners for when a task newly needs you and the app is in the background. Snoozing and
/// turning them off are this Mac's alone, kept in UserDefaults.
@MainActor @Observable final class Notifier: NSObject {
    static let shared = Notifier()

    /// Why a task wants you, as the banner says it.
    enum Reason {
        case hand(HandRaise.Reason)
        case question
        case approval
        case review

        var text: String {
            switch self {
            case .hand(let reason): "Needs a hand: \(reason.title)"
            case .question: "Asked you a question"
            case .approval: "Plan ready to approve"
            case .review: "Ready for your review"
            }
        }
    }

    private static let category = "task"
    private static let openAction = "open"
    private static let snoozeAction = "snooze"

    var enabled = UserDefaults.standard.object(forKey: "notifyEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "notifyEnabled") }
    }
    var snoozedUntil: Date? = UserDefaults.standard.object(forKey: "notifySnoozedUntil") as? Date {
        didSet { UserDefaults.standard.set(snoozedUntil, forKey: "notifySnoozedUntil") }
    }
    /// macOS said no, so the settings can point at System Settings.
    private(set) var denied = false
    /// A banner that was clicked: the task to open, and whether it was a raised hand.
    var opening: (id: String, hand: Bool)?

    /// `swift run` has no bundle, and UNUserNotificationCenter traps without one.
    private var available: Bool { Bundle.main.bundleIdentifier != nil }
    private let log = Logger(subsystem: "dev.maplefactory.app", category: "notifications")
    private var asked = false
    private var expiry: Timer?

    var isSnoozed: Bool {
        guard let snoozedUntil else { return false }
        return snoozedUntil > .now
    }

    var isOn: Bool { enabled && !isSnoozed }

    /// Called once at launch: takes the banners' clicks and defines their buttons.
    func start() {
        guard available else { return log.info("No bundle (swift run): notifications are off") }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let open = UNNotificationAction(identifier: Self.openAction, title: "Open", options: [.foreground])
        let snooze = UNNotificationAction(identifier: Self.snoozeAction, title: "Snooze 1 hour")
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [open, snooze], intentIdentifiers: [])])
        scheduleExpiry()
        Task { await refreshPermission() }
    }

    func snooze(for interval: TimeInterval) { snooze(until: .now.addingTimeInterval(interval)) }

    func snooze(until date: Date) {
        enabled = true
        snoozedUntil = date
        scheduleExpiry()
    }

    /// Tomorrow at 9am.
    static var tomorrowMorning: Date {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: .now) ?? .now
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    func resume() {
        enabled = true
        snoozedUntil = nil
        expiry?.invalidate()
    }

    func turnOff() {
        enabled = false
        snoozedUntil = nil
    }

    func notify(task: Wire.Task, reason: Reason) {
        // Why a banner didn't come: `log stream --predicate 'category == "notifications"'`.
        guard available else { return log.info("\(task.id): no banner, not a bundled app") }
        guard isOn else { return log.info("\(task.id): no banner, \(self.statusText)") }
        guard !NSApp.isActive else { return log.info("\(task.id): no banner, the app is frontmost") }
        log.info("\(task.id): banner, \(reason.text)")
        Task { await post(task: task, reason: reason) }
    }

    /// The task stopped needing you, so its banner goes too.
    func clear(task id: String) {
        guard available else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }

    func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func post(task: Wire.Task, reason: Reason) async {
        let center = UNUserNotificationCenter.current()
        if !asked {
            asked = true
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        await refreshPermission()
        guard !denied else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(task.id) · \(reason.text)"
        content.body = task.title
        content.sound = .default
        content.categoryIdentifier = Self.category
        content.userInfo = ["task": task.id, "hand": { if case .hand = reason { true } else { false } }()]
        // The task's id, so a task never stacks banners: a newer one replaces it.
        try? await center.add(UNNotificationRequest(identifier: task.id, content: content, trigger: nil))
    }

    func refreshPermission() async {
        guard available else { return }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        denied = status == .denied
    }

    /// Redraws the bell when a snooze runs out on its own.
    private func scheduleExpiry() {
        expiry?.invalidate()
        guard let snoozedUntil, snoozedUntil > .now else { return }
        expiry = Timer.scheduledTimer(withTimeInterval: snoozedUntil.timeIntervalSinceNow + 1, repeats: false) { _ in
            Task { @MainActor in Notifier.shared.snoozedUntil = nil }
        }
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let id = info["task"] as? String else { return }
        let hand = info["hand"] as? Bool ?? false
        let action = response.actionIdentifier
        await MainActor.run {
            if action == Self.snoozeAction {
                snooze(for: 3600)
            } else if action == Self.openAction || action == UNNotificationDefaultActionIdentifier {
                NSApp.activate(ignoringOtherApps: true)
                opening = (id, hand)
            }
        }
    }
}

import AppKit
import Foundation
import OSLog
import SwiftUI
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
        /// A teammate's comment that @mentions you: who wrote it, and what it says.
        case mention(author: String, text: String)

        var text: String {
            switch self {
            case .hand(let reason): "Needs a hand: \(reason.title)"
            case .question: "Asked you a question"
            case .approval: "Plan ready to approve"
            case .review: "Ready for your review"
            case .mention(let author, let text): "\(author) mentioned you: \(text)"
            }
        }
    }

    private static let category = "task"
    private static let openAction = "open"
    private static let snoozeAction = "snooze"

    var enabled = AppDefaults.object(forKey: "notifyEnabled") as? Bool ?? true {
        didSet { AppDefaults.set(enabled, forKey: "notifyEnabled") }
    }
    var snoozedUntil: Date? = AppDefaults.object(forKey: "notifySnoozedUntil") as? Date {
        didSet { AppDefaults.set(snoozedUntil, forKey: "notifySnoozedUntil") }
    }
    /// macOS said no, so the settings can point at System Settings.
    private(set) var denied = false
    /// A banner that was clicked: the task to open, whether it was a raised hand, and whether it opens
    /// full size (a hand or a mention: the comment is on the task, not in a list).
    var opening: (id: String, hand: Bool, focus: Bool)?

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

    /// Headless, the banner a run would have posted (it can't post one), so a recording shows it.
    var headlessBanner: (title: String, subtitle: String, body: String)?

    func notify(task: Wire.Task, reason: Reason) {
        // Why a banner didn't come: `log stream --predicate 'category == "notifications"'`.
        if Headless.isOn {
            let banner = Self.banner(task: task, reason: reason)
            headlessBanner = (banner.title, banner.subtitle, banner.body)
            return
        }
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
        let banner = Self.banner(task: task, reason: reason)
        content.title = banner.title
        content.subtitle = banner.subtitle
        content.body = banner.body
        // The task's id, so a task never stacks banners: a newer one replaces it. Each mention is its own.
        var identifier = task.id
        if case .mention = reason { identifier = "\(task.id)/mention/\(UUID().uuidString)" }
        content.sound = .default
        content.categoryIdentifier = Self.category
        let hand = { if case .hand = reason { true } else { false } }()
        let mention = { if case .mention = reason { true } else { false } }()
        content.userInfo = ["task": task.id, "hand": hand, "focus": hand || mention]
        try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    /// What a banner says: for a mention, who and what they wrote; otherwise why the task wants you.
    static func banner(task: Wire.Task, reason: Reason) -> (title: String, subtitle: String, body: String) {
        if case .mention(let author, let text) = reason {
            return ("\(author) mentioned you", "\(task.id) · \(task.title)", text)
        }
        return ("\(task.id) · \(reason.text)", "", task.title)
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
        let focus = info["focus"] as? Bool ?? hand
        let action = response.actionIdentifier
        await MainActor.run {
            if action == Self.snoozeAction {
                snooze(for: 3600)
            } else if action == Self.openAction || action == UNNotificationDefaultActionIdentifier {
                NSApp.activate(ignoringOtherApps: true)
                opening = (id, hand, focus)
            }
        }
    }
}

/// The banner a headless run would have posted, drawn in the window's corner.
struct HeadlessBanner: View {
    let banner: (title: String, subtitle: String, body: String)

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title).font(.system(size: 13, weight: .semibold))
                if !banner.subtitle.isEmpty { Text(banner.subtitle).font(.system(size: 12, weight: .medium)) }
                Text(banner.body).font(.system(size: 12)).lineLimit(2)
            }
            .foregroundStyle(Theme.text)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 340)
        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.stroke))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .padding(14)
    }
}

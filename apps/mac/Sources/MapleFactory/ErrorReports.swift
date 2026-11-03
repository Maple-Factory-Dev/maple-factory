import Foundation
import Sentry

/// Crashes and errors to Maple Factory's Sentry project, with the app's version and the factory's org.
/// Release builds carry the DSN in Info.plist (bundle.sh, from server/web/sentry.json); debug builds,
/// MAPLE_TELEMETRY=off, or `defaults write dev.maplefactory.app MapleTelemetry off` send nothing.
/// Nothing a person typed goes with a crash or error: no user, no screenshots or view hierarchy, no network
/// breadcrumbs. What does go with a crash or hang is which screen was open (`screen`), by kind only.
/// The one thing a person types that goes is feedback from Help › Send Feedback…, and only when they press
/// Send: their message, the email they give (if any), and a screenshot of the window if they tick it.
enum ErrorReports {
    static var dsn: String? {
        #if DEBUG
        return nil
        #else
        let dsn = Bundle.main.object(forInfoDictionaryKey: "MapleSentryDSN") as? String
        return forcedOff || !enabled || dsn?.isEmpty != false ? nil : dsn
        #endif
    }

    /// MAPLE_TELEMETRY=off in the environment: the Settings toggle can't turn reports back on.
    static var forcedOff: Bool { ProcessInfo.processInfo.environment["MAPLE_TELEMETRY"]?.lowercased() == "off" }

    /// Settings › General's "Send crash and error reports": the `MapleTelemetry` default, on unless it's "off".
    /// Changing it stops or starts the SDK straight away.
    static var enabled: Bool {
        get { AppDefaults.string(forKey: "MapleTelemetry")?.lowercased() != "off" }
        set {
            if newValue { AppDefaults.removeObject(forKey: "MapleTelemetry") } else { AppDefaults.set("off", forKey: "MapleTelemetry") }
            if newValue { start() } else { SentrySDK.close() }
        }
    }

    static func start() {
        guard let dsn, !SentrySDK.isEnabled else { return }
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0"
        SentrySDK.start { options in
            options.dsn = dsn
            options.releaseName = "maple-mac@\(version)"
            options.dist = info["CFBundleVersion"] as? String
            options.environment = "production"
            options.sendDefaultPii = false
            options.enableCrashHandler = true
            options.enableAutoPerformanceTracing = false
            options.tracesSampleRate = 0
            options.enableNetworkBreadcrumbs = false
            options.enableNetworkTracking = false
            options.enableCaptureFailedRequests = false
            options.enableAutoBreadcrumbTracking = false
            options.beforeSend = { event in
                event.user = nil
                event.serverName = nil
                return event
            }
        }
        // Until the feed says, the factory this app was last in.
        if let org = SavedFactories.load(AppDefaults)?.max(by: { $0.lastUsed < $1.lastUsed })?.org, !org.isEmpty {
            tag(org: org)
        }
        // `-sentryTest YES`: one test error, to see it arrive; with `-sentryTestHang YES` too, a 3s stall of
        // the main thread once the window is up, to see a hang report arrive with its symbols and screen.
        if AppDefaults.bool(forKey: "sentryTest") {
            SentrySDK.capture(error: NSError(domain: "dev.maplefactory.app", code: 1, userInfo: [NSLocalizedDescriptionKey: "Maple Factory Mac app: Sentry test error"]))
            SentrySDK.flush(timeout: 10)
            if AppDefaults.bool(forKey: "sentryTestHang") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { stallForTest() }
            }
        }
    }

    /// The screen on view, as a `screen` tag on every event after and a navigation breadcrumb, so a hang
    /// report says where it happened. Only the screen's kind ("goal.board", "task.focus", "settings"),
    /// never a task's id or title or a goal's name. A repeat of the current screen adds nothing.
    @MainActor static func screen(_ kind: String) {
        guard kind != lastScreen else { return }
        let from = lastScreen
        if kind == "settings" { screenUnder = from }
        lastScreen = kind
        guard dsn != nil else { return }
        let crumb = Breadcrumb(level: .info, category: "navigation")
        crumb.type = "navigation"
        crumb.data = ["from": from ?? "launch", "to": kind]
        SentrySDK.addBreadcrumb(crumb)
        SentrySDK.configureScope { $0.setTag(value: kind, key: "screen") }
    }
    /// A window that came over another (Settings) closing: the screen under it is on view again.
    @MainActor static func screenClosed(_ kind: String) {
        guard kind == lastScreen, let under = screenUnder else { return }
        screen(under)
    }
    @MainActor private static var lastScreen: String?
    /// The screen on view, by kind, for the feedback sheet's footer and fallback email.
    @MainActor static var currentScreen: String? { lastScreen }
    @MainActor private static var screenUnder: String?

    /// Blocks the main thread for 3s: past the hang tracker's 2s, for `-sentryTestHang`.
    @inline(never) static func stallForTest() {
        Thread.sleep(forTimeInterval: 3)
    }

    /// The factory this app is signed in to, on every event after.
    static func tag(org: String) {
        guard dsn != nil else { return }
        SentrySDK.configureScope { $0.setTag(value: org, key: "org") }
    }

    /// Feedback can go through Sentry: a release build with the DSN and reports on.
    static var canSendFeedback: Bool { dsn != nil }

    /// Help › Send Feedback…: a Sentry User Feedback item, with the scope's `screen` and `org` tags, a
    /// `feedback_kind` tag, and the window's screenshot when the person ticked it. Waits up to 10s to send.
    @discardableResult
    static func sendFeedback(_ draft: FeedbackDraft, screenshot: Data?) -> Bool {
        guard canSendFeedback, SentrySDK.isEnabled, draft.canSend else { return false }
        let attachments = screenshot.map { [Attachment(data: $0, filename: "screenshot.png", contentType: "image/png")] }
        let feedback = SentryFeedback(message: draft.sentryMessage, name: nil, email: draft.replyEmail,
                                      source: .custom, attachments: attachments)
        // On the scope only for this item, so later crash reports don't carry it.
        SentrySDK.configureScope { $0.setTag(value: draft.kind.rawValue, key: "feedback_kind") }
        SentrySDK.capture(feedback: feedback)
        SentrySDK.configureScope { $0.removeTag(key: "feedback_kind") }
        SentrySDK.flush(timeout: 10)
        return true
    }
}

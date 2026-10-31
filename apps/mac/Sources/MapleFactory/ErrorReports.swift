import Foundation
import Sentry

/// Crashes and errors to Maple Factory's Sentry project, with the app's version and the factory's org.
/// Release builds carry the DSN in Info.plist (bundle.sh, from server/web/sentry.json); debug builds,
/// MAPLE_TELEMETRY=off, or `defaults write dev.maplefactory.app MapleTelemetry off` send nothing.
/// Nothing a person typed goes: no user, no screenshots or view hierarchy, no network breadcrumbs.
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
        // `-sentryTest YES`: one test error, to see it arrive.
        if AppDefaults.bool(forKey: "sentryTest") {
            SentrySDK.capture(error: NSError(domain: "dev.maplefactory.app", code: 1, userInfo: [NSLocalizedDescriptionKey: "Maple Factory Mac app: Sentry test error"]))
            SentrySDK.flush(timeout: 10)
        }
    }

    /// The factory this app is signed in to, on every event after.
    static func tag(org: String) {
        guard dsn != nil else { return }
        SentrySDK.configureScope { $0.setTag(value: org, key: "org") }
    }
}

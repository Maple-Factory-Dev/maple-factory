import Foundation
import MapleKit
import Sentry

/// Crashes and errors to Maple Factory's `maple-ios` Sentry project, with the app's version and the
/// factory's org, like the Mac app's. The build copies the DSN into Info.plist (project.yml, from
/// server/web/sentry.json); debug builds, or `-MapleTelemetry off` (the setting of that name), send nothing.
/// Nothing a person typed goes: no user, no screenshots or view hierarchy, no network breadcrumbs.
enum ErrorReports {
    static var dsn: String? {
        #if DEBUG
        return nil
        #else
        let off = UserDefaults.standard.string(forKey: "MapleTelemetry")?.lowercased() == "off"
        let dsn = Bundle.main.object(forInfoDictionaryKey: "MapleSentryDSN") as? String
        return off || dsn?.isEmpty != false ? nil : dsn
        #endif
    }

    static func start() {
        guard let dsn else { return }
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0"
        SentrySDK.start { options in
            options.dsn = dsn
            options.releaseName = "maple-ios@\(version)"
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
            options.attachScreenshot = false
            options.attachViewHierarchy = false
            options.beforeSend = { event in
                event.user = nil
                event.serverName = nil
                return event
            }
        }
        // Until the feed says, the factory this app was last in.
        if let org = SavedFactories.fallback(SavedFactories.load(.standard) ?? [])?.org, !org.isEmpty {
            tag(org: org)
        }
        // `-sentryTest YES`: one test error, to see it arrive.
        if UserDefaults.standard.bool(forKey: "sentryTest") {
            SentrySDK.capture(error: NSError(domain: "dev.maplefactory.ios", code: 1, userInfo: [NSLocalizedDescriptionKey: "Maple Factory iOS app: Sentry test error"]))
            SentrySDK.flush(timeout: 10)
        }
    }

    /// The factory this app is signed in to, on every event after.
    static func tag(org: String) {
        guard dsn != nil else { return }
        SentrySDK.configureScope { $0.setTag(value: org, key: "org") }
    }
}

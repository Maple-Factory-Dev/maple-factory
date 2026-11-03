import MapleKit
import SwiftUI

/// Maple Factory for iPhone. `-demo YES` opens the sample factory; otherwise the last factory
/// signed into, or the sign-in screen. UI tests set the goal Overview's folds with the
/// `GOAL_OVERVIEW_FOLDS` launch environment variable (see `seedGoalOverviewFolds`).
@main
struct MapleFactoryApp: App {
    /// Owns the store, so a notification tapped on a cold launch can open its task (PushNotifications.swift).
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private var store: FactoryStore { delegate.store }

    init() {
        ErrorReports.start()
        Self.seedGoalOverviewFolds()
    }

    /// UI tests only: `GOAL_OVERVIEW_FOLDS=drafts=1,inMotion=0,landed=0,needsYou=1,upNext=1` in the launch
    /// environment sets the goal Overview's section folds (`goalOverview.<key>Open`) before the first view.
    /// They go into the normal defaults, not the argument domain a `-goalOverview.<key>Open` launch
    /// argument would use: that domain outranks what @AppStorage writes, so a header tap would never stick.
    private static func seedGoalOverviewFolds() {
        guard let folds = ProcessInfo.processInfo.environment["GOAL_OVERVIEW_FOLDS"] else { return }
        for pair in folds.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            UserDefaults.standard.set(parts[1] == "1", forKey: "goalOverview.\(parts[0])Open")
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if store.isSignedIn {
                    RootView()
                } else {
                    SignInView()
                }
            }
            .environment(store)
            .tint(Theme.accent)
            .animation(.default, value: store.isSignedIn)
            .task {
                if UserDefaults.standard.bool(forKey: "demo") {
                    store.startDemo()
                } else if UserDefaults.standard.string(forKey: "onboardingStep") == nil {
                    // `-onboardingStep` shows the sign-in screen's sample even when a factory is saved here.
                    store.restore()
                }
                // `-pushRef <id>`: as if that task's notification were tapped (NotificationSettingsTests).
                AppDelegate.open(ref: UserDefaults.standard.string(forKey: "pushRef"), in: store)
            }
            .onOpenURL { url in
                // maplefactory://task/<id> or maplefactory://session/<machine>/<id>; RootView opens it
                // once you're signed in. Anything else is ignored.
                if let link = FactoryLink(url: url) { store.pendingLink = link }
            }
        }
    }
}

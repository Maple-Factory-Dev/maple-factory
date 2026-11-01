import MapleKit
import SwiftUI

/// Maple Factory for iPhone. `-demo YES` opens the sample factory; otherwise the last factory
/// signed into, or the sign-in screen.
@main
struct MapleFactoryApp: App {
    /// Owns the store, so a notification tapped on a cold launch can open its task (PushNotifications.swift).
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private var store: FactoryStore { delegate.store }

    init() {
        ErrorReports.start()
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
                if UserDefaults.standard.bool(forKey: "demo") { store.startDemo() } else { store.restore() }
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

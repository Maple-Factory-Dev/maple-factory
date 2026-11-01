import MapleKit
import SwiftUI
import UIKit
import UserNotifications

/// Push notifications from the factory's relay (server/src/push.ts, MF-231). Asks for permission once a
/// real factory is live (never on the sign-in screen or in the demo), hands the APNs token to the store,
/// which registers it with `push.register`, and opens the task a tapped notification is about.
/// It owns the app's FactoryStore, so a notification tapped on a cold launch has somewhere to go.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let store = FactoryStore()

    /// The APNs environment this build's token belongs to, as the entitlement's aps-environment says.
    static var environment: Wire.PushEnvironment {
        #if DEBUG
        .sandbox
        #else
        .production
        #endif
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        store.askForPush = { [weak self] in self?.askForPermission() }
        return true
    }

    /// Asks once (iOS only shows the prompt the first time), then registers on every live sign-in, since
    /// the token can change. A refusal is recorded, not retried.
    func askForPermission() {
        Task {
            let center = UNUserNotificationCenter.current()
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            await refreshStatus()
            if granted { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    /// Reads whether notifications are allowed, as the Notifications screen shows it.
    func refreshStatus() async {
        store.notificationStatus = await Self.notificationStatus()
    }

    static func notificationStatus() async -> FactoryStore.NotificationStatus {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: .allowed
        case .denied: .off
        default: .notAsked
        }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        store.registerPush(token: deviceToken.map { String(format: "%02x", $0) }.joined(), environment: Self.environment)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // A simulator build has no aps-environment entitlement, so it lands here.
        store.pushError = error.localizedDescription
    }

    /// A tapped notification: its `ref` (a task key, like MF-12) opens that task.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let ref = response.notification.request.content.userInfo["ref"] as? String
        await MainActor.run { Self.open(ref: ref, in: store) }
    }

    /// While the app is open, still a banner, unless it's about the task already on screen.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let ref = notification.request.content.userInfo["ref"] as? String
        let onScreen = await MainActor.run { ref != nil && store.visibleTask == ref }
        return onScreen ? [] : [.banner, .list, .sound]
    }

    /// What a tap does, and what `-pushRef <id>` runs at launch: RootView's pendingLink opens the TaskRoute.
    static func open(ref: String?, in store: FactoryStore) {
        guard let ref, !ref.isEmpty else { return }
        store.pendingLink = .task(ref)
    }
}

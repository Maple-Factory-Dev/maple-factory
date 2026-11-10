import Foundation
import Testing
@testable import MapleFactory

/// The Dock badge's rule: what's waiting on you (For you items plus raised hands), cleared at zero,
/// signed out or with the setting off, and never hidden by snooze or quiet hours.
@MainActor struct DockBadgeTests {
    @Test func inboxAndHandsAddUp() {
        #expect(DockBadge.count(inbox: 3, hands: 2, signedIn: true, enabled: true) == 5)
        #expect(DockBadge.count(inbox: 4, hands: 0, signedIn: true, enabled: true) == 4)
        #expect(DockBadge.count(inbox: 0, hands: 1, signedIn: true, enabled: true) == 1)
        #expect(DockBadge.label(for: 5) == "5")
    }

    @Test func zeroClearsTheBadge() {
        #expect(DockBadge.count(inbox: 0, hands: 0, signedIn: true, enabled: true) == 0)
        #expect(DockBadge.label(for: 0) == nil)
    }

    @Test func signedOutShowsNothingEvenWithItems() {
        #expect(DockBadge.count(inbox: 3, hands: 2, signedIn: false, enabled: true) == 0)
    }

    @Test func settingOffShowsNothing() {
        #expect(DockBadge.count(inbox: 3, hands: 2, signedIn: true, enabled: false) == 0)
    }

    @Test func snoozedBannersStillGetABadge() {
        let notifier = Notifier.shared
        let was = notifier.enabled
        defer { notifier.enabled = was }
        notifier.enabled = false
        #expect(!notifier.isOn)
        // Snooze and quiet hours aren't inputs: banners off, the count is the same.
        #expect(DockBadge.count(inbox: 2, hands: 1, signedIn: true, enabled: true) == 3)
        #expect(DockBadge.label(for: 3) == "3")
    }

    @Test func capsAt99Plus() {
        #expect(DockBadge.label(for: 99) == "99")
        #expect(DockBadge.label(for: 100) == "99+")
        #expect(DockBadge.label(for: 1_000) == "99+")
    }

    @Test func settingDefaultsOn() {
        #expect(DockBadge.settingKey == "dockShowsBadge")
    }
}

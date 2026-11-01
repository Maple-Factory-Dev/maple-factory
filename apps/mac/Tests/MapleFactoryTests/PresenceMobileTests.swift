import Foundation
import Testing
@testable import MapleFactory

/// A teammate who's only on the iPhone or Android app says so in the People list's tooltips.
@MainActor struct PresenceMobileTests {
    private let ana = Person(name: "Ana Lee", color: .blue, isHuman: true, github: "ana")

    @Test func tooltipSaysOnMobile() {
        #expect(FactorySidebar.presenceHelp(ana, viewing: nil, online: true, mobile: true) == "Online on mobile")
        #expect(FactorySidebar.presenceHelp(ana, viewing: "MF-123", online: true, mobile: true) == "Ana is viewing MF-123 on mobile")
    }

    @Test func desktopAndOfflineReadAsBefore() {
        #expect(FactorySidebar.presenceHelp(ana, viewing: nil, online: true, mobile: false) == "Online")
        #expect(FactorySidebar.presenceHelp(ana, viewing: "MF-123", online: true, mobile: false) == "Ana is viewing MF-123")
        #expect(FactorySidebar.presenceHelp(ana, viewing: nil, online: false, mobile: false) == "Offline")
    }

    @Test func statusLineWithoutUntil() {
        let status = PersonStatus(emoji: "🎧", text: "Heads down on releases")
        #expect(FactorySidebar.statusLine(status) == "🎧 Heads down on releases")
        #expect(FactorySidebar.presenceHelp(ana, viewing: "MF-123", online: true, mobile: false, status: status)
                == "Ana is viewing MF-123 · 🎧 Heads down on releases")
    }

    @Test func statusLineWithUntil() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let later = now.addingTimeInterval(60 * 60 * 24 * 3)
        let status = PersonStatus(emoji: "🌴", text: "Out of office", until: later, kind: .outOfOffice)
        let until = try #require(FactorySidebar.untilLine(status, now: now))
        #expect(until.hasPrefix("until "))
        #expect(FactorySidebar.statusLine(status, now: now) == "🌴 Out of office, \(until)")
    }

    @Test func noStatusReadsAsPresenceOnly() {
        #expect(FactorySidebar.statusLine(nil) == nil)
        #expect(FactorySidebar.presenceHelp(ana, viewing: nil, online: false, mobile: false, status: nil) == "Offline")
    }

    @Test func hoverCardPresenceLine() {
        #expect(FactorySidebar.presenceLine(ana, viewing: nil, online: true, mobile: true) == "Online · on mobile")
        #expect(FactorySidebar.presenceLine(ana, viewing: "MF-123", online: true, mobile: false) == "Viewing MF-123")
        #expect(FactorySidebar.presenceLine(ana, viewing: nil, online: false, mobile: false) == "Offline")
    }
}

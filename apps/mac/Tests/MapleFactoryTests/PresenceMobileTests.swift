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
}

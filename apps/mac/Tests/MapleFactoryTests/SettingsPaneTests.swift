import Testing
import AppKit
@testable import MapleFactory

/// The Settings sidebar: every pane shows once, with a title, an icon and a tile color.
struct SettingsPaneTests {
    typealias Pane = OrgSettingsView.Pane

    @Test func sidebarShowsEveryPaneOnce() {
        let shown = OrgSettingsView.sidebarPanes
        #expect(shown.count == Pane.allCases.count)
        #expect(Set(shown) == Set(Pane.allCases))
    }

    @Test func accountIsTheHeaderAndUpdatesIsPinned() {
        #expect(OrgSettingsView.headerPane == .account)
        #expect(OrgSettingsView.footerPane == .updates)
        #expect(OrgSettingsView.sidebarGroups.compactMap(\.title) == ["Factory", "This Mac"])
    }

    @Test func everyPaneHasATitleIconAndColor() {
        for pane in Pane.allCases {
            #expect(!pane.title.isEmpty)
            #expect(NSImage(systemSymbolName: pane.icon, accessibilityDescription: nil) != nil, "\(pane) has no SF Symbol \(pane.icon)")
            #expect(pane.color != .clear)
        }
    }
}

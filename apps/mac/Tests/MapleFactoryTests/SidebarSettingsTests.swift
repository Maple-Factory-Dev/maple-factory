import Testing
@testable import MapleFactory

/// What the sidebar's cog offers: admins get the factory's panes, everyone gets their own.
struct SidebarSettingsTests {
    @Test func adminGetsFactoryAndPersonalPanes() {
        #expect(SidebarSettings.panes(admin: true) == [.repos, .secrets, .people, .prompts, .merging, .account, .runner, .notifications])
    }

    @Test func memberGetsOnlyPersonalPanes() {
        #expect(SidebarSettings.panes(admin: false) == [.account, .runner, .notifications])
    }

    @Test func memberMenuHasNoFactorySection() {
        #expect(SidebarSettings.sections(admin: true).map(\.title) == ["Factory", "You"])
        #expect(SidebarSettings.sections(admin: false).map(\.title) == ["You"])
    }

    @Test func clickLandsAdminsOnAFactoryPane() {
        #expect(SidebarSettings.clickTab(current: "secrets", admin: true) == "secrets")
        #expect(SidebarSettings.clickTab(current: "runner", admin: true) == "repos")
        #expect(SidebarSettings.clickTab(current: "runner", admin: false) == "runner")
    }
}

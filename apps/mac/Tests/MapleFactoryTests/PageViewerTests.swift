import CoreGraphics
import Testing
@testable import MapleFactory

/// MF-296: a mockup or artifact page shown large at Desktop, Tablet or Mobile width.
@MainActor
struct PageViewerTests {
    @Test func presetWidths() {
        #expect(PageViewport.desktop.width == 1280)
        #expect(PageViewport.tablet.width == 834)
        #expect(PageViewport.mobile.width == 390)
        #expect(PageViewport.fit.width == nil)
        #expect(PageViewport.allCases == [.desktop, .tablet, .mobile, .fit])
    }

    @Test func wideRoomShowsThePageAtItsOwnWidth() {
        // Mobile in a 1200×700 room: laid out at 390, not scaled, filling the room's height.
        let layout = PageViewport.layout(width: 390, room: CGSize(width: 1200, height: 700))
        #expect(layout.scale == 1)
        #expect(layout.page == CGSize(width: 390, height: 700))
        #expect(layout.shown == CGSize(width: 390, height: 700))
    }

    @Test func narrowRoomScalesThePageDownKeepingItsShape() {
        // Desktop in a 960×600 room: laid out at 1280, shown at 75%, tall enough to still fill the room.
        let layout = PageViewport.layout(width: 1280, room: CGSize(width: 960, height: 600))
        #expect(layout.scale == 0.75)
        #expect(layout.page == CGSize(width: 1280, height: 800))
        #expect(layout.shown == CGSize(width: 960, height: 600))
        #expect(abs(layout.page.width / layout.page.height - layout.shown.width / layout.shown.height) < 0.0001)
    }

    @Test func fitUsesTheRoomWidth() {
        let layout = PageViewport.layout(width: PageViewport.fit.width, room: CGSize(width: 1000, height: 640))
        #expect(layout.scale == 1)
        #expect(layout.page == CGSize(width: 1000, height: 640))
    }

    @Test func emptyRoomIsSafe() {
        #expect(PageViewport.layout(width: 1280, room: .zero).page == .zero)
    }

    @Test func showAndCloseThePage() {
        let state = AppState()
        state.showLightbox(.page(html: "<h1>Hi</h1>", caption: "Sign-in page", scripts: false))
        guard case let .page(html, caption, scripts) = state.lightbox else { Issue.record("Not a page"); return }
        #expect(html == "<h1>Hi</h1>")
        #expect(caption == "Sign-in page")
        #expect(!scripts)
        #expect(state.lightbox?.caption == "Sign-in page")
        state.closeLightbox()
        #expect(state.lightbox == nil)
    }

    @Test func presetRoundTripsThroughDefaults() {
        let before = AppDefaults.object(forKey: PageViewport.defaultsKey)
        defer { AppDefaults.set(before, forKey: PageViewport.defaultsKey) }
        AppDefaults.removeObject(forKey: PageViewport.defaultsKey)
        #expect(PageViewport.saved == .desktop)
        PageViewport.saved = .tablet
        #expect(AppDefaults.string(forKey: "pageviewport") == "tablet")
        #expect(PageViewport.saved == .tablet)
        // As a launch argument would set it, any case.
        AppDefaults.set("Mobile", forKey: "pageviewport")
        #expect(PageViewport.saved == .mobile)
        AppDefaults.set("huge", forKey: "pageviewport")
        #expect(PageViewport.saved == .desktop)
    }
}

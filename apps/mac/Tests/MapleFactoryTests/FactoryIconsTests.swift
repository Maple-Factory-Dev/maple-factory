import Testing
@testable import MapleFactory

/// Factory icons are cached by the id in their `/icon/<uuid>` link, and only such a link.
struct FactoryIconsTests {
    @Test func onlyAnIconLinkGivesAnIconID() {
        #expect(FactoryIcons.id("/icon/2a6b3f0f-690d-43e0-b7b2-a6c2a738394e") == "2a6b3f0f-690d-43e0-b7b2-a6c2a738394e")
        #expect(FactoryIcons.id("/icon/../secrets") == nil)
        #expect(FactoryIcons.id("/attachments/2a6b3f0f-690d-43e0-b7b2-a6c2a738394e/x.png") == nil)
    }
}

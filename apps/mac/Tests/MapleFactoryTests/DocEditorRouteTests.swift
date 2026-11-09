import Foundation
import Testing
@testable import MapleFactory

/// The docs web view's page URL and navigation policy (review R1.1, R1.3).
struct DocEditorRouteTests {
    private let embed = URL(string: "https://factory.test/app/docs/embed")!

    @Test func themeIsNotPartOfTheSource() {
        let source = DocEditorView.Source.live(url: embed, token: "t")
        #expect(DocEditorView.pageURL(source, dark: true)?.absoluteString == "https://factory.test/app/docs/embed?theme=dark")
        #expect(DocEditorView.pageURL(source, dark: false)?.absoluteString == "https://factory.test/app/docs/embed?theme=light")
    }

    @Test func onlyTheEmbedLoadsInPlace() {
        let page = DocEditorView.pageURL(.live(url: embed, token: "t"), dark: false)
        #expect(DocEditorView.route(URL(string: "https://factory.test/app/docs/embed?theme=dark")!, embed: page, isMainFrame: true) == .allow)
        #expect(DocEditorView.route(URL(string: "https://factory.test/app/#/task/MF-12")!, embed: page, isMainFrame: true) == .task("MF-12"))
        #expect(DocEditorView.route(URL(string: "https://factory.test/app/docs")!, embed: page, isMainFrame: true) == .external)
        #expect(DocEditorView.route(URL(string: "https://example.com/app/docs/embed")!, embed: page, isMainFrame: true) == .external)
    }

    @Test func demoEmbedLoadsInPlace() {
        let page = DocEditorView.pageURL(.demo(markdown: ""), dark: true)
        #expect(DocEditorView.route(page!, embed: page, isMainFrame: true) == .allow)
    }
}

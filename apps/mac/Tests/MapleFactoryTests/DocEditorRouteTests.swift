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

    /// MF-387: the diagram frames load in place (live, including the server's .html → extensionless redirect, and the
    /// bundled demo page); a main-frame move to another page still leaves.
    @Test func diagramSubframesLoadInPlace() {
        let live = DocEditorView.pageURL(.live(url: embed, token: "t"), dark: false)
        #expect(DocEditorView.route(URL(string: "https://factory.test/app/mermaid/diagram.html?mode=inline")!, embed: live, isMainFrame: false) == .allow)
        #expect(DocEditorView.route(URL(string: "https://factory.test/app/mermaid/diagram?mode=viewer")!, embed: live, isMainFrame: false) == .allow)
        #expect(DocEditorView.route(URL(string: "https://factory.test/app/mermaid/diagram?mode=inline")!, embed: live, isMainFrame: true) == .external)
        let demo = DocEditorView.pageURL(.demo(markdown: ""), dark: false)
        #expect(DocEditorView.route(URL(string: "maple-docs://embed/app/mermaid/diagram.html?mode=inline")!, embed: demo, isMainFrame: false) == .allow)
    }

    /// The bundled diagram page must let its own script load on the maple-docs scheme: WebKit doesn't match
    /// `'self'` for the opaque-origin sandboxed frame there, which left the demo doc's diagram unrendered.
    @Test func bundledDiagramPageAllowsItsSchemeScripts() throws {
        let page = try #require(Bundle.module.url(forResource: "diagram", withExtension: "html"))
        let html = try String(contentsOf: page, encoding: .utf8)
        #expect(html.contains("script-src 'self' 'unsafe-inline' file: \(DocsEmbedScheme.scheme):"))
    }

    // MARK: peers bridge event (MF-381)

    @Test func peerKeepsItsAvatar() {
        let peer = DocEditorStatus.Peer.parse(["login": "octo", "name": "Octo Cat", "color": "#ff0000", "avatar": "https://avatars.githubusercontent.com/u/1"])
        #expect(peer == .init(login: "octo", name: "Octo Cat", color: "#ff0000", avatar: "https://avatars.githubusercontent.com/u/1"))
    }

    @Test func peerWithoutAvatarHasNone() {
        #expect(DocEditorStatus.Peer.parse(["login": "octo", "name": "Octo"])?.avatar == nil)
        #expect(DocEditorStatus.Peer.parse(["login": "octo", "avatar": ""])?.avatar == nil)
        #expect(DocEditorStatus.Peer.parse(["login": "octo", "avatar": NSNull()])?.avatar == nil)
    }

    @Test func peerWithoutLoginIsDropped() {
        #expect(DocEditorStatus.Peer.parse(["name": "Ghost", "avatar": "https://x/y.png"]) == nil)
        #expect(DocEditorStatus.Peer.parse(["login": ""]) == nil)
    }

    @Test func peerDefaultsNameAndColor() {
        let peer = DocEditorStatus.Peer.parse(["login": "octo"])
        #expect(peer?.name == "octo")
        #expect(peer?.color == "#888888")
    }

    // MARK: bridge messages from subframes (MF-387 review)

    @Test func subframesMayOnlySendFrameDiagnostics() {
        #expect(DocEditorView.acceptsMessage("frame", isMainFrame: false))
        for type in ["openTask", "command", "error", "ready", "status", "synced", "peers"] {
            #expect(!DocEditorView.acceptsMessage(type, isMainFrame: false))
            #expect(DocEditorView.acceptsMessage(type, isMainFrame: true))
        }
    }
}

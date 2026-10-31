import Foundation
import Testing
@testable import MapleFactory

/// ArtifactFiles.page: the CSP meta is the first thing in the page (after a leading doctype), so it lands in
/// the implicit <head> ahead of every tag. A <header>, or a script before <head>, must not move it into <body>.
struct ArtifactPageTests {
    private let meta = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(ArtifactFiles.csp)\">"

    private func page(_ html: String) -> String { ArtifactFiles.page(Data(html.utf8), kind: .html) }

    @Test func headerOnlyPageGetsTheMetaFirst() {
        let html = "<html><body><header>Hi</header><script>fetch('https://x')</script></body></html>"
        #expect(page(html) == meta + html)
    }

    @Test func scriptBeforeHeadComesAfterTheMeta() {
        let html = "<script>fetch('https://x')</script><img src=https://x/a.png><html><head><title>t</title></head></html>"
        #expect(page(html) == meta + html)
    }

    @Test func headInACommentDoesNotMoveIt() {
        let html = "<!-- <head> --><p>x</p>"
        #expect(page(html) == meta + html)
    }

    @Test func leadingDoctypeStaysFirst() {
        let html = "  <!DOCTYPE html>\n<html><head></head><body><header></header></body></html>"
        #expect(page(html) == "  <!DOCTYPE html>" + meta + "\n<html><head></head><body><header></header></body></html>")
    }
}

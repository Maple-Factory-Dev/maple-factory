import Testing
@testable import MapleKit

@Suite struct MarkdownTests {
    @Test func headingsAndParagraphs() {
        let blocks = MarkdownBlock.parse("# Title\n\nSome text\nmore text\n\n### Small")
        #expect(blocks == [.heading(level: 1, text: "Title"), .paragraph("Some text more text"), .heading(level: 3, text: "Small")])
    }

    @Test func lists() {
        let blocks = MarkdownBlock.parse("- one\n* two\n1. first\n- [ ] todo\n- [x] done\n> quoted\n---")
        #expect(blocks == [.bullet("one"), .bullet("two"), .numbered(1, "first"),
                           .task(checked: false, text: "todo"), .task(checked: true, text: "done"),
                           .quote("quoted"), .rule])
    }

    @Test func fences() {
        let blocks = MarkdownBlock.parse("```swift\nlet a = 1\n```swift\n```\nafter")
        #expect(blocks == [.code(language: "swift", lines: ["let a = 1", "```swift"]), .paragraph("after")])
        #expect(MarkdownBlock.parse("```\nopen") == [.code(language: nil, lines: ["open"])])
    }

    @Test func imagesAndFiles() {
        let blocks = MarkdownBlock.parse("![shot.png](/attachments/abc)\n[log.txt](/attachments/def)\n[site](https://x.dev)")
        #expect(blocks == [.image(alt: "shot.png", path: "/attachments/abc"),
                           .file(name: "log.txt", path: "/attachments/def"),
                           .paragraph("[site](https://x.dev)")])
    }
}

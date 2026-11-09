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

    @Test func tables() {
        let source = "| Name | Size | Done |\n|:-----|:----:|-----:|\n| `a` | **big** | yes |\n| b | small | no |\n\nafter"
        #expect(MarkdownBlock.parse(source) == [
            .table(header: ["Name", "Size", "Done"], alignments: [.leading, .center, .trailing],
                   rows: [["`a`", "**big**", "yes"], ["b", "small", "no"]]),
            .paragraph("after"),
        ])
    }

    @Test func tableEscapedPipesAndRaggedRows() {
        let blocks = MarkdownBlock.parse("| a | b |\n|---|---|\n| x \\| y | z | extra |\n| only |")
        #expect(blocks == [.table(header: ["a", "b"], alignments: [.leading, .leading],
                                  rows: [["x | y", "z"], ["only", ""]])])
    }

    @Test func tableWithoutOuterPipes() {
        #expect(MarkdownBlock.parse("a | b\n--- | ---\n1 | 2") ==
                [.table(header: ["a", "b"], alignments: [.leading, .leading], rows: [["1", "2"]])])
    }

    @Test func pipesWithoutDelimiterStayParagraph() {
        #expect(MarkdownBlock.parse("| a | b |\n| c | d |") == [.paragraph("| a | b | | c | d |")])
        // A delimiter row with the wrong number of cells isn't one.
        #expect(MarkdownBlock.parse("| a | b |\n|---|") == [.paragraph("| a | b | |---|")])
    }

    @Test func tableInsideFenceStaysCode() {
        #expect(MarkdownBlock.parse("```\n| a |\n|---|\n```") == [.code(language: nil, lines: ["| a |", "|---|"])])
    }

    @Test func tableRightAfterParagraph() {
        #expect(MarkdownBlock.parse("Intro line\n| a |\n|---|\n| 1 |\nnot a row") == [
            .paragraph("Intro line"),
            .table(header: ["a"], alignments: [.leading], rows: [["1"]]),
            .paragraph("not a row"),
        ])
    }
}

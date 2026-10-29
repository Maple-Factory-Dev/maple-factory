import Foundation
import SwiftUI
import Testing
@testable import MapleFactory

/// `#` references another task: the picker's query and ranking, the plain ID it inserts, and which IDs
/// rendered Markdown links (MF-50).
@MainActor struct TaskRefTests {
    private let tasks = [
        FactoryTask(id: "MF-1", title: "Login page", state: .merged, detail: ""),
        FactoryTask(id: "MF-12", title: "Reference other tickets", state: .building, detail: ""),
        FactoryTask(id: "MF-13", title: "Mention people", state: .reviewing, detail: ""),
        FactoryTask(id: "MF-20", title: "Fix the MF-1 logo", state: .planning, detail: ""),
        FactoryTask(id: "MF-21", title: "Logging", state: .drafting, detail: ""),
    ]

    @Test func aHashStartsAReferenceButNotInsideAWordOrURL() {
        #expect(TaskRefQuery.at("#", cursor: 1) == TaskRefQuery(range: NSRange(location: 0, length: 1), query: ""))
        #expect(TaskRefQuery.at("see #MF-1", cursor: 9) == TaskRefQuery(range: NSRange(location: 4, length: 5), query: "MF-1"))
        #expect(TaskRefQuery.at("(#lo", cursor: 4)?.query == "lo")
        #expect(TaskRefQuery.at("a#b", cursor: 3) == nil)
        #expect(TaskRefQuery.at("foo#bar", cursor: 7) == nil)
        #expect(TaskRefQuery.at("https://x.dev/page#top", cursor: 22) == nil)
        #expect(TaskRefQuery.at("#MF-1 done", cursor: 10) == nil)
    }

    @Test func tasksRankByIDThenTitleWordThenAnywhere() {
        #expect(TaskRefQuery.matches(tasks, "MF-1").map(\.id) == ["MF-1", "MF-13", "MF-12", "MF-20"])
        #expect(TaskRefQuery.matches(tasks, "mf-12").map(\.id) == ["MF-12"])
        #expect(TaskRefQuery.matches(tasks, "log").map(\.id) == ["MF-21", "MF-20", "MF-1"])
        #expect(TaskRefQuery.matches(tasks, "ence").map(\.id) == ["MF-12"])
        #expect(TaskRefQuery.matches(tasks, "zzz").isEmpty)
        let many = (1...10).map { FactoryTask(id: "MF-\($0)", title: "", state: .building, detail: "") }
        #expect(TaskRefQuery.matches(many, "").count == 6)
    }

    @Test func pickingATaskInsertsItsPlainID() {
        let text = "blocked on #MF-1"
        let query = TaskRefQuery.at(text, cursor: (text as NSString).length)!
        let out = query.inserting(tasks[1], into: text)
        #expect(out.text == "blocked on MF-12 ")
        #expect(out.cursor == 17)
    }

    @Test func onlyKnownWordBoundedIDsLink() {
        let known: Set = ["MF-12", "MF-3"]
        let ids = { (text: String) in TaskRefQuery.references(in: text, known: known).map(\.id) }
        #expect(ids("see MF-12.") == ["MF-12"])
        #expect(ids("(#MF-12) and MF-3") == ["MF-12", "MF-3"])
        #expect(TaskRefQuery.references(in: "#MF-12", known: known).first?.range == NSRange(location: 0, length: 6))
        for plain in ["UTF-8 and ISO-8601", "foo#bar a#b", "MF-99 is unknown", "XMF-12", "MF-12a", "MF-12-x", "a#MF-12"] {
            #expect(ids(plain).isEmpty, "\(plain)")
        }
    }

    @Test func renderedReferencesGetAMapleTaskLinkButNotInCode() throws {
        var text = try AttributedString(markdown: "see MF-12, `MF-12` and UTF-8", options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        MarkdownPreview.linkTasks(in: &text, known: ["MF-12"])
        let links = text.runs.compactMap { run in run.link.map { (String(text[run.range].characters), $0) } }
        #expect(links.count == 1)
        #expect(links.first?.0 == "MF-12")
        #expect(links.first?.1 == URL(string: "maple-task://MF-12"))
        #expect(TaskRefQuery.id(from: URL(string: "maple-task://MF-12")!) == "MF-12")
        #expect(TaskRefQuery.id(from: URL(string: "https://x.dev")!) == nil)
    }
}

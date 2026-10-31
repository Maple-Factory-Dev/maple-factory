import Foundation
import Testing
@testable import MapleFactory

/// Hovering rendered Markdown finds the task reference under the pointer by character offset (MF-122).
struct TaskRefHoverTests {
    private let known: Set<String> = ["MF-116", "MF-12"]

    @Test func anOffsetInsideABareReferenceMapsToItsID() {
        let text = "Blocked on MF-116 for now"
        for offset in 11..<17 {
            #expect(TaskRefQuery.reference(at: offset, in: text, known: known)?.id == "MF-116")
        }
        #expect(TaskRefQuery.reference(at: 10, in: text, known: known) == nil)
        #expect(TaskRefQuery.reference(at: 17, in: text, known: known) == nil)
    }

    @Test func aHashPrefixedReferenceIncludesTheHash() {
        let text = "see #MF-116."
        let ref = TaskRefQuery.reference(at: 4, in: text, known: known)
        #expect(ref?.id == "MF-116")
        #expect(ref?.range == NSRange(location: 4, length: 7))
        #expect(TaskRefQuery.reference(at: 9, in: text, known: known)?.id == "MF-116")
        #expect(TaskRefQuery.reference(at: 11, in: text, known: known) == nil)
    }

    @Test func lookalikesAndPlainWordsAreNotReferences() {
        let text = "UTF-8 and XMF-12 and words"
        for offset in 0..<(text as NSString).length {
            #expect(TaskRefQuery.reference(at: offset, in: text, known: known) == nil)
        }
    }

    @Test func anUnknownIDMapsToNothing() {
        #expect(TaskRefQuery.reference(at: 3, in: "MF-999 is gone", known: known) == nil)
        #expect(TaskRefQuery.reference(at: 3, in: "MF-116", known: []) == nil)
    }

    // MF-147: the card on an overlap link lists the files the two tasks share.

    @Test func noFilesShowsNoSection() {
        let summary = TaskHovercard.filesSummary([])
        #expect(summary.shown.isEmpty)
        #expect(summary.more == nil)
    }

    @Test func aFewFilesAllShow() {
        let files = ["server/src/env.ts", "server/src/util.ts", "server/README.md"]
        let summary = TaskHovercard.filesSummary(files)
        #expect(summary.shown == files)
        #expect(summary.more == nil)
    }

    @Test func manyFilesShowFiveAndCountTheRest() {
        let files = (1...8).map { "src/file\($0).ts" }
        let summary = TaskHovercard.filesSummary(files)
        #expect(summary.shown == Array(files.prefix(5)))
        #expect(summary.more == "+3 more")
    }

    @MainActor @Test func anIDTheFactoryDoesntHaveOpensNoCard() {
        let tasks = [FactoryTask(id: "MF-89", title: "Security audit", state: .reviewing, detail: "")]
        #expect(TaskIDHover.task("MF-89", in: tasks)?.title == "Security audit")
        #expect(TaskIDHover.task("MF-999", in: tasks) == nil)
        #expect(TaskIDHover.task("MF-89", in: []) == nil)
    }
}

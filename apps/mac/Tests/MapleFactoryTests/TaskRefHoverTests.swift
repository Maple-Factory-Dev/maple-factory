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
}

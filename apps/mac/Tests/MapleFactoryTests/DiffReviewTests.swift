import Foundation
import Testing
@testable import MapleFactory

/// The Diff tab as a review (MF-88): the file tree built from the diff's paths, picking lines and the
/// note (lines, side, snippet) they make, and where GitHub's review threads land.
@MainActor struct DiffReviewTests {
    private func file(_ path: String) -> DiffFile { DiffFile(path: path, added: 1, removed: 0) }

    private let patch = """
    diff --git a/lib/auth/jwt.ts b/lib/auth/jwt.ts
    --- a/lib/auth/jwt.ts
    +++ b/lib/auth/jwt.ts
    @@ -10,6 +10,7 @@ export type TokenClaims
     const a = 1;
    -const b = 2;
    +const b = 3;
    +const c = 4;
     const d = 5;
    -const e = 6;
     const f = 7;
    @@ -40,3 +41,3 @@
     one();
    -two();
    +three();
    """

    private var lines: [DiffLine] { DiffReview.rows(DiffFile.parse(patch)[0].hunks) }

    // MARK: Tree

    @Test func folderChainsFoldIntoOneRowAndFoldersComeFirst() {
        let tree = DiffTreeNode.build([
            file("README.md"),
            file("app/api/auth/refresh/route.ts"),
            file("app/api/auth/login/route.ts"),
            file("lib/auth/jwt.ts"),
            file("lib/auth/session.ts"),
            file("lib/http.ts"),
        ])
        #expect(tree.map(\.name) == ["app/api/auth", "lib", "README.md"])
        #expect(tree[0].id == "app/api/auth")
        #expect(tree[0].children.map(\.name) == ["login", "refresh"])
        #expect(tree[0].children[0].children.map(\.id) == ["app/api/auth/login/route.ts"])
        // lib holds a file as well as a folder, so it doesn't fold into lib/auth.
        #expect(tree[1].children.map(\.name) == ["auth", "http.ts"])
        #expect(tree[1].children[0].children.map(\.name) == ["jwt.ts", "session.ts"])
        #expect(tree[1].files.map(\.path) == ["lib/auth/jwt.ts", "lib/auth/session.ts", "lib/http.ts"])
        #expect(tree[2].file?.path == "README.md")
    }

    @Test func aSingleDeepFileFoldsAllTheWay() {
        let tree = DiffTreeNode.build([file("a/b/c/d.swift")])
        #expect(tree.count == 1)
        #expect(tree[0].name == "a/b/c")
        #expect(tree[0].children.map(\.name) == ["d.swift"])
    }

    @Test func filesSortNaturally() {
        let tree = DiffTreeNode.build([file("v10.txt"), file("v2.txt"), file("v1.txt")])
        #expect(tree.map(\.name) == ["v1.txt", "v2.txt", "v10.txt"])
    }

    // MARK: Selection

    @Test func aSelectionCoversBothDirections() {
        var down = LineSelection(path: "x", row: 2)
        down.head = 5
        var up = LineSelection(path: "x", row: 5)
        up.head = 2
        #expect(down.rows == 2...5)
        #expect(up.rows == 2...5)
        #expect(up.contains("x", 3))
        #expect(!up.contains("y", 3))
        #expect(!up.contains("x", 6))
    }

    @Test func aRangeIsNumberedOnTheNewSide() throws {
        // const a (10/10), -b (11), +b (11), +c (12), d (12/13)
        let note = try #require(DiffReview.note(path: "lib/auth/jwt.ts", lines: lines, rows: 0...4, text: "Why?"))
        #expect(note.side == .new)
        #expect(note.start == 10)
        #expect(note.end == 13)
        #expect(note.snippet == " const a = 1;\n-const b = 2;\n+const b = 3;\n+const c = 4;\n const d = 5;")
        #expect(DiffReview.anchor(note) == "lib/auth/jwt.ts:L10–13")
    }

    @Test func removedLinesAloneAreOnTheOldSide() throws {
        let note = try #require(DiffReview.note(path: "lib/auth/jwt.ts", lines: lines, rows: 5...5, text: "Keep this"))
        #expect(note.side == .old)
        #expect(note.start == 13)
        #expect(note.end == 13)
        #expect(note.snippet == "-const e = 6;")
        #expect(DiffReview.anchor(note) == "lib/auth/jwt.ts:L13")
    }

    @Test func aSelectionCanRunIntoTheNextHunk() throws {
        // f (14/14) in the first hunk, then one() (40/41) and -two() (41) in the second.
        let note = try #require(DiffReview.note(path: "p", lines: lines, rows: 6...8, text: "t"))
        #expect(note.side == .new)
        #expect((note.start, note.end) == (14, 41))
        #expect(note.snippet.components(separatedBy: "\n").count == 3)
    }

    @Test func snippetsRoundTripThroughACommentsText() throws {
        let note = try #require(DiffReview.note(path: "p", lines: lines, rows: 1...2, text: "x"))
        let text = "```diff\n\(note.snippet)\n```\nUse 3 here."
        let split = try #require(DiffReview.splitSnippet(text))
        #expect(split.snippet == note.snippet)
        #expect(split.body == "Use 3 here.")
        #expect(DiffReview.splitSnippet("Just a comment") == nil)
    }

    @Test func codeAnchorsParseButOthersDont() {
        #expect(DiffReview.parseAnchor("lib/auth/jwt.ts:L12–18")! == ("lib/auth/jwt.ts", "L12–18"))
        #expect(DiffReview.parseAnchor("a:b.ts:L3")! == ("a:b.ts", "L3"))
        #expect(DiffReview.parseAnchor("Review") == nil)
        #expect(DiffReview.parseAnchor("Step 2: Lint") == nil)
        #expect(DiffReview.parseAnchor("Review · 3 comments") == nil)
    }

    // MARK: Threads

    private func thread(_ id: String, line: UInt32?, side: Wire.DiffSide = .new) -> Wire.ReviewThread {
        Wire.ReviewThread(id: id, path: "lib/auth/jwt.ts", line: line, side: side, resolved: false, outdated: line == nil, comments: [])
    }

    @Test func threadsLandUnderTheirLineOnTheirSide() {
        let placed = DiffReview.place([
            thread("new-c", line: 12),          // +const c
            thread("old-e", line: 13, side: .old), // -const e
            thread("ctx", line: 41),            // one(), context: new 41
            thread("old-two", line: 41, side: .old), // -two()
            thread("gone", line: nil),          // outdated
            thread("far", line: 300),           // not in these hunks
        ], in: lines)
        #expect(placed.rows[3]?.map(\.id) == ["new-c"])
        #expect(placed.rows[5]?.map(\.id) == ["old-e"])
        #expect(placed.rows[7]?.map(\.id) == ["ctx"])
        #expect(placed.rows[8]?.map(\.id) == ["old-two"])
        #expect(placed.elsewhere.map(\.id) == ["gone", "far"])
    }

    @Test func aRemovedLineIsNotFoundByItsOldNumberOnTheNewSide() {
        // New line 11 is +const b, not the removed -const b that was old line 11.
        #expect(DiffReview.row(side: .new, line: 11, in: lines) == 2)
        #expect(DiffReview.row(side: .old, line: 11, in: lines) == 1)
    }

    // MARK: Draft

    @Test func theDraftKeepsNotesUntilCleared() {
        let draft = ReviewDraft()
        #expect(draft.isEmpty)
        draft.add(Wire.ReviewNote(path: "a.ts", start: 1, end: 1, side: .new, snippet: "+x", text: "one"))
        draft.add(Wire.ReviewNote(path: "b.ts", start: 2, end: 3, side: .new, snippet: "+y", text: "two"))
        #expect(draft.paths == ["a.ts", "b.ts"])
        draft.update(draft.notes[0].id, text: "uno")
        #expect(draft.notes[0].note.text == "uno")
        draft.remove(draft.notes[1].id)
        #expect(draft.paths == ["a.ts"])
        draft.clear()
        #expect(draft.isEmpty)
    }

    @Test func theSameTasksDraftComesBack() {
        let state = AppState()
        let draft = state.reviewDraft(for: "ATL-141")
        draft.add(Wire.ReviewNote(path: "a.ts", start: 1, end: 1, side: .new, snippet: "+x", text: "one"))
        #expect(state.reviewDraft(for: "ATL-141").notes.count == 1)
        #expect(state.reviewDraft(for: "ATL-144").isEmpty)
    }
}

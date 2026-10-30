import Testing
@testable import MapleFactory

/// A task made from review findings picked on Statistics (MF-73): its title, its brief and Done when,
/// and the goal it goes to.
@MainActor struct FindingsTaskTests {
    private func finding(_ task: String, _ severity: Wire.Severity, _ text: String, kind: Wire.FindingKind = .code,
                         file: String? = nil, area: String = "(no file)", round: UInt32 = 1) -> Wire.StatsFindingRow {
        Wire.StatsFindingRow(task: task, title: "", kind: kind, severity: severity, text: text, file: file, area: area, raisedIn: round, at: 0)
    }

    @Test func aSingleFindingIsTitledByItsTextShortened() {
        let r = finding("MF-61", .major, "The retry loop never backs off when the server answers 429", file: "server/src/ws.ts:40", area: "server/src", round: 2)
        #expect(FindingsTask.title([r]) == "The retry loop never backs off when the server answers 429")
        let long = finding("MF-61", .minor, String(repeating: "word ", count: 30))
        let title = FindingsTask.title([long])
        #expect(title.hasSuffix("…") && title.count <= 73 && !title.contains("  "))

        let body = FindingsTask.body([r])
        #expect(body.contains("- **Major · code** `server/src/ws.ts:40`: The retry loop never backs off when the server answers 429 (from MF-61, round 2)"))
        #expect(body.contains("## Done when\n- [ ] Resolve: The retry loop never backs off when the server answers 429 (MF-61)"))
    }

    @Test func aBatchListsBlockersThenMajorsThenMinorsWithADoneWhenEach() {
        let rows = [
            finding("MF-1", .minor, "Rename the helper"),
            finding("MF-2", .blocker, "Crashes on empty input"),
            finding("MF-3", .major, "No test for the error path"),
            finding("MF-4", .blocker, "Leaks the token in logs"),
        ]
        #expect(FindingsTask.ordered(rows).map(\.task) == ["MF-2", "MF-4", "MF-3", "MF-1"])
        let body = FindingsTask.body(rows)
        let order = ["Crashes on empty input", "Leaks the token", "No test for the error path", "Rename the helper"].map { body.range(of: $0)!.lowerBound }
        #expect(order == order.sorted())
        #expect(body.hasPrefix("4 review findings to resolve"))
        #expect(body.components(separatedBy: "- [ ] Resolve: ").count == 5)
        #expect(FindingsTask.title(rows) == "Fix 4 review findings")
    }

    @Test func aMissingFileOrTextStillReads() {
        let r = finding("MF-9", .blocker, "", kind: .proof, round: 3)
        let body = FindingsTask.body([r])
        #expect(body.contains("- **Blocker · proof**: (no text kept) (from MF-9, round 3)"))
        #expect(!body.contains("``"))
        #expect(FindingsTask.title([r]) == "Blocker proof finding from MF-9")
        #expect(body.contains("- [ ] Resolve: Blocker proof finding from MF-9 (MF-9)"))
    }

    @Test func aBatchInOneFolderIsTitledByIt() {
        let mac = [finding("MF-1", .major, "a", area: "apps/mac"), finding("MF-2", .minor, "b", area: "apps/mac")]
        #expect(FindingsTask.title(mac) == "Fix 2 review findings in apps/mac")
        let apps = mac + [finding("MF-3", .minor, "c", area: "apps/web"), finding("MF-4", .minor, "d")]
        #expect(FindingsTask.commonArea(apps) == "apps")
        #expect(FindingsTask.title(apps) == "Fix 4 review findings in apps")
        #expect(FindingsTask.commonArea([finding("MF-1", .major, "a", area: "apps/mac"), finding("MF-2", .major, "b", area: "server/src")]) == nil)
        #expect(FindingsTask.commonArea([finding("MF-1", .major, "a")]) == nil)
    }

    @Test func theGoalIsTheOneMostOfTheirTasksAreIn() {
        let tasks = [
            FactoryTask(id: "A-1", goal: "Billing v2", title: "", state: .merged, detail: ""),
            FactoryTask(id: "A-2", goal: "Docs site", title: "", state: .merged, detail: ""),
            FactoryTask(id: "A-3", goal: "Docs site", title: "", state: .merged, detail: ""),
        ]
        let rows = [finding("A-1", .major, "x"), finding("A-2", .minor, "y"), finding("A-3", .minor, "z"), finding("A-1", .minor, "w"), finding("A-3", .major, "v")]
        #expect(FindingsTask.goal(rows, tasks: tasks) == "Docs site")
        // A tie goes to the goal of the first finding picked.
        #expect(FindingsTask.goal([finding("A-1", .major, "x"), finding("A-2", .major, "y")], tasks: tasks) == "Billing v2")
        // Tasks that are gone don't count, and none left means the composer's own pick.
        #expect(FindingsTask.goal([finding("GONE-1", .major, "x"), finding("GONE-2", .major, "y"), finding("A-1", .major, "z")], tasks: tasks) == "Billing v2")
        #expect(FindingsTask.goal([finding("GONE-1", .major, "x")], tasks: tasks) == nil)
    }

    @Test func composingOpensNewTaskOnTheirGoal() {
        let state = AppState()
        state.composeFromFindings([finding("BIL-88", .blocker, "Proration rounds the wrong way"), finding("BIL-91", .major, "Webhook retries double-charge")])
        #expect(state.isComposing)
        #expect(state.draft.goal == "Billing v2")
        #expect(state.draft.goalChosen)
        #expect(state.draft.title == "Fix 2 review findings")
        #expect(state.draft.body.contains("(from BIL-88, round 1)") && state.draft.body.contains("(from BIL-91, round 1)"))

        // None of their tasks left: the goal a plain New Task would pick.
        let plain = AppState()
        plain.startCompose()
        let fallback = AppState()
        fallback.composeFromFindings([finding("GONE-1", .major, "Gone")])
        #expect(fallback.isComposing)
        #expect(fallback.draft.goal == plain.draft.goal)
        #expect(fallback.draft.goalChosen == plain.draft.goalChosen)
    }

    @Test func pickedFindingsComeInTheListsOrderOnce() {
        let rows = [finding("MF-1", .minor, "a"), finding("MF-2", .major, "b"), finding("MF-1", .minor, "a", round: 2)]
        let f = Wire.StatsFindings(outcomes: Wire.StatsFindingOutcomes(fixed: 0, disputed: 0, open: 0, unknown: 0), recent: rows + [rows[0]])
        let keys: Set = [rows[2].pickKey, rows[0].pickKey]
        #expect(FindingsView.picked(keys, in: f).map(\.raisedIn) == [1, 2])
    }
}

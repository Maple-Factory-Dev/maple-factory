import Foundation
import Testing
@testable import MapleFactory

/// MF-404: the composer's unsent brief survives Esc, ⌘N and a relaunch, until it's sent or discarded.
@MainActor struct UnsentDraftTests {
    /// A mockup AppState on Inbox with nothing open, keeping its drafts in its own UserDefaults suite.
    private func makeState(_ defaults: UserDefaults? = nil) -> AppState {
        let state = AppState()
        state.taskGoalDefaults = defaults ?? UserDefaults(suiteName: "UnsentDraftTests.\(UUID().uuidString)")!
        state.destination = .inbox
        state.showInspector = false
        state.focusedTask = nil
        return state
    }

    /// Types a brief into a plain New Task, the way the person would.
    private func typeBrief(_ state: AppState) {
        state.startCompose()
        state.draft.title = "Passkeys on the login page"
        state.draft.body = "Long brief\n\n## Done when\n- [ ] it works"
        state.draft.goal = "Billing v2"
        state.draft.tickets = [TicketLink(system: .linear, key: "LIN-7", title: "Passkeys", status: "Todo")]
    }

    @Test func escThenNewTaskBringsTheBriefBack() {
        let state = makeState()
        typeBrief(state)
        let typed = state.draft
        state.cancelCompose()
        #expect(!state.isComposing)
        #expect(state.hasUnsentDraft)
        state.startCompose()
        #expect(state.isComposing)
        #expect(state.draft == typed)
        #expect(!state.hasUnsentDraft)
    }

    @Test func plainNewTaskWithNothingTypedStartsFreshOnTheUsualGoal() {
        let state = makeState()
        state.draft.goal = "Somewhere else"  // A goal alone isn't a draft.
        #expect(state.draft.isEmpty)
        #expect(!state.hasUnsentDraft)
        state.startCompose()
        #expect(state.draft.goal == state.newTaskGoal.name)
        #expect(state.draft.title.isEmpty)
    }

    @Test func specificComposersStartFreshAndParkTheBriefUntilSent() {
        let state = makeState()
        typeBrief(state)
        let typed = state.draft
        state.cancelCompose()

        // Turn into Task from a note: its own composer, the brief set aside.
        let note = UUID()
        state.startCompose(title: "From a note", body: "Note body", fromNote: note)
        #expect(state.draft.title == "From a note")
        #expect(state.draft.fromNote == note)
        #expect(state.parkedDraft == typed)
        #expect(state.toast?.text.hasPrefix("Kept your unsent draft") == true)

        // Findings while that's open: the slot's taken, so the note's composer stays as it was.
        let fromNote = state.draft
        state.composeFromFindings([Wire.StatsFindingRow(task: "MF-1", title: "", kind: .code, severity: .major, text: "A finding", area: "(no file)", raisedIn: 1, at: 0)])
        #expect(state.parkedDraft == typed)
        #expect(state.draft == fromNote)
        #expect(state.toast?.text.hasPrefix("Finish or discard this draft first") == true)

        state.submitDraft(sendToPlanning: false)
        #expect(state.parkedDraft == nil)
        #expect(state.draft == typed)
        state.startCompose()
        #expect(state.draft == typed)
    }

    /// R1.1: specific, type, Esc, specific — the second brief isn't replaced while the first is set aside.
    @Test func aFullSlotNeverSilentlyReplacesAnUnsentBrief() {
        let state = makeState()
        typeBrief(state)
        let first = state.draft
        state.cancelCompose()
        state.startCompose(goal: "Docs site")
        #expect(state.parkedDraft == first)
        state.draft.title = "Second brief"
        state.draft.body = "Typed into the goal's composer"
        let second = state.draft
        state.cancelCompose()

        state.startCompose(goal: "Billing v2")
        #expect(state.isComposing)
        #expect(state.draft == second)
        #expect(state.parkedDraft == first)
        #expect(state.toast?.text.hasPrefix("Finish or discard this draft first") == true)

        // Discarding the second brings the first back; then a specific composer parks it again.
        state.discardDraft()
        #expect(state.draft == first)
        #expect(state.parkedDraft == nil)
        state.startCompose(goal: "Billing v2")
        #expect(state.parkedDraft == first)
        #expect(state.draft.title.isEmpty)
    }

    @Test func aRequestsComposerParksTheBriefAndDiscardBringsItBack() {
        let state = makeState()
        typeBrief(state)
        let typed = state.draft
        state.cancelCompose()
        state.startCompose(goal: "Docs site", title: "A request", body: "From Slack")
        #expect(state.draft.title == "A request")
        #expect(state.parkedDraft == typed)
        state.discardDraft()
        #expect(!state.isComposing)
        #expect(state.parkedDraft == nil)
        #expect(state.hasUnsentDraft)
        state.startCompose()
        #expect(state.draft == typed)
    }

    @Test func theBriefSurvivesARelaunchOnTheSameDefaults() {
        let first = makeState()
        typeBrief(first)
        let typed = first.draft
        first.cancelCompose()

        let relaunched = makeState(first.taskGoalDefaults)
        #expect(relaunched.draft == typed)
        #expect(relaunched.hasUnsentDraft)
        relaunched.startCompose()
        #expect(relaunched.draft == typed)
    }

    @Test func aParkedBriefSurvivesARelaunchToo() {
        let first = makeState()
        typeBrief(first)
        let typed = first.draft
        first.startCompose(goal: "Docs site", title: "Findings", body: "…")

        let relaunched = makeState(first.taskGoalDefaults)
        #expect(relaunched.parkedDraft == typed)
        #expect(relaunched.hasUnsentDraft)
    }

    @Test func sendClearsTheStoredDraft() {
        let state = makeState()
        typeBrief(state)
        #expect(UnsentDraft.load(factory: nil, defaults: state.taskGoalDefaults) != nil)
        state.submitDraft(sendToPlanning: true)
        #expect(state.draft.isEmpty)
        #expect(!state.hasUnsentDraft)
        #expect(UnsentDraft.load(factory: nil, defaults: state.taskGoalDefaults) == nil)
        state.startCompose()
        #expect(state.draft.title.isEmpty)
    }

    @Test func discardClearsTheStoredDraftAndClosesTheComposer() {
        let state = makeState()
        typeBrief(state)
        state.discardDraft()
        #expect(!state.isComposing)
        #expect(state.draft.isEmpty)
        #expect(UnsentDraft.load(factory: nil, defaults: state.taskGoalDefaults) == nil)
        #expect(!makeState(state.taskGoalDefaults).hasUnsentDraft)
    }

    @Test func saveToScratchpadClearsIt() {
        let state = makeState()
        typeBrief(state)
        state.saveDraftAsNote()
        #expect(state.draft.isEmpty)
        #expect(UnsentDraft.load(factory: nil, defaults: state.taskGoalDefaults) == nil)
    }

    @Test func aRefusedSendKeepsTheBrief() {
        let state = makeState()
        state.startCompose()
        state.draft.body = "No title yet"
        state.submitDraft(sendToPlanning: true)  // Refused: no title.
        #expect(state.draft.body == "No title yet")
        #expect(UnsentDraft.load(factory: nil, defaults: state.taskGoalDefaults)?.body == "No title yet")
    }

    @Test func eachFactoryKeepsItsOwn() {
        let defaults = UserDefaults(suiteName: "UnsentDraftTests.\(UUID().uuidString)")!
        let a = URL(string: "https://a.example.com")!, b = URL(string: "https://b.example.com:8443")!
        var draft = ComposeDraft()
        draft.title = "For A"
        UnsentDraft.store(draft, key: UnsentDraft.key(a), defaults: defaults)
        #expect(UnsentDraft.load(factory: a, defaults: defaults)?.title == "For A")
        #expect(UnsentDraft.load(factory: b, defaults: defaults) == nil)
        #expect(UnsentDraft.load(factory: nil, defaults: defaults) == nil)
        #expect(UnsentDraft.key(b) == "unsentDraft.b.example.com:8443")
        #expect(UnsentDraft.key(b, parked: true) == "unsentDraft.b.example.com:8443.parked")
    }

    @Test func aDraftWhoseGoalIsGoneGetsTheUsualGoal() {
        let state = makeState()
        typeBrief(state)
        state.draft.goal = "Docs site"
        state.cancelCompose()
        state.taskGoalGoals = FactoryData.seedGoals.map { goal in
            var goal = goal
            if goal.name == "Docs site" { goal.archived = true }
            return goal
        }
        state.startCompose()
        #expect(state.draft.title == "Passkeys on the login page")
        #expect(state.draft.goal != "Docs site")
        #expect(state.draft.goal == state.newTaskGoal.name)
    }

    @Test func aPlainAppStateNeitherReadsNorWritesDrafts() {
        let state = AppState()
        #expect(state.unsentDraftKey == nil)
        state.draft.title = "Not kept anywhere"
        #expect(state.unsentDraftKey == nil)
    }
}

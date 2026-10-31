import SwiftUI
import Testing
@testable import MapleFactory

/// The goal editor's palette and its Agent instructions layers (MF-113).
struct GoalEditorTests {
    /// The six colors goals had before the palette grew keep their swatches, whatever the hex's case.
    @Test func legacyHexesMatchTheirSwatches() {
        let legacy = ["#2EA043", "#3B82F6", "#8B5CF6", "#F59E0B", "#EC4899", "#14B8A6"]
        for (index, hex) in legacy.enumerated() {
            #expect(GoalColors.choice(for: hex) == .swatch(index))
            #expect(GoalColors.choice(for: hex.lowercased()) == .swatch(index))
        }
        #expect(GoalColors.palette.prefix(6).map(\.name) == ["Green", "Blue", "Violet", "Amber", "Pink", "Teal"])
    }

    @Test func paletteHasSixteenDistinctColors() {
        #expect(GoalColors.palette.count == 16)
        #expect(Set(GoalColors.palette.map { $0.hex.uppercased() }).count == 16)
        #expect(Set(GoalColors.palette.map(\.name)).count == 16)
        #expect(GoalColors.choice(for: "#6366F1") == .swatch(GoalColors.palette.firstIndex { $0.name == "Indigo" }!))
    }

    /// A hex that isn't in the palette is Custom, not Green, and saves as it was.
    @Test func offPaletteHexIsCustomAndSavesUnchanged() {
        let choice = GoalColors.choice(for: "#123abc")
        #expect(choice == .custom("#123abc"))
        #expect(choice.hex == "#123abc")
    }

    @Test func pickedColorsBecomeHex() {
        #expect(GoalColors.hex(Color(hexString: "#6366F1")!) == "#6366F1")
    }

    private func prompts(builder: String) -> Wire.PromptAdditions {
        Wire.PromptAdditions(planner: "", builder: builder, reviewer: "")
    }

    @Test func layersAreBuiltInThenOrgThenGoal() {
        let layers = PromptLayers(role: .builder, org: prompts(builder: "Run swift test."), goal: prompts(builder: "Don't touch the server."))
        #expect(layers.layers.map(\.source) == [.builtIn, .org, .goal])
        #expect(layers.layers.map(\.editable) == [false, false, true])
        #expect(layers.org == "Run swift test.")
        #expect(layers.goal == "Don't touch the server.")
        #expect(PromptLayers.all(org: nil, goal: nil).map(\.role) == [.planner, .builder, .reviewer])
    }

    @Test func statusForEachCombination() {
        let org = prompts(builder: "Org says")
        let goal = prompts(builder: "Goal says")
        // Both: the goal's adds to the org's.
        #expect(PromptLayers(role: .builder, org: org, goal: goal).status == .addsToOrg)
        // Goal only: it's the only addition.
        #expect(PromptLayers(role: .builder, org: nil, goal: goal).status == .onlyAddition)
        #expect(PromptLayers(role: .builder, org: prompts(builder: "  \n"), goal: goal).status == .onlyAddition)
        // Org only, or neither: the goal adds nothing.
        #expect(PromptLayers(role: .builder, org: org, goal: nil).status == .notSet)
        #expect(PromptLayers(role: .builder, org: org, goal: prompts(builder: "   ")).status == .notSet)
        #expect(PromptLayers(role: .builder, org: nil, goal: nil).status == .notSet)
        // Each role reads its own text.
        #expect(PromptLayers(role: .planner, org: org, goal: goal).status == .notSet)
    }

    // MARK: Leaving the editor (MF-140)

    /// A sidebar, palette or link move closes the editor, New or Edit, instead of leaving it over the page.
    @MainActor @Test(arguments: [MachineSheet.new, .edit("g1")])
    func goingToAPageClosesTheEditor(sheet: MachineSheet) {
        let state = AppState()
        state.goalSheet = sheet
        state.goalPrefill = Wire.NewGoalIdea(name: "Idea", summary: "", repos: [])
        state.destination = .inbox
        #expect(state.goalSheet == nil)
        #expect(state.goalPrefill == nil)

        // Clicking the page already on screen counts too.
        state.goalSheet = sheet
        state.destination = .inbox
        #expect(state.goalSheet == nil)
    }

    @MainActor @Test(arguments: [MachineSheet.new, .edit("g1")])
    func openingATaskClosesTheEditor(sheet: MachineSheet) {
        let state = AppState()
        state.goalSheet = sheet
        state.openFocus("ONB-19")
        #expect(state.goalSheet == nil)
        #expect(state.focusedTask == "ONB-19")

        state.goalSheet = sheet
        state.openFullView("ONB-19")
        #expect(state.goalSheet == nil)
    }

    @MainActor @Test func openingTheEditorLeavesThePage() {
        let state = AppState()
        state.destination = .inbox
        state.goalSheet = .new
        #expect(state.destination == .inbox)
        #expect(state.goalSheet == .new)
    }
}

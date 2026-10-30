import Testing
@testable import MapleFactory

/// What the ⌘K palette ranks and filters for what's typed.
@MainActor
struct CommandPaletteTests {
    private let me = FactoryData.me
    private let teammate = Person(name: "Sam Rivera", color: .blue, isHuman: true, github: "sam")

    private func task(_ id: String, _ title: String, goal: String = "Auth overhaul", _ state: TaskState = .building,
                      mine: Bool = true, needsYou: Bool = false) -> FactoryTask {
        FactoryTask(id: id, goal: goal, title: title, state: state, owner: mine ? me : teammate, detail: "", needsYou: needsYou)
    }

    private var tasks: [FactoryTask] {
        [task("MF-10", "Passkey sign-in", .reviewing),
         task("MF-11", "Fix MF-12 flaky test", goal: "Mac app", .building, mine: false),
         task("MF-12", "Dark mode polish", goal: "Mac app", .reviewing, mine: false),
         task("MF-13", "Passkey recovery codes", .planning, needsYou: true),
         task("MF-14", "Old merged thing", .merged)]
    }

    private let goals = ["Auth overhaul", "Mac app"]

    private func results(_ query: String) -> [PaletteSection] {
        CommandPaletteModel.results(query: query, tasks: tasks, goals: goals, me: me.id)
    }

    private func items(_ query: String, _ kind: PaletteSection.Kind) -> [PaletteItem] {
        results(query).first { $0.kind == kind }?.items ?? []
    }

    @Test func idMatchBeatsTitleMatch() {
        #expect(items("mf-12", .tasks).first == .task("MF-12"))
        #expect(items("MF-12", .tasks).contains(.task("MF-11")))
    }

    @Test func titleWordsRankAndMustAllMatch() {
        #expect(items("passkey", .tasks) == [.task("MF-10"), .task("MF-13")])
        #expect(items("passkey recovery", .tasks) == [.task("MF-13")])
        #expect(results("passkey").first?.kind == .tasks)
    }

    @Test func goalFilterNarrows() {
        #expect(items("goal:mac", .tasks) == [.task("MF-11"), .task("MF-12")])
        #expect(items("goal:macapp dark", .tasks) == [.task("MF-12")])
    }

    @Test func stateFilterNarrowsToTasksOnly() {
        let sections = results("state:reviewing")
        #expect(sections.map(\.kind) == [.tasks])
        #expect(sections[0].items == [.task("MF-10"), .task("MF-12")])
        #expect(items("state:awaiting-approval", .tasks).isEmpty)
        #expect(items("state:review", .tasks).count == 2)
    }

    @Test func mineFilterKeepsYourTasks() {
        #expect(items("mine", .tasks) == [.task("MF-10"), .task("MF-13"), .task("MF-14")])
        #expect(items("mine state:reviewing", .tasks) == [.task("MF-10")])
    }

    @Test func pagesAndActionsMatchByName() {
        #expect(items("inbox", .pages).first == .page(PalettePage.all[0]))
        #expect(results("inbox").first?.kind == .pages)
        #expect(items("settings", .actions) == [.action(.settings)])
        #expect(items("preferences", .actions) == [.action(.settings)])
        #expect(items("new task", .actions).first == .action(.newTask))
        #expect(items("mac", .goals) == [.goal("Mac app")])
    }

    @Test func emptyQueryGivesDefaults() {
        let sections = results("  ")
        #expect(sections.map(\.kind) == [.tasks, .actions])
        // Needs you first, nothing finished.
        #expect(sections[0].items.first == .task("MF-13"))
        #expect(!sections[0].items.contains(.task("MF-14")))
        #expect(sections[1].items == [.action(.newTask), .action(.newGoal), .action(.settings)])
    }

    @Test func noMatchGivesNoSections() {
        #expect(results("zzqx").isEmpty)
        #expect(results("state:nonsense").isEmpty)
    }

    @Test func sectionsAreCapped() {
        let many = (1...20).map { task("MF-\($0)", "Thing \($0)") }
        let sections = CommandPaletteModel.results(query: "thing", tasks: many, goals: [], me: me.id)
        #expect(sections.first?.items.count == PaletteSection.Kind.tasks.limit)
    }

    @Test func fuzzyMatchesLettersInOrder() {
        #expect(CommandPaletteModel.fieldScore("pskey", "passkey") != nil)
        #expect(CommandPaletteModel.fieldScore("pk", "a long title with p and much later k") == nil)
    }
}

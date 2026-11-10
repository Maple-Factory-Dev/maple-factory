import Foundation
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

    @Test func stopTheLineIsFoundByItsKeywords() {
        for query in ["hold merges", "freeze", "incident", "andon", "pause merges", "stop the line"] {
            #expect(items(query, .actions).first == .action(.stopTheLine), "\(query)")
        }
        #expect(items("restart the line", .actions).first == .action(.restartTheLine))
    }

    @Test func docTitleQueryFindsTheDoc() {
        let docs = [PaletteDoc(id: "d1", title: "Onboarding plan", goal: "Auth overhaul"), PaletteDoc(id: "d2", title: "Release notes")]
        let sections = CommandPaletteModel.results(query: "onboarding", tasks: tasks, goals: goals, docs: docs, me: me.id)
        #expect(sections.first { $0.kind == .docs }?.items == [.doc("d1")])
        let byKeyword = CommandPaletteModel.results(query: "doc", tasks: tasks, goals: goals, docs: docs, me: me.id)
        #expect(byKeyword.first { $0.kind == .docs }?.items.count == 2)
        #expect(items("new doc", .actions).first == .action(.newDoc))
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

    @Test func themeFindsTheThreeThemeActions() {
        #expect(items("theme", .actions) == [.action(.themeSystem), .action(.themeLight), .action(.themeDark)])
        #expect(items("appearance", .actions) == [.action(.themeSystem), .action(.themeLight), .action(.themeDark)])
        #expect(Set(items("mode", .actions)) == [.action(.themeSystem), .action(.themeLight), .action(.themeDark)])
    }

    @Test func darkAndLightRankTheirThemeFirst() {
        #expect(items("dark", .actions).first == .action(.themeDark))
        #expect(items("light", .actions).first == .action(.themeLight))
    }

    @Test func themeActionsMapToAppearance() {
        #expect(PaletteAction.themeSystem.appearance == .system)
        #expect(PaletteAction.themeLight.appearance == .light)
        #expect(PaletteAction.themeDark.appearance == .dark)
        #expect(PaletteAction.newTask.appearance == nil)
        #expect(PaletteAction.themeDark.icon == Appearance.dark.icon)
        #expect(PaletteAction.themeDark.shortcut.isEmpty)
    }

    @Test func themeActionsStayOutOfTheDefaults() {
        #expect(items("", .actions) == [.action(.newTask), .action(.newGoal), .action(.settings)])
    }

    // MARK: This task

    private func thisTask(_ state: TaskState, _ ctx: TaskActionContext = TaskActionContext(), mine: Bool = true,
                          pr: Bool = false) -> [PaletteItem] {
        var open = task("MF-20", "Open task", state, mine: mine)
        if pr { open.pr = PullRequest(number: 3, state: .open, checks: [], link: URL(string: "https://github.com/a/b/pull/3")) }
        var ctx = ctx
        ctx.isMine = mine
        let sections = CommandPaletteModel.results(query: "", tasks: tasks + [open], goals: goals, me: me.id,
                                                   openTask: (open, TaskActions.palette(open, ctx)))
        #expect(sections.first?.kind == .thisTask)
        #expect(sections.first?.title == "This task · MF-20")
        return sections.first?.items ?? []
    }

    private func actions(_ items: [PaletteItem]) -> [TaskAction] {
        items.compactMap { if case .taskAction(_, let action) = $0 { action } else { nil } }
    }

    @Test func awaitingApprovalLeadsWithApprovePlan() {
        let rows = actions(thisTask(.awaitingApproval))
        #expect(rows.first == .approvePlan)
        #expect(rows == [.approvePlan, .sendToBacklog, .cancel, .assign, .moveToGoal, .rename, .copyID, .copyLink])
        #expect(!rows.contains(.retry) && !rows.contains(.merge))
    }

    @Test func approvedByMeDropsApprovePlan() {
        #expect(!actions(thisTask(.awaitingApproval, TaskActionContext(iApproved: true))).contains(.approvePlan))
    }

    @Test func reviewingOffersMergeOnlyWhenClearAndNotMerging() {
        #expect(actions(thisTask(.reviewing, TaskActionContext(canMerge: true))).first == .merge)
        #expect(!actions(thisTask(.reviewing, TaskActionContext(canMerge: true, isMerging: true))).contains(.merge))
        #expect(!actions(thisTask(.reviewing, TaskActionContext(canMerge: false))).contains(.merge))
    }

    @Test func finishedTasksDropCancelAndRetry() {
        let merged = actions(thisTask(.merged))
        #expect(!merged.contains(.cancel) && !merged.contains(.retry))
        #expect(merged == [.copyID, .copyLink])
        #expect(!actions(thisTask(.cancelled)).contains(.cancel))
    }

    @Test func teammatesTaskOffersTakeItOver() {
        #expect(actions(thisTask(.building, mine: false)).contains(.takeOver))
        #expect(!actions(thisTask(.building)).contains(.takeOver))
    }

    @Test func openPullRequestNeedsARemotePR() {
        #expect(actions(thisTask(.reviewing, pr: true)).contains(.openPullRequest))
        #expect(!actions(thisTask(.reviewing)).contains(.openPullRequest))
    }

    @Test func moveToGoalNeedsATarget() {
        #expect(!actions(thisTask(.building, TaskActionContext(hasMoveTargets: false))).contains(.moveToGoal))
    }

    @Test func typedQueryRanksThisTaskFirstOnATie() {
        let open = task("MF-20", "Open task", .awaitingApproval)
        let sections = CommandPaletteModel.results(query: "approve", tasks: tasks + [open], goals: goals, me: me.id,
                                                   openTask: (open, TaskActions.palette(open, TaskActionContext())))
        #expect(sections.first?.kind == .thisTask)
        #expect(sections.first?.items.first == .taskAction("MF-20", .approvePlan))
    }

    @Test func moveTargetsListTheGoals() {
        let sections = CommandPaletteModel.moveTargets(query: "", task: "MF-20", goals: ["Mac app", "Docs"])
        #expect(sections.first?.items == [.moveTarget("MF-20", "Mac app"), .moveTarget("MF-20", "Docs")])
        #expect(CommandPaletteModel.moveTargets(query: "mac", task: "MF-20", goals: ["Mac app", "Docs"]).first?.items.count == 1)
        #expect(CommandPaletteModel.moveTargets(query: "zzqx", task: "MF-20", goals: ["Mac app"]).isEmpty)
    }

    // MARK: Pages and everyday actions

    @Test func decisionsPageIsFound() {
        #expect(items("decisions", .pages).first?.id == "page:\(Destination.decisions.encoded)")
    }

    @Test func snoozeAndResumeFlipWithSnoozed() {
        let on = PaletteAction.available(taskPanel: true, signedIn: true, holds: 0, notificationsOn: true, snoozed: false)
        #expect(on.contains(.snoozeNotifications1h) && on.contains(.snoozeUntilTomorrow) && !on.contains(.resumeNotifications))
        let snoozed = PaletteAction.available(taskPanel: true, signedIn: true, holds: 0, notificationsOn: true, snoozed: true)
        #expect(!snoozed.contains(.snoozeNotifications1h) && !snoozed.contains(.snoozeUntilTomorrow) && snoozed.contains(.resumeNotifications))
        let found = CommandPaletteModel.results(query: "snooze", tasks: tasks, goals: goals, actions: on, me: me.id)
        #expect(found.first { $0.kind == .actions }?.items == [.action(.snoozeNotifications1h), .action(.snoozeUntilTomorrow)])
    }

    @Test func everydayActionsAreFound() {
        #expect(items("check for updates", .actions).first == .action(.checkForUpdates))
        #expect(PaletteAction.checkForUpdates.shortcut == "⇧⌘U")
        #expect(items("add factory", .actions).first == .action(.addFactory))
        #expect(items("keyboard shortcuts", .actions).first == .action(.keyboardShortcuts))
    }

    @Test func factoryAndPaneRowsOnlyWhenSearched() {
        let factories = [PaletteFactory(id: "acme.dev", name: "Acme")]
        let panes = OrgSettingsView.sidebarPanes
        let empty = CommandPaletteModel.results(query: "", tasks: tasks, goals: goals, me: me.id, factories: factories, panes: panes)
        #expect(!empty.contains { $0.kind == .factories || $0.kind == .settings })
        let acme = CommandPaletteModel.results(query: "acme", tasks: tasks, goals: goals, me: me.id, factories: factories, panes: panes)
        #expect(acme.first { $0.kind == .factories }?.items == [.factory("acme.dev")])
        let merging = CommandPaletteModel.results(query: "merging", tasks: tasks, goals: goals, me: me.id, factories: factories, panes: panes)
        #expect(merging.first { $0.kind == .settings }?.items.first == .settingsPane(.merging))
    }

    // MARK: Recent

    @Test func recentIsShownOrderedAndDedupedAgainstTasks() {
        let recent: [PaletteItem] = [.task("MF-12"), .doc("d1"), .task("MF-10"), .task("MF-12")]
        let sections = CommandPaletteModel.results(query: "", tasks: tasks, goals: goals, me: me.id, recent: recent)
        #expect(sections.map(\.kind) == [.recent, .tasks, .actions])
        #expect(sections[0].items == [.task("MF-12"), .doc("d1"), .task("MF-10")])
        #expect(!sections[1].items.contains(.task("MF-12")) && !sections[1].items.contains(.task("MF-10")))
    }

    @Test func recentLeavesOutTheOpenTaskAndIsCapped() {
        let open = tasks[0]
        let recent = [PaletteItem.task(open.id)] + (1...8).map { PaletteItem.doc("d\($0)") }
        let sections = CommandPaletteModel.results(query: "", tasks: tasks, goals: goals, me: me.id,
                                                   openTask: (open, [.copyID]), recent: recent)
        #expect(sections.map(\.kind).prefix(2) == [.thisTask, .recent])
        #expect(!sections[1].items.contains(.task(open.id)))
        #expect(sections[1].items.count == PaletteSection.Kind.recent.limit)
    }

    @Test func noRecentNoSection() {
        #expect(!results("").contains { $0.kind == .recent })
    }

    @Test func recentListIsNewestFirstDedupedAndCapped() {
        var list: [PaletteItem] = []
        for n in 1...12 { list = PaletteRecent.adding(.task("MF-\(n)"), to: list) }
        list = PaletteRecent.adding(.task("MF-5"), to: list)
        #expect(list.count == PaletteRecent.cap)
        #expect(list.first == .task("MF-5"))
        #expect(list.filter { $0 == .task("MF-5") }.count == 1)
        #expect(PaletteRecent.adding(.action(.newTask), to: list) == list)
        #expect(PaletteRecent.decode(PaletteRecent.encode(.doc("x:y"))!) == .doc("x:y"))
    }
}

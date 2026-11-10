import Foundation
import MapleKit

/// Something the ⌘K palette can run that isn't a place: the menu's common commands.
enum PaletteAction: String, CaseIterable, Hashable {
    case newTask, newGoal, newDoc, toggleSidebar, toggleTaskPanel, settings, themeSystem, themeLight, themeDark, sendFeedback, stopTheLine, restartTheLine
    case checkForUpdates, addFactory, snoozeNotifications1h, snoozeUntilTomorrow, resumeNotifications, keyboardShortcuts

    /// The actions to offer: the task panel only with peeking on; Stop the line only signed in to a factory,
    /// and Restart the line only while it's stopped; Snooze while notifications are on and not snoozed, Resume otherwise.
    static func available(taskPanel: Bool, signedIn: Bool, holds: Int, notificationsOn: Bool = true,
                          snoozed: Bool = false) -> [PaletteAction] {
        allCases.filter { action in
            switch action {
            case .toggleTaskPanel: taskPanel
            case .stopTheLine: signedIn
            case .restartTheLine: signedIn && holds > 0
            case .snoozeNotifications1h, .snoozeUntilTomorrow: notificationsOn && !snoozed
            case .resumeNotifications: snoozed || !notificationsOn
            default: true
            }
        }
    }

    /// The theme a "Theme: …" action switches to; nil for the rest.
    var appearance: Appearance? {
        switch self {
        case .themeSystem: .system
        case .themeLight: .light
        case .themeDark: .dark
        default: nil
        }
    }

    var title: String {
        switch self {
        case .newTask: "New task"
        case .newGoal: "New goal…"
        case .newDoc: "New doc"
        case .toggleSidebar: "Toggle sidebar"
        case .toggleTaskPanel: "Toggle task panel"
        case .settings: "Settings…"
        case .themeSystem: "Theme: System"
        case .themeLight: "Theme: Light"
        case .themeDark: "Theme: Dark"
        case .sendFeedback: "Send feedback…"
        case .stopTheLine: "Stop the line…"
        case .restartTheLine: "Restart the line"
        case .checkForUpdates: "Check for updates…"
        case .addFactory: "Add factory…"
        case .snoozeNotifications1h: "Snooze notifications for 1 hour"
        case .snoozeUntilTomorrow: "Snooze notifications until tomorrow"
        case .resumeNotifications: "Resume notifications"
        case .keyboardShortcuts: "Keyboard shortcuts"
        }
    }

    var icon: String {
        switch self {
        case .newTask: "plus"
        case .newGoal: "scope"
        case .newDoc: "doc.badge.plus"
        case .toggleSidebar: "sidebar.left"
        case .toggleTaskPanel: "sidebar.right"
        case .settings: "gearshape"
        case .themeSystem, .themeLight, .themeDark: appearance!.icon
        case .sendFeedback: "bubble.left.and.exclamationmark.bubble.right"
        case .stopTheLine: "hand.raised.fill"
        case .restartTheLine: "play.fill"
        case .checkForUpdates: "arrow.down.circle"
        case .addFactory: "plus.rectangle.on.rectangle"
        case .snoozeNotifications1h, .snoozeUntilTomorrow: "bell.slash"
        case .resumeNotifications: "bell"
        case .keyboardShortcuts: "keyboard"
        }
    }

    var shortcut: String {
        switch self {
        case .newTask: "⌘N"
        case .newGoal: "⇧⌘N"
        case .toggleSidebar: "⌃⌘S"
        case .toggleTaskPanel: "⌥⌘I"
        case .settings: "⌘,"
        case .checkForUpdates: "⇧⌘U"
        case .newDoc, .themeSystem, .themeLight, .themeDark, .sendFeedback, .stopTheLine, .restartTheLine,
             .addFactory, .snoozeNotifications1h, .snoozeUntilTomorrow, .resumeNotifications, .keyboardShortcuts: ""
        }
    }

    /// Other words people type for it.
    var keywords: [String] {
        switch self {
        case .newTask: ["create", "add", "compose", "brief"]
        case .newGoal: ["create", "add", "project"]
        case .newDoc: ["create", "add", "doc", "plan", "spec", "write", "page"]
        case .toggleSidebar: ["hide", "show", "collapse", "expand"]
        case .toggleTaskPanel: ["hide", "show", "inspector", "peek"]
        case .settings: ["preferences", "options", "config"]
        case .themeSystem: ["theme", "appearance", "mode", "color scheme", "auto"]
        case .themeLight: ["theme", "appearance", "mode", "color scheme", "light mode"]
        case .themeDark: ["theme", "appearance", "mode", "color scheme", "dark mode"]
        case .sendFeedback: ["bug", "report", "idea", "beta", "help", "contact", "suggestion"]
        case .stopTheLine: ["hold merges", "freeze", "incident", "andon", "pause merges", "merge hold"]
        case .restartTheLine: ["lift hold", "release merges", "unfreeze", "resume merges", "andon"]
        case .checkForUpdates: ["update", "upgrade", "version", "new version"]
        case .addFactory: ["new factory", "connect", "sign in", "server", "switch"]
        case .snoozeNotifications1h: ["mute", "quiet", "do not disturb", "dnd", "silence", "notifications", "pause"]
        case .snoozeUntilTomorrow: ["mute", "quiet", "do not disturb", "dnd", "silence", "notifications", "pause"]
        case .resumeNotifications: ["unmute", "unsnooze", "notifications", "turn on", "alerts"]
        case .keyboardShortcuts: ["help", "keys", "hotkeys", "cheat sheet", "shortcuts"]
        }
    }
}

/// A page the palette jumps to, with the name and icon the sidebar gives it.
struct PalettePage: Hashable {
    let destination: Destination
    let title: String
    let icon: String
    var keywords: [String] = []

    static let all: [PalettePage] = [
        PalettePage(destination: .inbox, title: "Inbox", icon: "tray", keywords: ["approvals", "mentions"]),
        PalettePage(destination: .myTasks, title: "My tasks", icon: "checkmark.circle", keywords: ["mine"]),
        PalettePage(destination: .dayReport, title: "Day report", icon: "doc.text", keywords: ["eod", "standup", "today", "report"]),
        PalettePage(destination: .needsHand, title: "Needs a hand", icon: "hand.raised", keywords: ["help", "stuck"]),
        PalettePage(destination: .intake, title: "Requests", icon: "tray.and.arrow.down", keywords: ["intake"]),
        PalettePage(destination: .activity, title: "Activity", icon: "waveform.path.ecg", keywords: ["feed"]),
        PalettePage(destination: .scratchpad, title: "Scratchpad", icon: "note.text", keywords: ["notes", "ideas"]),
        PalettePage(destination: .usage, title: "Usage", icon: "gauge.with.dots.needle.33percent", keywords: ["tokens", "cost"]),
        PalettePage(destination: .statistics, title: "Statistics", icon: "chart.bar.xaxis", keywords: ["stats", "findings"]),
        PalettePage(destination: .machines, title: "Machines", icon: "cpu", keywords: ["runners"]),
        PalettePage(destination: .allGoals, title: "All goals", icon: "scope", keywords: ["goals"]),
        PalettePage(destination: .docs, title: "Docs", icon: "doc.richtext", keywords: ["open docs", "plans", "specs", "notes"]),
        PalettePage(destination: .decisions, title: "Decisions", icon: "checkmark.seal", keywords: ["decided", "adr", "choices", "proposed"]),
    ]
}

/// A shared doc as ⌘K searches it: title, then its goal and words like "doc" and "plan".
struct PaletteDoc: Hashable {
    let id: String
    let title: String
    var goal: String? = nil
}

/// A saved factory ⌘K can switch to.
struct PaletteFactory: Hashable {
    let id: String
    let name: String
}

/// One row in the palette.
enum PaletteItem: Hashable, Identifiable {
    case task(String)
    case goal(String)
    case page(PalettePage)
    case action(PaletteAction)
    case doc(String)
    /// One of the open task's actions, in "This task".
    case taskAction(String, TaskAction)
    /// Switch to a saved factory.
    case factory(String)
    /// Settings, opened on a pane.
    case settingsPane(OrgSettingsView.Pane)
    /// "Move to goal…"'s sub-list: move the task to this goal.
    case moveTarget(String, String)

    var id: String {
        switch self {
        case .task(let id): "task:\(id)"
        case .goal(let name): "goal:\(name)"
        case .page(let page): "page:\(page.destination.encoded)"
        case .action(let action): "action:\(action.rawValue)"
        case .doc(let id): "doc:\(id)"
        case .taskAction(let task, let action): "taskAction:\(task):\(action.rawValue)"
        case .factory(let id): "factory:\(id)"
        case .settingsPane(let pane): "settings:\(pane.rawValue)"
        case .moveTarget(let task, let goal): "move:\(task):\(goal)"
        }
    }
}

struct PaletteSection: Equatable {
    enum Kind: CaseIterable {
        case thisTask, recent, tasks, docs, goals, pages, actions, factories, settings, moveTargets

        var title: String {
            switch self {
            case .thisTask: "This task"
            case .recent: "Recent"
            case .factories: "Factories"
            case .settings: "Settings"
            case .moveTargets: "Move to goal"
            case .tasks: "Tasks"
            case .docs: "Docs"
            case .goals: "Goals"
            case .pages: "Go to"
            case .actions: "Actions"
            }
        }

        var limit: Int {
            switch self {
            case .tasks: 8
            case .thisTask, .moveTargets: 30
            case .recent, .docs, .goals, .pages, .actions, .factories, .settings: 5
            }
        }
    }

    let kind: Kind
    let items: [PaletteItem]
    /// "This task"'s task, which its header names.
    var taskID: String? = nil

    var title: String { taskID.map { "\(kind.title) · \($0)" } ?? kind.title }
}

/// What ⌘K shows for what's typed: ranked tasks, goals, pages and actions. Pure, so it's tested on its own.
enum CommandPaletteModel {
    /// What's typed, split into filter tokens (`goal:auth`, `state:reviewing`, `mine`) and words to match.
    struct Query: Equatable {
        var words: [String] = []
        var goal: String? = nil
        var state: String? = nil
        var mine = false

        var filters: Bool { goal != nil || state != nil || mine }
        var isEmpty: Bool { words.isEmpty && !filters }

        init(_ text: String) {
            for token in text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init) {
                if token.hasPrefix("goal:"), token.count > 5 { goal = String(token.dropFirst(5)) }
                else if token.hasPrefix("state:"), token.count > 6 { state = String(token.dropFirst(6)) }
                else if token == "mine" { mine = true }
                else { words.append(token) }
            }
        }
    }

    /// The sections to show, best match first; empty sections are left out. Filter tokens narrow to tasks only.
    static func results(query text: String, tasks: [FactoryTask], goals: [String], pages: [PalettePage] = PalettePage.all,
                        actions: [PaletteAction] = PaletteAction.allCases, docs: [PaletteDoc] = [], me: String,
                        openTask: (task: FactoryTask, actions: [TaskAction])? = nil, recent: [PaletteItem] = [],
                        factories: [PaletteFactory] = [], panes: [OrgSettingsView.Pane] = []) -> [PaletteSection] {
        let query = Query(text)
        let thisTask = openTask.map { open in
            (open.task.id, open.actions.map { PaletteItem.taskAction(open.task.id, $0) })
        }
        if query.isEmpty { return defaults(tasks: tasks, actions: actions, thisTask: thisTask, recent: recent) }

        let filtered = tasks.filter { matches($0, query, me: me) }
        let rankedTasks: [(PaletteItem, Int)] = filtered.compactMap { task in
            guard let score = taskScore(task, query.words) else { return nil }
            return (.task(task.id), score)
        }
        var scored: [(PaletteSection.Kind, [(PaletteItem, Int)])] = []
        // First, so it wins a tie with another section.
        if let open = openTask, !query.filters {
            scored.append((.thisTask, open.actions.compactMap { action in
                score(query.words, [action.title], also: action.keywords).map { (.taskAction(open.task.id, action), $0) }
            }))
        }
        scored.append((.tasks, rankedTasks))
        if !query.filters {
            scored.append((.docs, docs.compactMap { doc in
                score(query.words, [doc.title], also: [doc.goal ?? "", "doc", "plan"]).map { (.doc(doc.id), $0) }
            }))
            scored.append((.goals, goals.compactMap { name in score(query.words, [name]).map { (.goal(name), $0) } }))
            scored.append((.pages, pages.compactMap { page in score(query.words, [page.title], also: page.keywords).map { (.page(page), $0) } }))
            scored.append((.actions, actions.compactMap { action in score(query.words, [action.title], also: action.keywords).map { (.action(action), $0) } }))
            scored.append((.factories, factories.compactMap { factory in
                score(query.words, ["Switch to \(factory.name)"], also: ["factory", "org"]).map { (.factory(factory.id), $0) }
            }))
            scored.append((.settings, panes.compactMap { pane in
                score(query.words, [pane.title], also: ["settings", "preferences"]).map { (.settingsPane(pane), $0) }
            }))
        }

        // Each section best first (ties keep their order); sections by their best row, then Tasks · Goals · Go to · Actions.
        let sections = scored.compactMap { kind, rows -> (PaletteSection, Int)? in
            let sorted = rows.enumerated().sorted { a, b in a.element.1 != b.element.1 ? a.element.1 > b.element.1 : a.offset < b.offset }
            guard let best = sorted.first?.element.1 else { return nil }
            return (PaletteSection(kind: kind, items: sorted.prefix(kind.limit).map(\.element.0),
                                   taskID: kind == .thisTask ? openTask?.task.id : nil), best)
        }
        return sections.enumerated()
            .sorted { a, b in a.element.1 != b.element.1 ? a.element.1 > b.element.1 : a.offset < b.offset }
            .map(\.element.0)
    }

    /// The rows in the order ↑/↓ moves through them.
    static func flatten(_ sections: [PaletteSection]) -> [PaletteItem] { sections.flatMap(\.items) }

    /// Nothing typed: the open task's actions, where you've just been, what needs you, then what's moving,
    /// and the common actions.
    private static func defaults(tasks: [FactoryTask], actions: [PaletteAction], thisTask: (String, [PaletteItem])?,
                                 recent: [PaletteItem]) -> [PaletteSection] {
        var seen = Set<PaletteItem>()
        let lately = recent.filter { item in
            if case .task(let id) = item, id == thisTask?.0 { return false }
            return seen.insert(item).inserted
        }.prefix(PaletteSection.Kind.recent.limit)
        let open = tasks.filter { !$0.state.isFinished && $0.id != thisTask?.0 && !lately.contains(.task($0.id)) }
        let moving = open.filter { $0.needsYou || $0.hand != nil } + open.filter { !$0.needsYou && $0.hand == nil }
        let common = actions.filter { $0 == .newTask || $0 == .newGoal || $0 == .settings }
        return [
            PaletteSection(kind: .thisTask, items: thisTask?.1 ?? [], taskID: thisTask?.0),
            PaletteSection(kind: .recent, items: Array(lately)),
            PaletteSection(kind: .tasks, items: moving.prefix(PaletteSection.Kind.tasks.limit).map { .task($0.id) }),
            PaletteSection(kind: .actions, items: common.map { .action($0) }),
        ].filter { !$0.items.isEmpty }
    }

    /// "Move to goal…": the goals the task can move to, narrowed by what's typed.
    static func moveTargets(query text: String, task: String, goals: [String]) -> [PaletteSection] {
        let words = Query(text).words
        let items = goals.filter { words.isEmpty || score(words, [$0]) != nil }.map { PaletteItem.moveTarget(task, $0) }
        return items.isEmpty ? [] : [PaletteSection(kind: .moveTargets, items: items, taskID: task)]
    }

    private static func matches(_ task: FactoryTask, _ query: Query, me: String) -> Bool {
        if query.mine && task.owner.id != me { return false }
        if let goal = query.goal, !squash(task.goal).contains(squash(goal)) { return false }
        if let state = query.state, !squash(task.state.title).hasPrefix(squash(state)) && !"\(task.state)".lowercased().hasPrefix(squash(state)) {
            return false
        }
        return true
    }

    /// An id match beats the title, which beats the goal and state. With only filters, every task scores the same,
    /// unfinished ones first.
    private static func taskScore(_ task: FactoryTask, _ words: [String]) -> Int? {
        SearchRank.taskScore(words, id: task.id, title: task.title, goal: task.goal, state: task.state.title,
                             finished: task.state.isFinished)
    }

    private static func score(_ words: [String], _ names: [String], also keywords: [String] = []) -> Int? {
        SearchRank.score(words, names, also: keywords)
    }

    static func fieldScore(_ word: String, _ field: String) -> Int? { SearchRank.fieldScore(word, field) }

    /// Lowercased with spaces and dashes gone, so `state:awaiting-approval` and `goal:authoverhaul` match.
    private static func squash(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

/// ⌘K's Recent list: newest first, no repeats, at most 10, saved as `task:<id>` / `doc:<id>` strings.
enum PaletteRecent {
    static let cap = 10

    static func adding(_ item: PaletteItem, to list: [PaletteItem]) -> [PaletteItem] {
        guard encode(item) != nil else { return list }
        return Array(([item] + list.filter { $0 != item }).prefix(cap))
    }

    static func encode(_ item: PaletteItem) -> String? {
        switch item {
        case .task(let id): "task:\(id)"
        case .doc(let id): "doc:\(id)"
        default: nil
        }
    }

    static func decode(_ text: String) -> PaletteItem? {
        if text.hasPrefix("task:") { return .task(String(text.dropFirst(5))) }
        if text.hasPrefix("doc:") { return .doc(String(text.dropFirst(4))) }
        return nil
    }
}

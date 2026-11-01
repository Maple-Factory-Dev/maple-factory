import Foundation

/// Something the ⌘K palette can run that isn't a place: the menu's common commands.
enum PaletteAction: String, CaseIterable, Hashable {
    case newTask, newGoal, toggleSidebar, toggleTaskPanel, settings, themeSystem, themeLight, themeDark

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
        case .toggleSidebar: "Toggle sidebar"
        case .toggleTaskPanel: "Toggle task panel"
        case .settings: "Settings…"
        case .themeSystem: "Theme: System"
        case .themeLight: "Theme: Light"
        case .themeDark: "Theme: Dark"
        }
    }

    var icon: String {
        switch self {
        case .newTask: "plus"
        case .newGoal: "scope"
        case .toggleSidebar: "sidebar.left"
        case .toggleTaskPanel: "sidebar.right"
        case .settings: "gearshape"
        case .themeSystem, .themeLight, .themeDark: appearance!.icon
        }
    }

    var shortcut: String {
        switch self {
        case .newTask: "⌘N"
        case .newGoal: "⇧⌘N"
        case .toggleSidebar: "⌃⌘S"
        case .toggleTaskPanel: "⌥⌘I"
        case .settings: "⌘,"
        case .themeSystem, .themeLight, .themeDark: ""
        }
    }

    /// Other words people type for it.
    var keywords: [String] {
        switch self {
        case .newTask: ["create", "add", "compose", "brief"]
        case .newGoal: ["create", "add", "project"]
        case .toggleSidebar: ["hide", "show", "collapse", "expand"]
        case .toggleTaskPanel: ["hide", "show", "inspector", "peek"]
        case .settings: ["preferences", "options", "config"]
        case .themeSystem: ["theme", "appearance", "mode", "color scheme", "auto"]
        case .themeLight: ["theme", "appearance", "mode", "color scheme", "light mode"]
        case .themeDark: ["theme", "appearance", "mode", "color scheme", "dark mode"]
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
        PalettePage(destination: .needsHand, title: "Needs a hand", icon: "hand.raised", keywords: ["help", "stuck"]),
        PalettePage(destination: .intake, title: "Requests", icon: "tray.and.arrow.down", keywords: ["intake"]),
        PalettePage(destination: .activity, title: "Activity", icon: "waveform.path.ecg", keywords: ["feed"]),
        PalettePage(destination: .scratchpad, title: "Scratchpad", icon: "note.text", keywords: ["notes", "ideas"]),
        PalettePage(destination: .usage, title: "Usage", icon: "gauge.with.dots.needle.33percent", keywords: ["tokens", "cost"]),
        PalettePage(destination: .statistics, title: "Statistics", icon: "chart.bar.xaxis", keywords: ["stats", "findings"]),
        PalettePage(destination: .machines, title: "Machines", icon: "cpu", keywords: ["runners"]),
        PalettePage(destination: .allGoals, title: "All goals", icon: "scope", keywords: ["goals"]),
    ]
}

/// One row in the palette.
enum PaletteItem: Hashable, Identifiable {
    case task(String)
    case goal(String)
    case page(PalettePage)
    case action(PaletteAction)

    var id: String {
        switch self {
        case .task(let id): "task:\(id)"
        case .goal(let name): "goal:\(name)"
        case .page(let page): "page:\(page.destination.encoded)"
        case .action(let action): "action:\(action.rawValue)"
        }
    }
}

struct PaletteSection: Equatable {
    enum Kind: CaseIterable {
        case tasks, goals, pages, actions

        var title: String {
            switch self {
            case .tasks: "Tasks"
            case .goals: "Goals"
            case .pages: "Go to"
            case .actions: "Actions"
            }
        }

        var limit: Int {
            switch self {
            case .tasks: 8
            case .goals, .pages, .actions: 5
            }
        }
    }

    let kind: Kind
    let items: [PaletteItem]
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
                        actions: [PaletteAction] = PaletteAction.allCases, me: String) -> [PaletteSection] {
        let query = Query(text)
        if query.isEmpty { return defaults(tasks: tasks, actions: actions) }

        let filtered = tasks.filter { matches($0, query, me: me) }
        let rankedTasks: [(PaletteItem, Int)] = filtered.compactMap { task in
            guard let score = taskScore(task, query.words) else { return nil }
            return (.task(task.id), score)
        }
        var scored: [(PaletteSection.Kind, [(PaletteItem, Int)])] = [(.tasks, rankedTasks)]
        if !query.filters {
            scored.append((.goals, goals.compactMap { name in score(query.words, [name]).map { (.goal(name), $0) } }))
            scored.append((.pages, pages.compactMap { page in score(query.words, [page.title], also: page.keywords).map { (.page(page), $0) } }))
            scored.append((.actions, actions.compactMap { action in score(query.words, [action.title], also: action.keywords).map { (.action(action), $0) } }))
        }

        // Each section best first (ties keep their order); sections by their best row, then Tasks · Goals · Go to · Actions.
        let sections = scored.compactMap { kind, rows -> (PaletteSection, Int)? in
            let sorted = rows.enumerated().sorted { a, b in a.element.1 != b.element.1 ? a.element.1 > b.element.1 : a.offset < b.offset }
            guard let best = sorted.first?.element.1 else { return nil }
            return (PaletteSection(kind: kind, items: sorted.prefix(kind.limit).map(\.element.0)), best)
        }
        return sections.enumerated()
            .sorted { a, b in a.element.1 != b.element.1 ? a.element.1 > b.element.1 : a.offset < b.offset }
            .map(\.element.0)
    }

    /// The rows in the order ↑/↓ moves through them.
    static func flatten(_ sections: [PaletteSection]) -> [PaletteItem] { sections.flatMap(\.items) }

    /// Nothing typed: what needs you, then what's moving, and the common actions.
    private static func defaults(tasks: [FactoryTask], actions: [PaletteAction]) -> [PaletteSection] {
        let open = tasks.filter { !$0.state.isFinished }
        let recent = open.filter { $0.needsYou || $0.hand != nil } + open.filter { !$0.needsYou && $0.hand == nil }
        let common = actions.filter { $0 == .newTask || $0 == .newGoal || $0 == .settings }
        return [
            PaletteSection(kind: .tasks, items: recent.prefix(PaletteSection.Kind.tasks.limit).map { .task($0.id) }),
            PaletteSection(kind: .actions, items: common.map { .action($0) }),
        ].filter { !$0.items.isEmpty }
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
        let finished = task.state.isFinished ? 0 : 1
        guard !words.isEmpty else { return finished }
        var total = 0
        for word in words {
            let id = fieldScore(word, task.id).map { $0 * 2 } ?? 0
            let title = fieldScore(word, task.title) ?? 0
            let other = max(fieldScore(word, task.goal) ?? 0, fieldScore(word, task.state.title) ?? 0) / 2
            let best = max(id, title, other)
            guard best > 0 else { return nil }
            total += best
        }
        return total * 2 + finished
    }

    /// Every word has to match a name (or, weaker, a keyword); the sum of each word's best.
    private static func score(_ words: [String], _ names: [String], also keywords: [String] = []) -> Int? {
        var total = 0
        for word in words {
            let name = names.compactMap { fieldScore(word, $0) }.max() ?? 0
            let keyword = (keywords.compactMap { fieldScore(word, $0) }.max() ?? 0) / 2
            let best = max(name, keyword)
            guard best > 0 else { return nil }
            total += best
        }
        return total
    }

    /// How well one typed word matches a field: exact, prefix, a word's start, anywhere, then in order with gaps.
    static func fieldScore(_ word: String, _ field: String) -> Int? {
        let field = field.lowercased()
        if field == word { return 1000 }
        if field.hasPrefix(word) { return 800 }
        if field.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(word) }) { return 600 }
        if field.contains(word) { return 400 }
        return fuzzy(word, field)
    }

    /// The word's letters in order, close together: 100 for a tight run, less as it spreads out.
    private static func fuzzy(_ word: String, _ field: String) -> Int? {
        guard word.count >= 2 else { return nil }
        let letters = Array(field)
        var index = 0, first: Int? = nil
        for char in word {
            while index < letters.count && letters[index] != char { index += 1 }
            guard index < letters.count else { return nil }
            if first == nil { first = index }
            index += 1
        }
        let span = index - first!
        guard span <= word.count * 3 else { return nil }
        return max(1, 100 - (span - word.count) * 10)
    }

    /// Lowercased with spaces and dashes gone, so `state:awaiting-approval` and `goal:authoverhaul` match.
    private static func squash(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

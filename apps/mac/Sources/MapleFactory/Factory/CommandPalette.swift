import SwiftUI

/// ⌘K: a search field over every task, goal, page and common action, driven from the keyboard.
struct CommandPalette: View {
    static let width: CGFloat = 620
    static let rowHeight: CGFloat = 36

    @Environment(AppState.self) private var state
    @Environment(FactoryClient.self) private var client
    @AppStorage("appearance") private var appearance = Appearance.system
    @FocusState private var fieldFocused: Bool

    var body: some View {
        @Bindable var state = state
        let sections = state.paletteSections
        ZStack(alignment: .top) {
            Color.black.opacity(0.22)
                .contentShape(Rectangle())
                .onTapGesture { state.togglePalette() }

            VStack(spacing: 0) {
                field($state.paletteQuery)
                Hairline()
                if sections.isEmpty {
                    Text(state.paletteMovingTask != nil ? "No goals match “\(state.paletteQuery)”"
                                                        : "No tasks, goals or pages match “\(state.paletteQuery)”")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                } else {
                    results(sections)
                }
                Hairline()
                footer
            }
            .frame(width: min(Self.width, state.windowWidth - 32))
            .background(Theme.editorBG)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke))
            .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
            .padding(.top, 72)
            .padding(.horizontal, 16)
            .defaultFocus($fieldFocused, true)
        }
        .onAppear(perform: focusField)
        .sheet(isPresented: $state.showsKeyboardShortcuts) { KeyboardShortcutsSheet() }
    }

    /// The caret in the search field, so typing starts the search without a click. A runloop late: on appear the
    /// overlay's transition hasn't put the field in the window yet, and the composer, the session's terminal or the
    /// diff's composer can still hold focus. If one of them does, it's let go and the field asked for again.
    private func focusField() {
        DispatchQueue.main.async {
            fieldFocused = true
            DispatchQueue.main.async {
                guard !fieldFocused else { return }
                NSApp.keyWindow?.makeFirstResponder(nil)
                fieldFocused = true
            }
        }
    }

    private func field(_ query: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textMuted)
            if let moving = state.paletteMovingTask {
                Text(moving)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 6)
                    .frame(height: 20)
                    .background(Capsule().fill(Theme.fill))
            }
            TextField(state.paletteMovingTask.map { "Move \($0) to…" } ?? "Search tasks, goals and pages, or try goal: state: mine",
                      text: query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .foregroundStyle(Theme.text)
                .focused($fieldFocused)
                .onSubmit { state.runPaletteSelection() }
                .onExitCommand { state.paletteEscape() }
                .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                    state.movePaletteSelection(press.key == .upArrow ? -1 : 1)
                    return .handled
                }
            Text("esc")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textFaint)
                .padding(.horizontal, 6)
                .frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.stroke))
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private func results(_ sections: [PaletteSection]) -> some View {
        // Flat indexes, so a row knows whether it's the highlighted one.
        let starts = sections.indices.map { index in sections[..<index].reduce(0) { $0 + $1.items.count } }
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(sections.enumerated()), id: \.element.kind) { index, section in
                        header(section)
                            .padding(.horizontal, 18)
                            .padding(.top, index == 0 ? 10 : 14)
                            .padding(.bottom, 4)
                        ForEach(Array(section.items.enumerated()), id: \.element.id) { offset, item in
                            let flat = starts[index] + offset
                            row(item, selected: flat == state.paletteSelection, recent: section.kind == .recent)
                                .id(flat)
                                .onTapGesture { state.perform(item) }
                                .onHover { if $0 { state.paletteSelection = flat } }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: state.paletteSelection) { _, selection in proxy.scrollTo(selection) }
        }
    }

    /// A section's title; "This task · MF-123" also shows the task's state.
    @ViewBuilder private func header(_ section: PaletteSection) -> some View {
        HStack(spacing: 8) {
            Text(section.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textFaint)
            if section.kind == .thisTask, let id = section.taskID {
                StateBadge(state: state.task(id).state)
                    .scaleEffect(0.85, anchor: .leading)
            }
        }
    }

    @ViewBuilder private func row(_ item: PaletteItem, selected: Bool, recent: Bool = false) -> some View {
        HStack(spacing: 10) {
            switch item {
            case .taskAction(_, let action):
                icon(action.icon, color: action.isDestructive ? .red : Theme.accent)
                Text(action.title).font(.system(size: 13.5)).foregroundStyle(action.isDestructive ? .red : Theme.text)
                Spacer(minLength: 8)
            case .factory(let id):
                let factory = client.savedFactories.first { $0.id == id }
                icon("building.2", color: Theme.textMuted)
                Text("Switch to \(factory?.name ?? id)").font(.system(size: 13.5)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 8)
                hint("Factory")
            case .settingsPane(let pane):
                icon(pane.icon, color: pane.color)
                Text(pane.title).font(.system(size: 13.5)).foregroundStyle(Theme.text)
                Spacer(minLength: 8)
                hint("Settings")
            case .moveTarget(let id, let goal):
                let blocked = state.moveTargets(id).first { $0.goal.name == goal }?.blocked
                icon("scope", color: FactoryData.goal(named: goal).color)
                Text(goal).font(.system(size: 13.5)).foregroundStyle(blocked == nil ? Theme.text : Theme.textFaint).lineLimit(1)
                Spacer(minLength: 8)
                hint(blocked ?? "Move here")
            case .task(let id):
                let task = state.task(id)
                icon(task.state.icon, color: task.state.color)
                Text(task.id)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textMuted)
                Text(task.title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if !state.isCompact { goalChip(task.goal) }
                if recent { Image(systemName: "clock").font(.system(size: 10.5)).foregroundStyle(Theme.textFaint) }
                StateBadge(state: task.state)
            case .goal(let name):
                icon("scope", color: FactoryData.goal(named: name).color)
                Text(name).font(.system(size: 13.5)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 8)
                hint("Goal")
            case .page(let page):
                icon(page.icon, color: Theme.textMuted)
                Text(page.title).font(.system(size: 13.5)).foregroundStyle(Theme.text)
                Spacer(minLength: 8)
                hint("Go to")
            case .doc(let id):
                let doc = client.docs.first { $0.id == id } ?? (id == DemoDoc.id ? DemoDoc.doc : nil)
                icon("doc.richtext", color: Theme.textMuted)
                Text(doc?.title ?? "Doc").font(.system(size: 13.5)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 8)
                if recent { Image(systemName: "clock").font(.system(size: 10.5)).foregroundStyle(Theme.textFaint) }
                hint(DocsIndex.goalName(doc?.goal, client: client) ?? "Doc")
            case .action(let action):
                icon(action.icon, color: Theme.accent)
                Text(action.title).font(.system(size: 13.5)).foregroundStyle(Theme.text)
                Spacer(minLength: 8)
                if let theme = action.appearance {
                    hint(theme == appearance ? "✓ Current" : "")
                } else {
                    hint(action.shortcut)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Theme.fillSelected : .clear))
        .overlay(alignment: .leading) {
            if selected { Capsule().fill(Theme.accent).frame(width: 3, height: 18).offset(x: -1) }
        }
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }

    private func icon(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(color)
            .frame(width: 18)
    }

    private func goalChip(_ name: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(FactoryData.goal(named: name).color).frame(width: 6, height: 6)
            Text(name).lineLimit(1)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.textMuted)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Capsule().fill(Theme.fill))
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.textFaint)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("↑↓ to move")
            hint("↩ to open")
            hint(state.paletteMovingTask != nil ? "esc to go back" : "esc to close")
            Spacer()
            if !state.isCompact { hint("Filter with goal:auth  state:reviewing  mine") }
        }
        .padding(.horizontal, 16)
        .frame(height: 32)
    }
}

/// ⌘K's "Keyboard shortcuts": every palette action with a shortcut, and the menu's own keys.
struct KeyboardShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    private var rows: [(String, String)] {
        [("Command palette", "⌘K"), ("Switch to factory 1–9", "⌘1–⌘9"), ("Previous / next task", "⌥⌘↑ ⌥⌘↓")]
            + PaletteAction.allCases.filter { !$0.shortcut.isEmpty }.map { ($0.title, $0.shortcut) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Keyboard shortcuts")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
                .padding(.bottom, 12)
            ForEach(rows, id: \.0) { title, keys in
                HStack {
                    Text(title).font(.system(size: 13)).foregroundStyle(Theme.text)
                    Spacer(minLength: 24)
                    Text(keys).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.textMuted)
                }
                .padding(.vertical, 5)
                Hairline()
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.top, 14)
        }
        .padding(20)
        .frame(width: 380)
    }
}

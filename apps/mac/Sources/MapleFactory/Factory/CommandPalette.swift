import SwiftUI

/// ⌘K: a search field over every task, goal, page and common action, driven from the keyboard.
struct CommandPalette: View {
    static let width: CGFloat = 620
    static let rowHeight: CGFloat = 36

    @Environment(AppState.self) private var state
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
                    Text("No tasks, goals or pages match “\(state.paletteQuery)”")
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
            TextField("Search tasks, goals and pages, or try goal: state: mine", text: query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .foregroundStyle(Theme.text)
                .focused($fieldFocused)
                .onSubmit { state.runPaletteSelection() }
                .onExitCommand { state.togglePalette() }
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
                        Text(section.kind.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.textFaint)
                            .padding(.horizontal, 18)
                            .padding(.top, index == 0 ? 10 : 14)
                            .padding(.bottom, 4)
                        ForEach(Array(section.items.enumerated()), id: \.element.id) { offset, item in
                            let flat = starts[index] + offset
                            row(item, selected: flat == state.paletteSelection)
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

    @ViewBuilder private func row(_ item: PaletteItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            switch item {
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
            case .action(let action):
                icon(action.icon, color: Theme.accent)
                Text(action.title).font(.system(size: 13.5)).foregroundStyle(Theme.text)
                Spacer(minLength: 8)
                hint(action.shortcut)
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
            hint("esc to close")
            Spacer()
            if !state.isCompact { hint("Filter with goal:auth  state:reviewing  mine") }
        }
        .padding(.horizontal, 16)
        .frame(height: 32)
    }
}

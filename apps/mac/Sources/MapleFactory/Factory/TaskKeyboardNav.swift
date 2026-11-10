import AppKit
import SwiftUI

// MARK: - Actions

extension AppState {
    /// ↑↓←→ / J K H L: move the cursor through the rows on screen. With the panel open it follows the cursor.
    func moveCursor(_ direction: TaskKeyNav.Direction) {
        guard let next = TaskKeyNav.move(direction, from: keyboardCursor, in: navLayout) else { return }
        keyboardCursor = next
        if showInspector, taskPanelEnabled { selectedTask = next }
    }

    /// Return: open the cursor's task per "When you click a task" (the panel, or the full view).
    func openCursor() {
        guard let id = keyboardCursor else { return }
        if taskPanelEnabled { openTask(id) } else { openFocus(id) }
    }

    /// Space: peek at the cursor's task in the panel, or close the peek; with the panel off, the full view.
    func peekCursor() {
        guard let id = keyboardCursor else { return }
        if taskPanelEnabled { toggleTask(id) } else { openFocus(id) }
    }

    /// A: the Inbox row's Approve / Rerun / Review / Answer, or Needs a hand's Answer.
    func performCursorPrimary() {
        guard let id = keyboardCursor, let navPrimary else { return }
        navPrimary(id)
    }

    var canPerformCursorPrimary: Bool { keyboardCursor != nil && navPrimary != nil }

    /// The Inbox row's action button, and A on the selected row.
    func performInboxAction(_ item: InboxItem) {
        switch item.kind {
        case .approval:
            approvePlan(item.taskID)
        case .failing:
            rerunFailedChecks(item.taskID)
        case .mention:
            dismissedMentions.insert(item.id)
            openFocus(item.taskID)
        case .review, .question:
            openFocus(item.taskID)
        }
    }

    /// The full view's Next / Previous Task (⌘⌥↓ / ⌘⌥↑, or J / K): the neighbour in the list it was opened from.
    func stepTask(forward: Bool) {
        guard let current = focusedTask, let next = TaskKeyNav.neighbour(of: current, in: navList, forward: forward) else { return }
        keyboardCursor = next
        openFocus(next)
    }

    func canStepTask(forward: Bool) -> Bool {
        focusedTask.flatMap { TaskKeyNav.neighbour(of: $0, in: navList, forward: forward) } != nil
    }

    /// Opening a task from the rows on screen remembers them, so the full view can walk them.
    func rememberNavList(opening id: String) {
        let rows = navLayout.flat
        if rows.contains(id) { navList = rows; keyboardCursor = id }
    }

    /// Whether a bare key belongs to typing, not to navigation: a text field, the composer, the palette or a sheet has it.
    var keysBelongToTyping: Bool {
        if showPalette || isComposing || goalSheet != nil || showOnboarding { return true }
        return TextFocus.isEditing
    }
}

/// Whether the key window's first responder takes typing: a text field or view (the field editor is an
/// NSTextView), or a web view such as the doc editor.
enum TextFocus {
    @MainActor static var isEditing: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if responder is NSText || responder is NSTextField { return true }
        return String(describing: type(of: responder)).hasPrefix("WK")
    }
}

// MARK: - Keys

/// The keys, read once for the main window before anything else sees them, so a scroll view doesn't
/// page on Space and arrows. Anything with ⌘, ⌥ or ⌃ held, any other window (a popover, a sheet, the
/// palette) and any typing passes straight through.
@MainActor final class TaskKeyMonitor {
    private var monitor: Any?

    func install(_ state: AppState) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak state] event in
            guard let state, Self.handle(event, state: state) else { return event }
            return nil
        }
    }


    /// The key's action, by key code for the arrows, Return and Space, and by character for the letters.
    enum Key: Equatable { case move(TaskKeyNav.Direction), open, peek, primary }

    static func key(code: UInt16, characters: String?) -> Key? {
        switch code {
        case 125: return .move(.down)
        case 126: return .move(.up)
        case 123: return .move(.left)
        case 124: return .move(.right)
        case 36, 76: return .open
        case 49: return .peek
        default: break
        }
        switch characters?.lowercased() {
        case "j": return .move(.down)
        case "k": return .move(.up)
        case "h": return .move(.left)
        case "l": return .move(.right)
        case "a": return .primary
        default: return nil
        }
    }

    private static func handle(_ event: NSEvent, state: AppState) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              let window = event.window, window === NSApp.keyWindow, window.sheets.isEmpty,
              window.attachedSheet == nil, !(window is NSPanel),
              !state.keysBelongToTyping,
              let key = key(code: event.keyCode, characters: event.charactersIgnoringModifiers) else { return false }

        // The full view: J / K walk the list it was opened from; everything else is the page's own.
        if state.focusedTask != nil {
            switch key {
            case .move(.down) where event.keyCode != 125: state.stepTask(forward: true); return true
            case .move(.up) where event.keyCode != 126: state.stepTask(forward: false); return true
            default: return false
            }
        }
        guard !state.navLayout.isEmpty else { return false }
        switch key {
        case .move(let direction): state.moveCursor(direction)
        case .open:
            guard state.keyboardCursor != nil else { return false }
            state.openCursor()
        case .peek:
            guard state.keyboardCursor != nil else { return false }
            state.peekCursor()
        case .primary:
            guard state.canPerformCursorPrimary else { return false }
            state.performCursorPrimary()
        }
        return true
    }
}

// MARK: - Rows on screen

private struct TaskKeyboardNav: ViewModifier {
    @Environment(AppState.self) private var state
    let layout: TaskKeyNav.Layout
    let primary: ((String) -> Void)?
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .onAppear { register() }
                .onDisappear {
                    // Another list may have registered already; only this one's rows go.
                    if TaskKeyboardNav.current == owner {
                        state.navLayout = .empty
                        state.navPrimary = nil
                        TaskKeyboardNav.current = nil
                    }
                }
                .onChange(of: layout) { old, new in
                    if TaskKeyboardNav.current == owner || TaskKeyboardNav.current == nil { register() }
                    // A cleared row (an approved plan leaves the Inbox) hands the cursor to the one after it.
                    if let cursor = state.keyboardCursor, !new.flat.contains(cursor) {
                        state.keyboardCursor = TaskKeyNav.survivor(of: cursor, before: old.flat, after: new.flat)
                    }
                }
                .onChange(of: state.keyboardCursor) { _, id in
                    guard let id, layout.flat.contains(id) else { return }
                    withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(id, anchor: nil) }
                }
        }
    }

    private func register() {
        TaskKeyboardNav.current = owner
        state.navLayout = layout
        state.navPrimary = primary
    }

    @MainActor static var current: UUID?
}

extension View {
    /// The rows ↑↓←→, Return, Space and A act on, in order; the modified view holds the scroll view they scroll in.
    func taskKeyboardNav(_ layout: TaskKeyNav.Layout, primary: ((String) -> Void)? = nil) -> some View {
        modifier(TaskKeyboardNav(layout: layout, primary: primary))
    }

    /// The keyboard cursor's ring on a row or card.
    func keyboardCursorRing(_ on: Bool, cornerRadius: CGFloat = 0, inset: CGFloat = 0) -> some View {
        overlay {
            if on {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Theme.accent.opacity(0.85), lineWidth: 1.5)
                    .padding(inset)
                    .allowsHitTesting(false)
            }
        }
    }
}

import AppKit
import SwiftUI

// MARK: - Hovering a task reference

/// Hovering a linked task ID (MarkdownPreview.linkTasks) in a rendered Text opens a preview card under
/// it after a short delay. SwiftUI's Text doesn't say which character is under the pointer, so the same
/// string is laid out with an NSLayoutManager at the Text's width and hit-tested there.
struct TaskRefHover: ViewModifier {
    let text: AttributedString
    let size: CGFloat
    var weight: NSFont.Weight = .regular
    var lineSpacing: CGFloat = 0
    let known: Set<String>

    @Environment(AppState.self) private var appState: AppState?
    @State private var frame: CGRect = .zero
    private var width: CGFloat { frame.width }
    /// The reference under the pointer, and the card that's showing (they differ while the delays run).
    @State private var hovered: Hovered?
    @State private var shown: Hovered?
    @State private var cardHovered = false
    @State private var pending: Task<Void, Never>?
    @State private var pointing = false
    /// A demoHover is showing the card: the real pointer, nowhere near an off-screen window, is ignored.
    @State private var demo = false

    struct Hovered: Identifiable, Equatable {
        let id: String
        let rect: CGRect
    }

    /// `-actions "hoverref:MF-116"` (AppState.play): hovers that reference, for recordings; `hoverref:none`
    /// moves away.
    static let demoHover = Notification.Name("TaskRefHover.demoHover")
    static let openDelay = Duration.milliseconds(350)
    static let closeGrace = Duration.milliseconds(150)

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            .onContinuousHover(coordinateSpace: .local) { phase in
                guard !demo else { return }
                switch phase {
                case let .active(point): hover(reference(at: point))
                case .ended: hover(nil)
                }
            }
            .popover(item: $shown, attachmentAnchor: .rect(.rect(shown?.rect ?? .zero)), arrowEdge: .bottom) { ref in
                if let task = appState?.tasks.first(where: { $0.id == ref.id }) {
                    TaskHovercard(task: task)
                        .onHover { inside in
                            guard !demo else { return }
                            cardHovered = inside
                            if !inside, hovered == nil { schedule(nil) }
                        }
                        .onTapGesture {
                            shown = nil
                            appState?.openReference(ref.id)
                        }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: Self.demoHover)) { note in
                let id = note.userInfo?["id"] as? String ?? "none"
                guard id != "none" else {
                    // The real pointer may sit where AppKit put the off-screen popover; it doesn't hold the card.
                    if demo { demo = false; cardHovered = false; hover(nil) }
                    return
                }
                // The first rendered Text that links the ID takes it, so only one card opens.
                guard let claim = note.object as? DemoClaim, !claim.taken, let rect = rect(of: id) else { return }
                claim.taken = true
                demo = true
                hover(Hovered(id: id, rect: rect))
            }
            .onChange(of: shown) { _, ref in
                guard Headless.isOn else { return }
                Headless.popoverAnchor = ref.map { $0.rect.offsetBy(dx: frame.minX, dy: frame.minY) }
            }
            .onDisappear {
                pending?.cancel()
                if pointing { NSCursor.pop(); pointing = false }
            }
    }

    /// The pointer moved onto `ref` (or off any): the card opens after openDelay, or closes after
    /// closeGrace unless the pointer reached the card.
    private func hover(_ ref: Hovered?) {
        if (ref != nil) != pointing {
            if ref != nil { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            pointing = ref != nil
        }
        guard ref?.id != hovered?.id else { return }
        hovered = ref
        pending?.cancel()
        pending = nil
        if let ref, ref.id == shown?.id { return }
        if ref == nil, shown == nil { return }
        schedule(ref)
    }

    private func schedule(_ ref: Hovered?) {
        pending = Task { @MainActor in
            try? await Task.sleep(for: ref == nil ? Self.closeGrace : Self.openDelay)
            guard !Task.isCancelled else { return }
            pending = nil
            if ref == nil, cardHovered { return }
            shown = ref
        }
    }

    // MARK: Measuring

    private func reference(at point: CGPoint) -> Hovered? {
        let layout = Layout(text, size: size, weight: weight, lineSpacing: lineSpacing, width: width)
        guard let index = layout.characterIndex(at: point),
              let ref = TaskRefQuery.reference(at: index, in: layout.plain, known: known),
              layout.links(ref) else { return nil }
        return Hovered(id: ref.id, rect: layout.rect(of: ref.range))
    }

    private func rect(of id: String) -> CGRect? {
        let layout = Layout(text, size: size, weight: weight, lineSpacing: lineSpacing, width: width)
        return TaskRefQuery.references(in: layout.plain, known: known)
            .first { $0.id == id && layout.links($0) }
            .map { layout.rect(of: $0.range) }
    }

    /// The rendered string in TextKit, with the fonts MarkdownPreview's runs get.
    private struct Layout {
        let plain: String
        let storage: NSTextStorage
        let manager = NSLayoutManager()
        let container: NSTextContainer

        init(_ text: AttributedString, size: CGFloat, weight: NSFont.Weight, lineSpacing: CGFloat, width: CGFloat) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = lineSpacing
            let string = NSMutableAttributedString()
            for run in text.runs {
                let intent = run.inlinePresentationIntent ?? []
                var font = intent.contains(.code)
                    ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                    : NSFont.systemFont(ofSize: size, weight: intent.contains(.stronglyEmphasized) ? .bold : weight)
                if intent.contains(.emphasized) {
                    font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                }
                var attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
                if let link = run.link { attributes[.link] = link }
                string.append(NSAttributedString(string: String(text[run.range].characters), attributes: attributes))
            }
            plain = string.string
            storage = NSTextStorage(attributedString: string)
            container = NSTextContainer(size: CGSize(width: max(width, 1), height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
            manager.ensureLayout(for: container)
        }

        /// The character whose glyph is under `point`, if one is.
        func characterIndex(at point: CGPoint) -> Int? {
            guard storage.length > 0 else { return nil }
            let glyph = manager.glyphIndex(for: point, in: container)
            let bounds = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            guard bounds.insetBy(dx: -1, dy: -2).contains(point) else { return nil }
            return manager.characterIndexForGlyph(at: glyph)
        }

        /// The reference got linkTasks' link: not in code or another link.
        func links(_ ref: (range: NSRange, id: String)) -> Bool {
            storage.attribute(.link, at: ref.range.location, effectiveRange: nil) as? URL == TaskRefQuery.url(ref.id)
        }

        /// Where the reference sits; its first line if it wraps.
        func rect(of range: NSRange) -> CGRect {
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var first: CGRect?
            manager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, stop in
                first = rect
                stop.pointee = true
            }
            return first ?? manager.boundingRect(forGlyphRange: glyphs, in: container)
        }
    }
}

/// Carried by a demoHover note so one Text answers it.
final class DemoClaim {
    var taken = false
}

extension View {
    /// Hovering a linked task ID in this Text (`text` is what it renders) shows TaskHovercard.
    func taskRefHover(_ text: AttributedString, size: CGFloat, weight: NSFont.Weight = .regular, lineSpacing: CGFloat = 0, known: Set<String>) -> some View {
        modifier(TaskRefHover(text: text, size: size, weight: weight, lineSpacing: lineSpacing, known: known))
    }
}

// MARK: - The card

/// A read-only preview of a referenced task: its ID and state, title, and goal, agent and last change.
struct TaskHovercard: View {
    let task: FactoryTask

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(task.id)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.textMuted)
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    Circle().fill(task.state.color).frame(width: 7, height: 7)
                    Text(task.state.title)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(task.state.color)
                }
            }
            Text(task.title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Label(task.goal, systemImage: "scope")
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let agent = task.agent {
                    Text("·").foregroundStyle(Theme.textFaint)
                    Text(agent.name).lineLimit(1).fixedSize()
                }
                Text("·").foregroundStyle(Theme.textFaint)
                Text(task.updated).lineLimit(1).fixedSize()
                Spacer(minLength: 0)
                Text("Open ↩").foregroundStyle(Theme.textFaint).fixedSize()
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.textMuted)
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
        .background(Theme.cardBG)
        .contentShape(Rectangle())
    }
}

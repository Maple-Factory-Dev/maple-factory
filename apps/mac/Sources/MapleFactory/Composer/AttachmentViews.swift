import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Pasted and dropped files

/// A file pasted or dropped into the editor, read off the pasteboard.
struct PastedFile {
    let data: Data
    let name: String
    let mime: String

    var isImage: Bool { mime.hasPrefix("image/") }

    /// Files (Finder's copy, a drop) or a bare image (a screenshot copied to the clipboard). Text, even
    /// text that comes with a picture of itself, isn't a file: it's pasted as text.
    static func read(_ pasteboard: NSPasteboard) -> [PastedFile] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty {
            return urls.compactMap { url in
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                      let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
                let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                return PastedFile(data: data, name: url.lastPathComponent, mime: mime)
            }
        }
        guard pasteboard.string(forType: .string) == nil else { return [] }
        let png = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff).flatMap {
            NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:])
        }
        guard let png else { return [] }
        let stamp = Date().formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)", timeZone: .current, calendar: .current))
        return [PastedFile(data: png, name: "screenshot-\(stamp).png", mime: "image/png")]
    }
}

/// An NSTextView that hands pasted and dropped files to `onFiles` (when it's set) instead of
/// inserting their paths.
final class AttachingTextView: NSTextView {
    var onFiles: (([PastedFile]) -> Void)?

    override func paste(_ sender: Any?) {
        if let onFiles {
            let files = PastedFile.read(.general)
            if !files.isEmpty { return onFiles(files) }
        }
        super.paste(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let onFiles {
            let files = PastedFile.read(sender.draggingPasteboard)
            if !files.isEmpty {
                let index = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
                setSelectedRange(NSRange(location: index, length: 0))
                window?.makeFirstResponder(self)
                onFiles(files)
                return true
            }
        }
        return super.performDragOperation(sender)
    }
}

/// The editor's text: plain monospaced Markdown, with its selection bound so the toolbar can wrap it.
/// With `upload`, a pasted or dropped file goes up to the factory and the note links to it.
struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    var upload: ((PastedFile) async throws -> FactoryClient.Attachment)?

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let old = scroll.documentView as! NSTextView
        let view = AttachingTextView(frame: old.frame, textContainer: old.textContainer)
        view.autoresizingMask = old.autoresizingMask
        view.minSize = old.minSize
        view.maxSize = old.maxSize
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        scroll.documentView = view
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        view.delegate = context.coordinator
        view.drawsBackground = false
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.textContainerInset = NSSize(width: 12, height: 12)
        view.textContainer?.lineFragmentPadding = 5
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        view.defaultParagraphStyle = paragraph
        view.typingAttributes = Self.attributes
        view.string = text
        context.coordinator.view = view
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.demoPaste), name: MarkdownEditor.demoPaste, object: nil)
        return scroll
    }

    static var attributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        return [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor(Theme.text), .paragraphStyle: paragraph]
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? AttachingTextView else { return }
        view.onFiles = upload == nil ? nil : { [weak coordinator = context.coordinator] files in coordinator?.attach(files) }
        if view.string != text {
            view.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: Self.attributes))
        }
        let length = (view.string as NSString).length
        let wanted = NSRange(location: min(selection.location, length), length: min(selection.length, max(0, length - selection.location)))
        if view.selectedRange() != wanted { view.setSelectedRange(wanted) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextView
        weak var view: AttachingTextView?

        @objc func demoPaste() {
            guard let view, view.window != nil else { return }
            view.window?.makeFirstResponder(view)
            view.paste(nil)
        }

        init(_ parent: MarkdownTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view else { return }
            parent.text = view.string
            parent.selection = view.selectedRange()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view, parent.selection != view.selectedRange() else { return }
            parent.selection = view.selectedRange()
        }

        /// Puts a placeholder for each file at the cursor, on lines of their own, and swaps each for
        /// its link (or why it didn't go up) when its upload ends.
        func attach(_ files: [PastedFile]) {
            guard let view, let upload = parent.upload else { return }
            let range = view.selectedRange()
            let string = view.string as NSString
            let before = range.location > 0 && string.character(at: range.location - 1) != 10 ? "\n" : ""
            let end = NSMaxRange(range)
            let after = end < string.length && string.character(at: end) != 10 ? "\n" : ""
            let placeholders = files.map { "![Uploading \($0.name)…]()" }
            view.insertText(before + placeholders.joined(separator: "\n") + after, replacementRange: range)
            for (file, placeholder) in zip(files, placeholders) {
                Task {
                    let link: String
                    do {
                        let stored = try await upload(file)
                        link = "\(stored.mime.hasPrefix("image/") ? "!" : "")[\(stored.name)](\(stored.path))"
                    } catch {
                        link = "_Couldn't upload \(file.name): \(FactoryClient.describe(error))_"
                    }
                    let now = (self.view?.string ?? "") as NSString
                    let found = now.range(of: placeholder)
                    if found.location != NSNotFound { self.replace(found, with: link) }
                }
            }
        }

        /// An edit the way typing makes one: undoable, and the text binding follows.
        private func replace(_ range: NSRange, with string: String) {
            guard let view, view.shouldChangeText(in: range, replacementString: string) else { return }
            view.textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: string, attributes: MarkdownTextView.attributes))
            view.didChangeText()
        }
    }
}

// MARK: - Showing attachments

/// An image a note links to: an attachment (fetched with the app's token) or a web image.
struct LinkedImage: View {
    let alt: String
    let path: String
    @Environment(FactoryClient.self) private var client: FactoryClient?
    @State private var image: NSImage?
    @State private var failed: String?

    var body: some View {
        Group {
            if path.isEmpty {
                status(icon: nil, "\(alt)")
            } else if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: min(image.size.width, 720), alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.stroke))
                    .help(alt)
            } else if let failed {
                status(icon: "exclamationmark.triangle", "\(alt): \(failed)")
            } else {
                status(icon: nil, alt)
            }
        }
        .task(id: path) { await load() }
    }

    private func status(icon: String?, _ text: String) -> some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon) } else { ProgressView().controlSize(.small) }
            Text(text)
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.textMuted)
    }

    private func load() async {
        guard !path.isEmpty else { return }
        do {
            let data: Data
            if path.hasPrefix("/attachments/") {
                guard let client else { throw FactoryClient.ClientError.message("Not signed in.") }
                data = try await client.attachment(path)
            } else if let url = URL(string: path), url.scheme == "https" {
                data = try await URLSession.shared.data(from: url).0
            } else {
                throw FactoryClient.ClientError.message("Can't show this image.")
            }
            guard let loaded = NSImage(data: data) else { throw FactoryClient.ClientError.message("Not an image.") }
            image = loaded
        } catch {
            failed = FactoryClient.describe(error)
        }
    }
}

/// A file a note links to, as a chip that opens it.
struct AttachmentChip: View {
    let name: String
    let path: String
    @Environment(FactoryClient.self) private var client: FactoryClient?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc").font(.system(size: 11))
            Text(name).font(.system(size: 12.5, weight: .medium))
            Image(systemName: "arrow.up.forward").font(.system(size: 9.5)).foregroundStyle(Theme.textMuted)
        }
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.fill))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.stroke))
        .contentShape(Rectangle())
        .onTapGesture { Task { await client?.open(attachment: path) } }
        .help("Open \(name)")
    }
}

import AVKit
import QuickLook
import SwiftUI

/// A file linked from a brief or comment: `![name](/attachments/…)` from the phone and the Mac,
/// `- [name](/attachments/…)` from Slack.
struct LinkedAttachment: Hashable, Identifiable {
    enum Kind { case image, video, file }
    let name: String
    let path: String
    let kind: Kind
    var id: String { path }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "bmp", "tiff"]
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "webm"]

    static func kind(of path: String, image: Bool) -> Kind {
        let ext = (path.split(separator: "?").first.map(String.init) ?? path).split(separator: ".").last.map { $0.lowercased() } ?? ""
        if videoExtensions.contains(ext) { return .video }
        if imageExtensions.contains(ext) || (image && !path.hasPrefix("/attachments/")) { return .image }
        return .file
    }
}

/// Markdown split into the text to show and the attachments it links, so the attachments can show as
/// thumbnails rather than link text. The rules mirror the Mac's `MarkdownBlock`: a line that is only
/// `![alt](path)`, `[name](/attachments/…)` or `- [name](/attachments/…)` is an attachment, and Slack's
/// `## Attachments` heading goes once its links are taken out.
enum BriefContent {
    static func parse(_ source: String) -> (text: String, attachments: [LinkedAttachment]) {
        var lines: [String] = []
        var attachments: [LinkedAttachment] = []
        var inFence = false
        for raw in source.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inFence.toggle() }
            if !inFence, let attachment = attachment(line) {
                attachments.append(attachment)
                continue
            }
            lines.append(raw)
        }
        if !attachments.isEmpty {
            // Slack's `## Attachments` heading, now with nothing under it before the next heading.
            var index = 0
            while index < lines.count {
                if lines[index].trimmingCharacters(in: .whitespaces).lowercased() == "## attachments" {
                    let rest = lines[(index + 1)...].prefix { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
                    if rest.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                        lines.remove(at: index)
                        continue
                    }
                }
                index += 1
            }
        }
        // Blank lines left where the attachments were.
        var text = lines.joined(separator: "\n")
        while text.contains("\n\n\n") { text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), attachments)
    }

    private static func attachment(_ line: String) -> LinkedAttachment? {
        var line = Substring(line)
        let bullet = line.hasPrefix("- ") || line.hasPrefix("* ")
        if bullet { line = line.dropFirst(2) }
        guard let match = line.wholeMatch(of: /(!?)\[([^\]]*)\]\((\S*)\)/) else { return nil }
        let image = !match.1.isEmpty, name = String(match.2), path = String(match.3)
        if bullet || !image {
            // A plain link counts only when it's to an attachment.
            guard path.hasPrefix("/attachments/") else { return nil }
        } else {
            guard path.hasPrefix("/attachments/") || path.hasPrefix("https://") else { return nil }
        }
        let fallback = path.split(separator: "/").last.map { String($0).removingPercentEncoding ?? String($0) } ?? path
        return LinkedAttachment(name: name.isEmpty ? fallback : name, path: path, kind: LinkedAttachment.kind(of: path, image: image))
    }
}

/// A note's text followed by its attachments: what the Brief card and timeline comments show.
struct NoteWithAttachments: View {
    let source: String
    var compact = false

    var body: some View {
        let content = BriefContent.parse(source)
        VStack(alignment: .leading, spacing: 8) {
            if !content.text.isEmpty { MarkdownText(source: content.text) }
            if !content.attachments.isEmpty { AttachmentGallery(attachments: content.attachments, compact: compact) }
        }
    }
}

/// Images and videos in a grid, other files as chips under it. Tapping an image opens the viewer.
struct AttachmentGallery: View {
    let attachments: [LinkedAttachment]
    var compact = false
    @State private var viewing: LinkedAttachment?

    private var images: [LinkedAttachment] { attachments.filter { $0.kind == .image } }
    private var videos: [LinkedAttachment] { attachments.filter { $0.kind == .video } }
    private var files: [LinkedAttachment] { attachments.filter { $0.kind == .file } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !images.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: compact ? 4 : 3), spacing: 6) {
                    ForEach(images) { image in
                        Button { viewing = image } label: { AttachmentThumb(attachment: image) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(image.name)
                            .accessibilityIdentifier("attachment.image.\(image.name)")
                    }
                }
            }
            ForEach(videos) { AttachmentVideo(attachment: $0) }
            ForEach(files) { AttachmentChip(attachment: $0) }
        }
        .fullScreenCover(item: $viewing) { start in
            AttachmentViewer(images: images, selection: start.path)
        }
    }
}

/// Loads an attachment's image: the factory's with your token, a web image as is.
@MainActor
enum AttachmentLoader {
    static func image(_ path: String, store: FactoryStore) async -> UIImage? {
        let data: Data?
        if path.hasPrefix("https://"), let url = URL(string: path) {
            data = try? await URLSession.shared.data(from: url).0
        } else {
            data = await store.attachment(path)
        }
        return data.flatMap(UIImage.init(data:))
    }
}

/// One square thumbnail: a spinner while it loads, an icon and its name if it can't.
struct AttachmentThumb: View {
    @Environment(FactoryStore.self) private var store
    let attachment: LinkedAttachment
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Color(.secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if failed {
                    VStack(spacing: 4) {
                        Image(systemName: "photo").font(.title3)
                        Text(attachment.name).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.secondary).padding(4)
                } else {
                    ProgressView()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .task(id: attachment.path) {
                image = await AttachmentLoader.image(attachment.path, store: store)
                failed = image == nil
            }
    }
}

/// A video, played inline with your token on the request.
struct AttachmentVideo: View {
    @Environment(FactoryStore.self) private var store
    let attachment: LinkedAttachment

    var body: some View {
        if let request = store.request(attachment.path), let url = request.url {
            VideoPlayer(player: AVPlayer(playerItem: AVPlayerItem(asset: AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": request.allHTTPHeaderFields ?? [:]]))))
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("attachment.video.\(attachment.name)")
        } else {
            AttachmentChip(attachment: attachment)
        }
    }
}

/// Any other file: tapping it downloads it and opens it in Quick Look.
struct AttachmentChip: View {
    @Environment(FactoryStore.self) private var store
    let attachment: LinkedAttachment
    @State private var loading = false
    @State private var preview: URL?
    @State private var failed = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: attachment.kind == .video ? "film" : "doc").foregroundStyle(.secondary)
                Text(attachment.name).font(.callout).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if loading { ProgressView().controlSize(.small) }
                else if failed { Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warning) }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemBackground)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(attachment.name)
        .accessibilityIdentifier("attachment.file.\(attachment.name)")
        .quickLookPreview($preview)
    }

    private func open() {
        guard !loading else { return }
        loading = true
        failed = false
        Task {
            defer { loading = false }
            guard let data = await store.attachment(attachment.path) else { failed = true; return }
            let folder = FileManager.default.temporaryDirectory.appending(path: "attachments/\(UUID().uuidString)", directoryHint: .isDirectory)
            let file = folder.appending(path: attachment.name)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: file)
                preview = file
            } catch { failed = true }
        }
    }
}

/// The task's images full screen: swipe between them, pinch to zoom, share, Done to go back.
struct AttachmentViewer: View {
    @Environment(\.dismiss) private var dismiss
    let images: [LinkedAttachment]
    @State var selection: String

    var body: some View {
        NavigationStack {
            TabView(selection: $selection) {
                ForEach(images) { image in
                    ZoomableAttachment(attachment: image).tag(image.path)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: images.count > 1 ? .automatic : .never))
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(images.first { $0.path == selection }?.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("attachmentViewer.done")
                }
            }
        }
        .accessibilityIdentifier("attachmentViewer")
    }
}

/// One image in the viewer, with pinch to zoom (double-tap to zoom in or back out) and Share.
private struct ZoomableAttachment: View {
    @Environment(FactoryStore.self) private var store
    let attachment: LinkedAttachment
    @State private var image: UIImage?
    @State private var failed = false
    @State private var scale: CGFloat = 1
    @State private var settled: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragged: CGSize = .zero

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(MagnifyGesture()
                        .onChanged { scale = max(1, settled * $0.magnification) }
                        .onEnded { _ in settled = scale; if scale == 1 { offset = .zero; dragged = .zero } })
                    .simultaneousGesture(scale > 1 ? DragGesture()
                        .onChanged { offset = CGSize(width: dragged.width + $0.translation.width, height: dragged.height + $0.translation.height) }
                        .onEnded { _ in dragged = offset } : nil)
                    .onTapGesture(count: 2) {
                        withAnimation {
                            scale = scale > 1 ? 1 : 2.5
                            settled = scale
                            offset = .zero
                            dragged = .zero
                        }
                    }
                    .accessibilityIdentifier("attachmentViewer.image.\(attachment.name)")
            } else if failed {
                Label("Couldn't load \(attachment.name)", systemImage: "photo").foregroundStyle(.white.opacity(0.7))
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if let image {
                ShareLink(item: Image(uiImage: image), preview: SharePreview(attachment.name, image: Image(uiImage: image))) {
                    Label("Share", systemImage: "square.and.arrow.up").font(.callout.weight(.medium))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .accessibilityIdentifier("attachmentViewer.share")
                .padding(.bottom, 40)
            }
        }
        .task(id: attachment.path) {
            image = await AttachmentLoader.image(attachment.path, store: store)
            failed = image == nil
        }
    }
}

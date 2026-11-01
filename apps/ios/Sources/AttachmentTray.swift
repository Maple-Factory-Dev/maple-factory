import MapleKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Photos, screen recordings and files picked for a brief, comment or steer, and how each upload
/// (`POST /api/attachments`, FactoryStore.upload) is going. NewTaskView and ComposeSheet share it.
@MainActor @Observable
final class AttachmentUploads {
    private(set) var items: [PendingAttachment] = []

    var uploading: Bool { items.contains { $0.state == .uploading } }
    var failed: Bool { items.contains { $0.state.failure != nil } }
    /// What went up, in the order picked: what the text links to.
    var attachments: [FactoryStore.Attachment] { items.compactMap(\.attachment) }

    /// Reads a picked item as data and starts its upload. A screenshot stays a PNG; a photo (HEIC on
    /// the phone, which browsers can't show) goes up as JPEG; a screen recording as it is.
    func add(_ item: PhotosPickerItem, index: Int, store: FactoryStore) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        let stamp = Self.stamp(index)
        let types = item.supportedContentTypes
        let pending: PendingAttachment
        if types.contains(where: { $0.conforms(to: .movie) }) {
            let mov = types.contains { $0.conforms(to: .mpeg4Movie) } ? ("mp4", "video/mp4") : ("mov", "video/quicktime")
            pending = PendingAttachment(data: data, filename: "recording-\(stamp).\(mov.0)", mime: mov.1, preview: nil)
        } else if types.contains(where: { $0.conforms(to: .png) }), let image = UIImage(data: data) {
            pending = PendingAttachment(data: data, filename: "screenshot-\(stamp).png", mime: "image/png", preview: image)
        } else if let image = UIImage(data: data), let jpeg = types.contains(where: { $0.conforms(to: .jpeg) }) ? data : image.jpegData(compressionQuality: 0.85) {
            pending = PendingAttachment(data: jpeg, filename: "IMG-\(stamp).jpg", mime: "image/jpeg", preview: image)
        } else {
            return
        }
        append(pending, store: store)
    }

    /// A file from the Files app (a log, a PDF, anything), as it is.
    func addFile(_ url: URL, store: FactoryStore) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let type = UTType(filenameExtension: url.pathExtension)
        let mime = type?.preferredMIMEType ?? "application/octet-stream"
        let preview = type?.conforms(to: .image) == true ? UIImage(data: data) : nil
        append(PendingAttachment(data: data, filename: url.lastPathComponent, mime: mime, preview: preview), store: store)
    }

    func remove(_ id: UUID) { items.removeAll { $0.id == id } }

    func retry(_ id: UUID, store: FactoryStore) { upload(id, store: store) }

    /// `-<flag> <n>` (or YES) adds n copies of the app's mark, a screenshot then photos, since UI tests
    /// can't drive the system photo picker.
    func injectTestAttachments(flag: String, store: FactoryStore) {
        guard items.isEmpty, let value = UserDefaults.standard.string(forKey: flag),
              let image = UIImage(named: "Mark") else { return }
        let count = Int(value) ?? (UserDefaults.standard.bool(forKey: flag) ? 1 : 0)
        for index in 0..<count {
            let pending = index == 0
                ? image.pngData().map { PendingAttachment(data: $0, filename: "screenshot-\(Self.stamp(index)).png", mime: "image/png", preview: image) }
                : image.jpegData(compressionQuality: 0.85).map { PendingAttachment(data: $0, filename: "IMG-\(Self.stamp(index)).jpg", mime: "image/jpeg", preview: image) }
            if let pending { append(pending, store: store) }
        }
    }

    private func append(_ pending: PendingAttachment, store: FactoryStore) {
        items.append(pending)
        upload(pending.id, store: store)
    }

    private func upload(_ id: UUID, store: FactoryStore) {
        guard let pending = items.first(where: { $0.id == id }) else { return }
        setState(id, .uploading)
        Task {
            do {
                let stored = try await store.upload(data: pending.data, filename: pending.filename, mime: pending.mime)
                setState(id, .uploaded, attachment: stored)
            } catch {
                setState(id, .failed(error.localizedDescription))
            }
        }
    }

    private func setState(_ id: UUID, _ state: PendingAttachment.State, attachment: FactoryStore.Attachment? = nil) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].state = state
        items[i].attachment = attachment
    }

    private static func stamp(_ index: Int) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyyMMdd-HHmmss"
        return format.string(from: .now) + (index > 0 ? "-\(index + 1)" : "")
    }
}

/// A photo, recording or file picked to attach, and how its upload is going.
struct PendingAttachment: Identifiable {
    enum State: Equatable {
        case uploading, uploaded, failed(String)
        var failure: String? { if case .failed(let why) = self { why } else { nil } }
        var label: String {
            switch self {
            case .uploading: "uploading"
            case .uploaded: "uploaded"
            case .failed: "failed"
            }
        }
    }

    let id = UUID()
    let data: Data
    let filename: String
    let mime: String
    let preview: UIImage?
    var state: State = .uploading
    var attachment: FactoryStore.Attachment?
}

/// The picked attachments as thumbnails (tap a failed one to retry, × to remove), then the Photos and
/// Files buttons. Accessibility identifiers start with `prefix` (`newTask`, `compose`).
struct AttachmentTray: View {
    @Environment(FactoryStore.self) private var store
    let uploads: AttachmentUploads
    let prefix: String
    @State private var picks: [PhotosPickerItem] = []
    @State private var importing = false

    var body: some View {
        if !uploads.items.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(uploads.items) { item in thumbnail(item) }
                }
                .padding(.vertical, 6)
            }
            .accessibilityIdentifier("\(prefix).attachments")
        }
        HStack(spacing: 16) {
            PhotosPicker(selection: $picks, maxSelectionCount: 6, matching: .any(of: [.images, .screenRecordings])) {
                Label("Add photos or screenshots", systemImage: "photo.badge.plus")
            }
            .accessibilityIdentifier("\(prefix).addPhotos")
            Spacer(minLength: 0)
            Button { importing = true } label: {
                Label("Files", systemImage: "paperclip")
            }
            .accessibilityIdentifier("\(prefix).addFiles")
        }
        .buttonStyle(.borderless)
        .onChange(of: picks) {
            let picked = picks
            picks = []
            for (index, item) in picked.enumerated() { Task { await uploads.add(item, index: index, store: store) } }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            for url in (try? result.get()) ?? [] { uploads.addFile(url, store: store) }
        }
    }

    private func thumbnail(_ item: PendingAttachment) -> some View {
        ZStack {
            Group {
                if let image = item.preview {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: item.mime.hasPrefix("video/") ? "film" : "doc").font(.title2)
                        if !item.mime.hasPrefix("video/") {
                            Text(item.filename).font(.caption2).lineLimit(2).multilineTextAlignment(.center).padding(.horizontal, 4)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary)
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .opacity(item.state == .uploaded ? 1 : 0.55)
            switch item.state {
            case .uploading:
                ProgressView().accessibilityLabel("Uploading \(item.filename)")
            case .failed:
                Button { uploads.retry(item.id, store: store) } label: {
                    Image(systemName: "arrow.clockwise.circle.fill").font(.title).foregroundStyle(.white, Theme.danger)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Retry \(item.filename)")
            case .uploaded:
                EmptyView()
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { uploads.remove(item.id) } label: {
                Image(systemName: "xmark.circle.fill").font(.body).foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .accessibilityLabel("Remove \(item.filename)")
        }
        .padding(.top, 6)
        .padding(.trailing, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(prefix).attachment.\(item.state.label)")
    }
}

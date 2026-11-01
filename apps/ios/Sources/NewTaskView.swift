import MapleKit
import PhotosUI
import SwiftUI

/// Starts a task from the phone: a goal, a title and brief, photos and screenshots for it, how soon,
/// which repo (when the goal spans several), the agent and the effort, and whether a planner picks it
/// up now or it waits as a draft. Sends `task.create`. Tickets aren't offered: on the Mac they come only
/// from intake requests, and there's no ticket search to pick one from.
struct NewTaskView: View {
    @Environment(FactoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var goalID: String
    @State private var title = ""
    @State private var brief = ""
    @State private var priority: Wire.Priority = .p2
    @State private var repo: String?
    @State private var plan = true
    @State private var agent = "claude"
    /// "" for none, an effort's name, or `Self.newEffort` while one is typed in.
    @State private var effort = ""
    @State private var newEffort = ""
    @State private var picks: [PhotosPickerItem] = []
    @State private var photos: [PendingPhoto] = []
    @FocusState private var titleFocused: Bool
    @FocusState private var effortFocused: Bool

    private static let newEffort = "\u{0}new"

    init(goal: String) {
        _goalID = State(initialValue: goal)
    }

    private var goal: Wire.Goal? { store.feed.goal(goalID) }
    private var uploading: Bool { photos.contains { $0.state == .uploading } }
    private var canSend: Bool { goal != nil && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !uploading }
    private var chosenEffort: String? {
        let name = effort == Self.newEffort ? newEffort : effort
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let priorityTitles: [Wire.Priority: String] = [.p0: "Do it right away", .p1: "Next", .p2: "Soon", .p3: "When there's room"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Goal", selection: $goalID) {
                        ForEach(store.feed.activeGoals) { goal in
                            Text(goal.name).tag(goal.id)
                        }
                    }
                    .accessibilityIdentifier("newTask.goal")
                    if let goal, goal.repos.count > 1 {
                        Picker("Repo", selection: $repo) {
                            ForEach(goal.repos, id: \.self) { Text($0).tag(Optional($0)) }
                        }
                        .accessibilityIdentifier("newTask.repo")
                    }
                }
                Section {
                    TextField("Title", text: $title)
                        .focused($titleFocused)
                        .accessibilityIdentifier("newTask.title")
                    TextField("What should it do, and why?", text: $brief, axis: .vertical)
                        .lineLimit(5...12)
                        .accessibilityIdentifier("newTask.brief")
                } footer: {
                    Text("Left empty, the title is the brief.")
                }
                attachmentsSection
                Section {
                    Picker("Priority", selection: $priority) {
                        ForEach(Wire.Priority.allCases, id: \.self) { priority in
                            Text("\(priority.rawValue.uppercased()) · \(Self.priorityTitles[priority] ?? "")").tag(priority)
                        }
                    }
                    .accessibilityIdentifier("newTask.priority")
                    if store.agents.count > 1 {
                        Picker("Agent", selection: $agent) {
                            ForEach(store.agents, id: \.self) { id in
                                Label { Text(Self.agentTitle(id)) } icon: { Image(systemName: Self.agentSymbol(id)) }.tag(id)
                            }
                        }
                        .accessibilityIdentifier("newTask.agent")
                    }
                    Picker("Effort", selection: $effort) {
                        Text("None").tag("")
                        if let goal {
                            ForEach(store.efforts(in: goal), id: \.self) { Text($0).tag($0) }
                        }
                        Text("New effort…").tag(Self.newEffort)
                    }
                    .accessibilityIdentifier("newTask.effort")
                    if effort == Self.newEffort {
                        TextField("Effort name", text: $newEffort)
                            .focused($effortFocused)
                            .accessibilityIdentifier("newTask.newEffort")
                    }
                }
                Section {
                    Picker("When", selection: $plan) {
                        Text("Plan now").tag(true)
                        Text("Save as draft").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("newTask.when")
                } footer: {
                    Text(plan ? "A planner writes a plan for you to approve." : "It waits in the goal's drafts until you send it to planning.")
                }
            }
            .navigationTitle("New task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        guard let goal else { return }
                        store.createTask(goal: goal, title: title, brief: brief, repo: goal.repos.count > 1 ? repo : nil, priority: priority, plan: plan,
                                         agent: agent, effort: chosenEffort, attachments: photos.compactMap(\.attachment))
                        dismiss()
                    }
                    .disabled(!canSend)
                    .accessibilityIdentifier("newTask.send")
                }
            }
            .onAppear {
                repo = goal?.repo ?? goal?.repos.first
                // Opened by `-newTask YES` for a screenshot, the keyboard would hide the form.
                titleFocused = !UserDefaults.standard.bool(forKey: "newTask")
                injectTestAttachments()
                // `-newTaskEffort <name>` opens with a new effort typed in, for a screenshot.
                if let name = UserDefaults.standard.string(forKey: "newTaskEffort"), !name.isEmpty {
                    effort = Self.newEffort
                    newEffort = name
                }
            }
            .onChange(of: goalID) {
                repo = goal?.repo ?? goal?.repos.first
                effort = ""
                newEffort = ""
            }
            .onChange(of: effort) { effortFocused = effort == Self.newEffort && !UserDefaults.standard.bool(forKey: "newTask") }
            .onChange(of: picks) {
                let items = picks
                picks = []
                for (index, item) in items.enumerated() { Task { await add(item, index: index) } }
            }
        }
    }

    // MARK: Attachments

    private var attachmentsSection: some View {
        Section {
            if !photos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(photos) { photo in thumbnail(photo) }
                    }
                    .padding(.vertical, 6)
                }
                .accessibilityIdentifier("newTask.attachments")
            }
            PhotosPicker(selection: $picks, maxSelectionCount: 6, matching: .any(of: [.images, .screenRecordings])) {
                Label("Add photos or screenshots", systemImage: "photo.badge.plus")
            }
            .accessibilityIdentifier("newTask.addPhotos")
        } header: {
            Text("Attachments")
        } footer: {
            if photos.contains(where: { $0.state.failure != nil }) {
                Text("Tap a photo that didn't go up to try again.")
            } else if uploading {
                Text("Send waits for the uploads to finish.")
            }
        }
    }

    private func thumbnail(_ photo: PendingPhoto) -> some View {
        ZStack {
            Group {
                if let image = photo.preview {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "film").font(.title2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary)
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .opacity(photo.state == .uploaded ? 1 : 0.55)
            switch photo.state {
            case .uploading:
                ProgressView().accessibilityLabel("Uploading \(photo.filename)")
            case .failed:
                Button { retry(photo.id) } label: {
                    Image(systemName: "arrow.clockwise.circle.fill").font(.title).foregroundStyle(.white, Theme.danger)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Retry \(photo.filename)")
            case .uploaded:
                EmptyView()
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { photos.removeAll { $0.id == photo.id } } label: {
                Image(systemName: "xmark.circle.fill").font(.body).foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .accessibilityLabel("Remove \(photo.filename)")
        }
        .padding(.top, 6)
        .padding(.trailing, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("newTask.attachment.\(photo.state.label)")
    }

    /// Reads a picked item as data and starts its upload. A screenshot stays a PNG; a photo (HEIC on
    /// the phone, which browsers can't show) goes up as JPEG; a screen recording as it is.
    private func add(_ item: PhotosPickerItem, index: Int) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        let stamp = Self.stamp(index)
        let types = item.supportedContentTypes
        let photo: PendingPhoto
        if types.contains(where: { $0.conforms(to: .movie) }) {
            let mov = types.contains { $0.conforms(to: .mpeg4Movie) } ? ("mp4", "video/mp4") : ("mov", "video/quicktime")
            photo = PendingPhoto(data: data, filename: "recording-\(stamp).\(mov.0)", mime: mov.1, preview: nil)
        } else if types.contains(where: { $0.conforms(to: .png) }), let image = UIImage(data: data) {
            photo = PendingPhoto(data: data, filename: "screenshot-\(stamp).png", mime: "image/png", preview: image)
        } else if let image = UIImage(data: data), let jpeg = types.contains(where: { $0.conforms(to: .jpeg) }) ? data : image.jpegData(compressionQuality: 0.85) {
            photo = PendingPhoto(data: jpeg, filename: "IMG-\(stamp).jpg", mime: "image/jpeg", preview: image)
        } else {
            return
        }
        photos.append(photo)
        upload(photo.id)
    }

    private func upload(_ id: UUID) {
        guard let photo = photos.first(where: { $0.id == id }) else { return }
        setState(id, .uploading)
        Task {
            do {
                let stored = try await store.upload(data: photo.data, filename: photo.filename, mime: photo.mime)
                setState(id, .uploaded, attachment: stored)
            } catch {
                setState(id, .failed(error.localizedDescription))
            }
        }
    }

    private func retry(_ id: UUID) { upload(id) }

    private func setState(_ id: UUID, _ state: PendingPhoto.State, attachment: FactoryStore.Attachment? = nil) {
        guard let i = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[i].state = state
        photos[i].attachment = attachment
    }

    /// `-newTaskAttachment <n>` (or YES) adds n copies of the app's mark, a screenshot then photos, since
    /// UI tests can't drive the system photo picker.
    private func injectTestAttachments() {
        guard photos.isEmpty, let flag = UserDefaults.standard.string(forKey: "newTaskAttachment"),
              let image = UIImage(named: "Mark") else { return }
        let count = Int(flag) ?? (UserDefaults.standard.bool(forKey: "newTaskAttachment") ? 1 : 0)
        for index in 0..<count {
            let photo = index == 0
                ? image.pngData().map { PendingPhoto(data: $0, filename: "screenshot-\(Self.stamp(index)).png", mime: "image/png", preview: image) }
                : image.jpegData(compressionQuality: 0.85).map { PendingPhoto(data: $0, filename: "IMG-\(Self.stamp(index)).jpg", mime: "image/jpeg", preview: image) }
            guard let photo else { continue }
            photos.append(photo)
            upload(photo.id)
        }
    }

    private static func stamp(_ index: Int) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyyMMdd-HHmmss"
        return format.string(from: .now) + (index > 0 ? "-\(index + 1)" : "")
    }

    static func agentTitle(_ id: String) -> String {
        switch id {
        case "claude": "Claude Code"
        case "codex": "Codex"
        default: id.capitalized
        }
    }

    static func agentSymbol(_ id: String) -> String {
        switch id {
        case "claude": "sparkle"
        case "codex": "chevron.left.forwardslash.chevron.right"
        default: "terminal"
        }
    }
}

/// A photo or recording picked for the brief, and how its upload is going.
private struct PendingPhoto: Identifiable {
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

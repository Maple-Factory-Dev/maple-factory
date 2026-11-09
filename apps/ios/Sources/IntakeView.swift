import MapleKit
import SwiftUI

/// The Requests list: work asked for from Slack, Linear, Jira or the API, before it becomes a task.
struct IntakeRoute: Hashable {}
/// One request's detail.
struct IntakeRequestRoute: Hashable { let id: String }

extension Wire.IntakeRequest {
    var sourceIcon: String {
        switch source {
        case "slack": "number"
        case "linear": "line.diagonal"
        case "jira": "diamond.fill"
        default: "curlybraces"
        }
    }

    var sourceColor: Color {
        switch source {
        case "slack": Color(hex: 0xE01E5A)
        case "linear": Color(hex: 0x5E6AD2)
        case "jira": Color(hex: 0x2684FF)
        default: .secondary
        }
    }

    var sourceTitle: String { IntakeBrief.sourceTitle(self) }
}

extension IntakeStatus {
    var color: Color {
        switch self {
        case .new: Theme.accent
        case .clarifying: Theme.warning
        case .accepted: Color(light: 0x8250DF, dark: 0xA371F7)
        case .declined: .secondary
        }
    }
}

extension FactoryStore {
    /// An accepted request leaves In flight once its task merges or is cancelled; an unknown task is still running.
    func intakeTaskFinished(_ id: String) -> Bool {
        guard let task = feed.task(id) else { return false }
        return task.state == .merged || task.state == .cancelled
    }

    func intakeRequest(_ id: String) -> Wire.IntakeRequest? { feed.intake.first { $0.id == id } }
}

enum IntakeTime {
    static func ago(_ ms: UInt64) -> String {
        let minutes = max(0, (Date().timeIntervalSince1970 * 1000 - Double(ms)) / 60_000)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(Int(minutes))m" }
        if minutes < 60 * 24 { return "\(Int(minutes / 60))h" }
        return "\(Int(minutes / 60 / 24))d"
    }
}

struct SourceGlyph: View {
    let request: Wire.IntakeRequest
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: request.sourceIcon)
            .font(.system(size: size * 0.45, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(request.sourceColor, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityLabel(request.sourceTitle)
    }
}

struct IntakeStatusPill: View {
    let status: IntakeStatus

    var body: some View {
        Text(status.title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(status.color)
            .background(status.color.opacity(0.14), in: Capsule())
            .lineLimit(1)
    }
}

// MARK: - List

struct IntakeListView: View {
    @Environment(FactoryStore.self) private var store
    @State private var filter: IntakeFilter = .all

    var body: some View {
        let requests = store.feed.intake
        let counts = IntakeFilter.counts(requests, isFinished: store.intakeTaskFinished)
        let visible = IntakeFilter.visible(requests, filter: filter, isFinished: store.intakeTaskFinished)
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(IntakeFilter.allCases) { option in
                            Button { withAnimation(.snappy(duration: 0.2)) { filter = option } } label: {
                                HStack(spacing: 4) {
                                    Text(option.title)
                                    Text("\(counts[option, default: 0])").foregroundStyle(filter == option ? .white.opacity(0.8) : .secondary)
                                }
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .foregroundStyle(filter == option ? .white : .primary)
                                .background(filter == option ? Theme.accent : Color(.secondarySystemFill), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("intake.filter.\(option.rawValue)")
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            if visible.isEmpty {
                ContentUnavailableView(filter.emptyTitle, systemImage: filter.icon,
                                       description: Text("Requests from Slack, Linear and Jira land here before they become tasks."))
                    .listRowBackground(Color.clear)
            }
            ForEach(visible) { request in
                NavigationLink(value: IntakeRequestRoute(id: request.id)) { IntakeRow(request: request) }
                    .accessibilityIdentifier("intake.row.\(request.id)")
            }
        }
        .navigationTitle("Requests")
        .refreshable { await store.refresh() }
    }
}

struct IntakeRow: View {
    let request: Wire.IntakeRequest

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SourceGlyph(request: request)
            VStack(alignment: .leading, spacing: 5) {
                Text(request.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text("\(request.requester) · \(IntakeTime.ago(request.at))")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    IntakeStatusPill(status: request.intakeStatus)
                    if !request.tickets.isEmpty {
                        Label("\(request.tickets.count)", systemImage: "ticket")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Detail

struct IntakeDetailView: View {
    @Environment(FactoryStore.self) private var store
    let id: String

    @State private var asking = UserDefaults.standard.bool(forKey: "intakeAsk")
    @State private var attaching = false
    @State private var starting = UserDefaults.standard.bool(forKey: "intakeStart")
    @State private var confirmingDecline = false

    var body: some View {
        if let request = store.intakeRequest(id) {
            content(request)
        } else {
            ContentUnavailableView("Request not found", systemImage: "tray")
        }
    }

    private func content(_ request: Wire.IntakeRequest) -> some View {
        let status = request.intakeStatus
        return List {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    SourceGlyph(request: request, size: 38)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(request.title).font(.headline)
                        Text("\(request.requester) in \(request.sourceTitle) · \(IntakeTime.ago(request.at))")
                            .font(.caption).foregroundStyle(.secondary)
                        IntakeStatusPill(status: status).accessibilityIdentifier("intake.status")
                    }
                }
                .padding(.vertical, 4)
                if case .accepted(let task) = status, !task.isEmpty {
                    NavigationLink(value: TaskRoute(id: task)) {
                        Label("Open \(task)", systemImage: "arrow.right.circle")
                    }
                    .accessibilityIdentifier("intake.openTask")
                } else if let related = request.relatedTask {
                    NavigationLink(value: TaskRoute(id: related)) {
                        Label("Looks like \(related)", systemImage: "link")
                    }
                }
            }

            if !request.gaps.isEmpty, !status.isSettled {
                Section("Needs before planning") {
                    ForEach(request.gaps, id: \.self) { gap in
                        Label(gap, systemImage: "questionmark.circle").foregroundStyle(Theme.warning)
                    }
                }
            }

            if !request.tickets.isEmpty {
                Section("Tickets") {
                    ForEach(request.tickets, id: \.key) { TicketRow(ticket: $0) }
                }
            }

            Section("Thread") {
                ForEach(Array(request.thread.enumerated()), id: \.offset) { _, message in
                    ThreadMessageRow(message: message)
                }
            }
        }
        .navigationTitle("Request")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if !status.isSettled { actionBar(request) }
        }
        .sheet(isPresented: $asking) { IntakeAskSheet(request: request) }
        .sheet(isPresented: $attaching) { IntakeAttachSheet(request: request) }
        .sheet(isPresented: $starting) {
            NewTaskView(prefill: IntakePrefill(request, goals: store.feed.activeGoals))
        }
        .confirmationDialog("Decline this request?", isPresented: $confirmingDecline, titleVisibility: .visible) {
            Button("Decline", role: .destructive) { store.declineIntake(request.id) }
                .accessibilityIdentifier("intake.confirmDecline")
        } message: {
            Text("\(request.requester) is told in \(request.sourceTitle) that it was passed on.")
        }
    }

    private func actionBar(_ request: Wire.IntakeRequest) -> some View {
        HStack(spacing: 8) {
            Button { starting = true } label: {
                Label("Start task", systemImage: "plus").lineLimit(1).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .accessibilityIdentifier("intake.start")
            Button { asking = true } label: { Label("Ask", systemImage: "bubble.left").lineLimit(1) }
                .fixedSize()
                .accessibilityIdentifier("intake.ask")
            Button { attaching = true } label: { Label("Attach", systemImage: "link").lineLimit(1) }
                .fixedSize()
                .accessibilityIdentifier("intake.attach")
            Button(role: .destructive) { confirmingDecline = true } label: { Image(systemName: "xmark") }
                .accessibilityLabel("Decline")
                .accessibilityIdentifier("intake.decline")
        }
        .buttonStyle(.bordered)
        .labelStyle(.titleAndIcon)
        .controlSize(.regular)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

struct TicketRow: View {
    let ticket: Wire.TicketLink

    var body: some View {
        let jira = ticket.system.lowercased() == "jira"
        HStack(spacing: 10) {
            Image(systemName: jira ? "diamond.fill" : "line.diagonal")
                .font(.caption.weight(.bold))
                .foregroundStyle(jira ? Color(hex: 0x2684FF) : Color(hex: 0x5E6AD2))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(ticket.title).font(.subheadline).lineLimit(2)
                Text("\(ticket.key) · \(ticket.status)").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
    }
}

struct ThreadMessageRow: View {
    let message: Wire.IntakeMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if message.bot {
                    Image(systemName: "leaf.fill").font(.caption2).foregroundStyle(Theme.accent)
                }
                Text(message.bot ? "Maple" : message.author).font(.caption.weight(.semibold))
                if let task = message.relayedFrom {
                    Text("from \(task)").font(.caption2.weight(.medium)).foregroundStyle(Theme.warning)
                }
                Spacer()
                Text(IntakeTime.ago(message.at)).font(.caption2).foregroundStyle(.secondary)
            }
            Text(message.text).font(.subheadline)
                .foregroundStyle(message.bot ? .secondary : .primary)
        }
        .padding(.vertical, 2)
        .listRowBackground(message.bot ? Theme.accent.opacity(0.06) : nil)
    }
}

// MARK: - Sheets

struct IntakeAskSheet: View {
    @Environment(FactoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: Wire.IntakeRequest
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What do you need to know?", text: $text, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($focused)
                        .accessibilityIdentifier("intake.askText")
                } footer: {
                    Text("Maple posts it in \(request.sourceTitle) for \(request.requester).")
                }
            }
            .navigationTitle("Ask \(request.requester.split(separator: " ").first.map(String.init) ?? request.requester)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        store.askIntake(request.id, text: text)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("intake.askSend")
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }
}

struct IntakeAttachSheet: View {
    @Environment(FactoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: Wire.IntakeRequest
    @State private var search = ""

    /// Open tasks, the request's related task first.
    private var tasks: [Wire.Task] {
        let open = store.feed.tasks.filter { $0.state != .merged && $0.state != .cancelled }
            .sorted { ($0.id == request.relatedTask ? 0 : 1, $1.updatedAt) < ($1.id == request.relatedTask ? 0 : 1, $0.updatedAt) }
        guard !search.isEmpty else { return open }
        return open.filter { $0.title.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List(tasks, id: \.id) { task in
                Button {
                    store.attachIntake(request.id, task: task.id)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(task.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                            if task.id == request.relatedTask {
                                Text("Looks related").font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent)
                            }
                        }
                        Text(task.title).font(.subheadline).foregroundStyle(.primary)
                    }
                }
                .accessibilityIdentifier("intake.attachTo.\(task.id)")
            }
            .searchable(text: $search, prompt: "Open tasks")
            .navigationTitle("Attach to a task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

/// What New task opens with when it's started from a request.
struct IntakePrefill {
    let id: String
    let title: String
    let brief: String
    let goal: String
    let tickets: [Wire.TicketLink]

    init(_ request: Wire.IntakeRequest, goals: [Wire.Goal]) {
        id = request.id
        title = request.title
        brief = IntakeBrief.compose(request)
        goal = goals.first { $0.id == request.suggestedGoal }?.id ?? goals.first?.id ?? ""
        tickets = request.tickets
    }
}

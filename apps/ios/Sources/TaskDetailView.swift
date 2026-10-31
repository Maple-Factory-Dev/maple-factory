import AVKit
import MapleKit
import SwiftUI
import WebKit

/// One task: what it's for, its plan, review, proofs, diff and timeline, with a bar of whatever its
/// stage lets you do: approve the plan, request changes, approve changes, merge or hold, answer, comment.
struct TaskDetailView: View {
    @Environment(FactoryStore.self) private var store
    let id: String

    @State private var section: Section = .overview
    @State private var compose: Compose?

    enum Section: String, CaseIterable { case overview = "Overview", review = "Review", diff = "Diff", timeline = "Timeline" }

    var body: some View {
        if let task = store.feed.task(id) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(task)
                    Picker("Section", selection: $section) {
                        ForEach(Section.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    switch section {
                    case .overview: overview(task)
                    case .review: ReviewSection(task: task)
                    case .diff: DiffSection(task: task)
                    case .timeline: TimelineSection(task: task)
                    }
                }
                .padding(16)
            }
            .navigationTitle(task.id)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { TaskActionsMenu(task: task) } }
            .safeAreaInset(edge: .bottom) { ActionBar(task: task, compose: $compose) }
            .sheet(item: $compose) { ComposeSheet(compose: $0) }
            .refreshable { await store.refresh() }
            .onAppear { store.viewing(id) }
            .onDisappear { store.viewing(nil) }
        } else if !store.feed.hasSnapshot {
            // Opened from a link before the feed landed: it fills in when the snapshot does.
            ProgressView().navigationTitle(id).navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("Task not found", systemImage: "questionmark.square.dashed")
        }
    }

    private func header(_ task: Wire.Task) -> some View {
        let goal = store.feed.goal(task.goal)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let goal {
                    Text(goal.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color(goalHex: goal.color))
                }
                StatePill(state: task.state)
                Spacer()
            }
            Text(task.title).font(.title2.bold())
            HStack(spacing: 6) {
                Avatar(login: task.owner, url: store.feed.member(task.owner)?.avatarUrl, size: 20)
                Text(task.owner).font(.subheadline)
                Text("· \(task.agent)\(task.model.map { " \($0)" } ?? "") · updated \(When.ago(task.updatedAt))")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if let waiting = task.waiting { Label(waiting, systemImage: "hourglass").font(.footnote).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private func overview(_ task: Wire.Task) -> some View {
        if let worker = task.worker, let activity = store.feed.workerActivity(for: worker), let prompt = activity.permission {
            PermissionPromptCard(task: task, role: worker.role.rawValue, prompt: prompt).id(activity.at)
        }
        if let hand = task.hand { HandCard(task: task, hand: hand) }
        if let question = task.question { QuestionCard(task: task, question: question) }
        if !task.brief.isEmpty {
            Card("Brief", icon: "doc.text") { Text(LocalizedStringKey(task.brief)).font(.callout) }
        }
        if !task.plan.isEmpty {
            Card("Plan v\(task.planVersion)", icon: "list.number") {
                if let summary = task.planSummary { Text(summary).font(.callout).foregroundStyle(.secondary) }
                ForEach(Array(task.plan.enumerated()), id: \.offset) { index, step in
                    PlanStepRow(number: index + 1, step: step)
                }
                if task.approvalsNeeded > 0 {
                    Label("\(task.approvals.count) of \(task.approvalsNeeded) approvals\(task.approvals.isEmpty ? "" : ": " + task.approvals.joined(separator: ", "))", systemImage: "checkmark.seal")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        if !task.doneWhen.isEmpty {
            Card("Done when", icon: "checklist") {
                ForEach(Array(task.doneWhen.enumerated()), id: \.offset) { index, item in DoneItemRow(task: task, index: index, item: item, compose: $compose) }
            }
        }
        if let risk = task.risk {
            Card("Risk: \(risk.level.rawValue)", icon: "exclamationmark.shield") {
                ForEach(risk.reasons, id: \.self) { Text("• \($0)").font(.callout) }
                if let footprint = task.footprint {
                    Text("\(footprint.files) files, ~\(footprint.lines) lines\(footprint.estimated ? " (estimated)" : "")").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        ForEach(task.mockups, id: \.id) { mockup in
            Card("Mockup: \(mockup.title)", icon: "photo.on.rectangle") { MockupView(task: task, mockup: mockup, compose: $compose) }
        }
    }
}

// MARK: - Cards

struct Card<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    init(_ title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color(.separator).opacity(0.4)))
    }
}

struct PlanStepRow: View {
    let number: Int
    let step: Wire.PlanStep

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(color.opacity(0.15))
                if step.progress == .done {
                    Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(color)
                } else {
                    Text("\(number)").font(.caption2.bold()).foregroundStyle(color)
                }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(step.text).font(.callout)
                Text(step.file).font(.caption.monospaced()).foregroundStyle(.secondary)
                if let from = step.from { Text("Was: \(from)").font(.caption).strikethrough().foregroundStyle(.tertiary) }
                if step.added { Text("New in this version").font(.caption2.weight(.semibold)).foregroundStyle(Theme.approve) }
            }
        }
    }

    private var color: Color {
        switch step.progress {
        case .done: Theme.approve
        case .active: Theme.state(.building)
        default: .secondary
        }
    }
}

struct DoneItemRow: View {
    @Environment(FactoryStore.self) private var store
    let task: Wire.Task
    let index: Int
    let item: Wire.DoneItem
    @Binding var compose: Compose?

    /// The server takes your word for an item while the task is building or in review.
    private var canAttest: Bool { item.status != .proven && (task.state == .building || task.state == .reviewing) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Image(systemName: item.status == .proven ? "checkmark.circle.fill" : item.status == .failed ? "xmark.circle.fill" : "circle")
                    .foregroundStyle(item.status == .proven ? Theme.approve : item.status == .failed ? Theme.danger : .secondary)
                Text(item.text).font(.callout)
                Spacer()
                Text(item.proof.rawValue).font(.caption2).foregroundStyle(.secondary)
            }
            if let evidence = item.evidence { EvidenceView(evidence: evidence) }
            if canAttest {
                Button {
                    compose = Compose(title: "I checked it", placeholder: "Why? (optional)", send: "Mark checked", optional: true) { [store, task, index] note in
                        store.checkedIt(task.id, item: index, note: note)
                    }
                } label: {
                    Label("I checked it", systemImage: "checkmark.seal").font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("attest-\(index)")
            }
        }
    }
}

/// What proves a Done when item: terminal output, test counts, or an image or video.
struct EvidenceView: View {
    @Environment(FactoryStore.self) private var store
    let evidence: Wire.Evidence
    @State private var image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(evidence.summary).font(.footnote).foregroundStyle(.secondary)
            if let passed = evidence.passed {
                Text("\(passed) passed\(evidence.failed.map { ", \($0) failed" } ?? "")").font(.caption.weight(.semibold)).foregroundStyle(evidence.failed ?? 0 > 0 ? Theme.danger : Theme.approve)
            }
            if evidence.command != nil || !evidence.output.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    if let command = evidence.command { Text("$ \(command)").bold() }
                    ForEach(Array(evidence.output.suffix(12).enumerated()), id: \.offset) { Text($0.element) }
                }
                .font(.caption2.monospaced())
                .foregroundStyle(.white.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.12)))
            }
            if let file = evidence.file {
                if evidence.kind == .video, let request = store.request(file), let url = request.url {
                    VideoPlayer(player: AVPlayer(playerItem: AVPlayerItem(asset: AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": request.allHTTPHeaderFields ?? [:]]))))
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else if let image {
                    Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    ProgressView().task { if let data = await store.attachment(file) { image = UIImage(data: data) } }
                }
            }
        }
    }
}

struct HandCard: View {
    @Environment(FactoryStore.self) private var store
    let task: Wire.Task
    let hand: Wire.Hand

    var body: some View {
        Card("Raised hand: \(hand.reason.rawValue)", icon: "exclamationmark.triangle.fill") {
            Text(hand.summary).font(.callout)
            Text("For \(hand.assignee) · \(When.ago(hand.at)) ago").font(.caption).foregroundStyle(.secondary)
            ForEach(hand.options, id: \.title) { option in
                Button { store.resolveHand(task.id, option: option.title, note: "") } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.title + (option.recommended ? " (recommended)" : "")).font(.callout.weight(.medium))
                        Text(option.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .tint(option.recommended ? Theme.approve : .secondary)
            }
        }
        .tint(Theme.warning)
    }
}

/// The worker stopped at a permission prompt in its session: what it wants to run, and Yes / No.
/// A new prompt (a new activity) gives it a fresh identity, so "Sent" only covers the one answered.
struct PermissionPromptCard: View {
    @Environment(FactoryStore.self) private var store
    let task: Wire.Task
    let role: String
    let prompt: PermissionPrompt

    @State private var sent: Wire.PromptChoice?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("\(role.capitalized) is waiting on you", systemImage: "hand.raised.fill")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Theme.state(.awaitingApproval).opacity(0.15)))
                .foregroundStyle(Theme.state(.awaitingApproval))
            (Text("Wants to run ") + Text(prompt.tool).bold() + Text(": \(prompt.summary)"))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = prompt.detail {
                ScrollView {
                    Text(detail)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 140)
                .fixedSize(horizontal: false, vertical: true)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(.tertiarySystemGroupedBackground)))
            }
            if let warning = prompt.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.warning)
            }
            if let sent {
                Label("Sent: \(sent == .yes ? "Yes" : "No")", systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("permission-sent")
            }
            VStack(spacing: 8) {
                Button { answer(.yes) } label: { Text("Yes").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.approve)
                    .accessibilityIdentifier("permission-yes")
                Button { answer(.no) } label: { Text("No").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("permission-no")
            }
            .controlSize(.large)
            .disabled(sent != nil)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.state(.awaitingApproval).opacity(0.5)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("permission-card")
    }

    private func answer(_ choice: Wire.PromptChoice) {
        sent = choice
        store.answerPrompt(task.id, choice: choice)
    }
}

struct QuestionCard: View {
    @Environment(FactoryStore.self) private var store
    let task: Wire.Task
    let question: Wire.Question

    var body: some View {
        Card("The \(question.role.rawValue) asks", icon: "questionmark.bubble.fill") {
            Text(question.text).font(.callout)
            HStack {
                ForEach(question.options, id: \.self) { option in
                    Button(option) { store.answer(task.id, text: option) }.buttonStyle(.bordered)
                }
            }
        }
    }
}

/// A planner's mockup: a screen (HTML) in a web view, or terminal lines.
struct MockupView: View {
    @Environment(FactoryStore.self) private var store
    let task: Wire.Task
    let mockup: Wire.Mockup
    @Binding var compose: Compose?

    var body: some View {
        if mockup.kind == "terminal" {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(mockup.lines.enumerated()), id: \.offset) { _, line in
                    Text(line.text).foregroundStyle(line.style == "error" ? Theme.danger : line.style == "dim" ? .gray : .white)
                }
            }
            .font(.caption2.monospaced())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.12)))
        } else {
            WebView(html: mockup.html, request: mockup.html == nil ? mockup.url.flatMap { store.request($0) } : nil)
                .frame(height: 320)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        ForEach(mockup.notes, id: \.self) { Text("• \($0)").font(.caption).foregroundStyle(.secondary) }
        if mockup.status == .changesRequested {
            Label("Changes requested · v\(mockup.version + 1) coming", systemImage: "paintbrush.pointed")
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.warning)
                .accessibilityIdentifier("mockup-changes-requested-\(mockup.id)")
        } else if task.state == .planning || task.state == .awaitingApproval {
            // Only while the plan is open: past it, nothing would deliver the change to the planner.
            Button {
                compose = Compose(title: "Change \"\(mockup.title)\"", placeholder: "What should the planner change in this mockup?", send: "Request") { [store, task, mockup] text in
                    store.requestMockupChange(task.id, mockup: mockup.id, text: text)
                }
            } label: {
                Label("Request change", systemImage: "paintbrush.pointed").font(.subheadline)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("mockup-change-\(mockup.id)")
        }
    }
}

struct WebView: UIViewRepresentable {
    let html: String?
    let request: URLRequest?

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.isOpaque = false
        view.scrollView.bounces = false
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        if let html { view.loadHTMLString(html, baseURL: nil) } else if let request { view.load(request) }
    }
}

// MARK: - Review

struct ReviewSection: View {
    let task: Wire.Task

    var body: some View {
        if let review = task.autoReview {
            Card("Automatic review", icon: "sparkle.magnifyingglass") {
                if let round = review.rounds.last {
                    Label("Round \(round.number) of \(review.maxRounds): \(round.verdict.rawValue)", systemImage: round.verdict == .passed ? "checkmark.seal.fill" : "arrow.triangle.2.circlepath")
                        .foregroundStyle(round.verdict == .passed ? Theme.approve : Theme.warning)
                        .font(.subheadline.weight(.medium))
                }
                Text(review.summary).font(.callout)
                ForEach(review.ask + review.proofs, id: \.text) { check in
                    Label(check.text, systemImage: check.verdict == .met ? "checkmark" : "exclamationmark")
                        .font(.footnote).foregroundStyle(check.verdict == .met ? Theme.approve : Theme.warning)
                }
            }
            if !review.findings.isEmpty {
                Card("Findings", icon: "ladybug") {
                    ForEach(review.findings, id: \.id) { finding in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(finding.severity.rawValue).font(.caption2.weight(.bold)).foregroundStyle(finding.severity == .blocker ? Theme.danger : Theme.warning)
                                Text(finding.kind.rawValue).font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                                Text(finding.status == .fixed ? "Fixed in round \(finding.fixedIn ?? 0)" : finding.status.rawValue).font(.caption2).foregroundStyle(finding.status == .fixed ? Theme.approve : .secondary)
                            }
                            Text(finding.text).font(.callout).strikethrough(finding.status == .fixed, color: .secondary)
                            if let file = finding.file { Text(file).font(.caption.monospaced()).foregroundStyle(.secondary) }
                        }
                        Divider()
                    }
                }
            }
        } else {
            ContentUnavailableView("No review yet", systemImage: "eye", description: Text("The review agent reads the change once it's pushed."))
        }
        if let pr = task.pr {
            Card("Pull request #\(pr.number)", icon: "arrow.triangle.pull") {
                Text("\(pr.branch) → \(pr.base) · \(pr.state.rawValue)").font(.footnote.monospaced()).foregroundStyle(.secondary)
                ForEach(pr.checks, id: \.name) { check in
                    HStack {
                        Image(systemName: check.status == .passed ? "checkmark.circle.fill" : check.status == .failed ? "xmark.circle.fill" : "clock")
                            .foregroundStyle(check.status == .passed ? Theme.approve : check.status == .failed ? Theme.danger : .secondary)
                        Text(check.name)
                        Spacer()
                        Text(check.duration ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
                if let link = pr.url.flatMap(URL.init(string:)) { Link("Open on GitHub", destination: link).font(.callout) }
            }
        }
    }
}

// MARK: - Diff

struct DiffSection: View {
    @Environment(FactoryStore.self) private var store
    let task: Wire.Task

    private var key: String { "\(task.pr?.head ?? "")-\(task.diff?.added ?? 0)-\(task.diff?.removed ?? 0)" }

    var body: some View {
        Group {
            if let files = store.diffs[task.id]?.files {
                if files.isEmpty {
                    ContentUnavailableView("No changes yet", systemImage: "doc.text.magnifyingglass")
                }
                ForEach(files) { file in DiffFileView(file: file) }
            } else if task.diff == nil && task.pr == nil {
                ContentUnavailableView("No changes yet", systemImage: "doc.text.magnifyingglass", description: Text("The diff appears once the builder starts writing."))
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .task(id: key) { await store.loadDiff(task: task.id, key: key) }
    }
}

struct DiffFileView: View {
    let file: DiffFile
    @State private var open = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation { open.toggle() } } label: {
                HStack {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption)
                    Text(file.path).font(.caption.monospaced().weight(.medium)).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Text("+\(file.added)").foregroundStyle(Theme.approve)
                    Text("−\(file.removed)").foregroundStyle(Theme.danger)
                }
                .font(.caption.monospaced())
                .padding(10)
            }
            .buttonStyle(.plain)
            if open {
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(file.hunks) { hunk in
                            Text(hunk.header).foregroundStyle(.secondary).padding(.vertical, 3).padding(.horizontal, 8)
                            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                                HStack(spacing: 6) {
                                    Text(line.new.map(String.init) ?? line.old.map(String.init) ?? "").foregroundStyle(.tertiary).frame(width: 30, alignment: .trailing)
                                    Text(line.kind == .added ? "+" : line.kind == .removed ? "−" : " ")
                                    Text(line.text)
                                }
                                .padding(.horizontal, 8)
                                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                                .background(line.kind == .added ? Theme.approve.opacity(0.12) : line.kind == .removed ? Theme.danger.opacity(0.12) : .clear)
                            }
                        }
                    }
                    .font(.caption2.monospaced())
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemGroupedBackground)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(.separator).opacity(0.4)))
    }
}

// MARK: - Timeline

struct TimelineSection: View {
    let task: Wire.Task

    private enum Item: Identifiable {
        case event(Wire.TaskEvent), comment(Wire.Comment), change(Wire.ChangeRequest)
        var at: UInt64 { switch self { case .event(let e): e.at; case .comment(let c): c.at; case .change(let c): c.at } }
        var id: String {
            switch self {
            case .event(let e): "e\(e.at)\(e.text)"
            case .comment(let c): "c\(c.id)"
            case .change(let c): "r\(c.id)"
            }
        }
    }

    var body: some View {
        let items = (task.events.map(Item.event) + task.comments.map(Item.comment) + task.changes.map(Item.change)).sorted { $0.at > $1.at }
        if items.isEmpty { ContentUnavailableView("Nothing yet", systemImage: "clock") }
        ForEach(items) { item in
            HStack(alignment: .top, spacing: 10) {
                switch item {
                case .event(let event):
                    Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.secondary).frame(width: 22).padding(.top, 6)
                    Text("**\(event.who)** \(event.text)").font(.callout)
                case .comment(let comment):
                    Avatar(login: comment.author, size: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(comment.author).font(.caption.weight(.semibold))
                        Text(LocalizedStringKey(comment.text)).font(.callout)
                    }
                case .change(let change):
                    Image(systemName: "arrow.uturn.right").foregroundStyle(Theme.warning).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(change.author) asked for changes · \(change.status.rawValue)").font(.caption.weight(.semibold))
                        Text(change.text).font(.callout)
                    }
                }
                Spacer()
                Text(When.ago(item.at)).font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Actions

struct Compose: Identifiable {
    let title: String
    let placeholder: String
    let send: String
    /// The text may be left empty (an attestation's note).
    var optional = false
    let action: (String) -> Void
    var id: String { title }
}

struct ActionBar: View {
    @Environment(FactoryStore.self) private var store
    let task: Wire.Task
    @Binding var compose: Compose?

    var body: some View {
        let me = store.me
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if task.state == .awaitingApproval, !task.approvals.contains(me) {
                    action("Approve plan", "checkmark", prominent: true) { store.approvePlan(task.id) }
                    action("Request changes", "arrow.uturn.left") {
                        compose = Compose(title: "Request changes to the plan", placeholder: "What should the planner change?", send: "Send") { store.steer(task.id, text: $0) }
                    }
                }
                if task.question != nil {
                    action("Answer", "bubble.left", prominent: task.state != .awaitingApproval) {
                        compose = Compose(title: "Answer the agent", placeholder: task.question?.text ?? "", send: "Answer") { store.answer(task.id, text: $0) }
                    }
                }
                if task.hand != nil {
                    action("Reply to hand", "hand.raised") {
                        compose = Compose(title: "Help the agent", placeholder: task.hand?.summary ?? "", send: "Send") { store.resolveHand(task.id, option: nil, note: $0) }
                    }
                }
                if task.state == .reviewing {
                    let approved = task.reviews.count >= task.reviewsNeeded
                    if !task.reviews.contains(me) {
                        action("Approve changes", "checkmark.seal", prominent: true) { store.approveChanges(task.id) }
                    }
                    if task.mergeAt != nil {
                        action("Hold merge", "pause.circle") { store.holdMerge(task.id) }
                    }
                    if approved {
                        action("Merge", "arrow.triangle.merge", prominent: task.reviews.contains(me)) { store.merge(task.id) }
                    }
                    action("Request changes", "arrow.uturn.left") {
                        compose = Compose(title: "Request changes", placeholder: "What should the builder change?", send: "Request") { store.steer(task.id, text: $0) }
                    }
                }
                if task.state == .building || task.state == .planning {
                    action("Steer", "arrow.triangle.turn.up.right.diamond") {
                        compose = Compose(title: "Steer the agent", placeholder: "Redirect the \(task.state == .planning ? "planner" : "builder")…", send: "Send") { store.steer(task.id, text: $0) }
                    }
                }
                if task.pr?.checks.contains(where: { $0.status == .failed }) ?? false || task.hand?.reason == .sessionEnded {
                    action("Retry", "arrow.clockwise") { store.retryTask(task.id) }
                }
                action("Comment", "text.bubble") {
                    compose = Compose(title: "Comment on \(task.id)", placeholder: "Write a comment; @mention people", send: "Comment") { store.comment(task.id, text: $0) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    @ViewBuilder
    private func action(_ title: String, _ icon: String, prominent: Bool = false, _ perform: @escaping () -> Void) -> some View {
        if prominent {
            Button(action: perform) { Label(title, systemImage: icon).font(.subheadline.weight(.semibold)) }
                .buttonStyle(.borderedProminent)
                .tint(Theme.approve)
        } else {
            Button(action: perform) { Label(title, systemImage: icon).font(.subheadline) }
                .buttonStyle(.bordered)
        }
    }
}

struct ComposeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let compose: Compose
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            TextField(compose.placeholder, text: $text, axis: .vertical)
                .lineLimit(5...12)
                .focused($focused)
                .padding()
                .frame(maxHeight: .infinity, alignment: .top)
                .navigationTitle(compose.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(compose.send) {
                            compose.action(text.trimmingCharacters(in: .whitespacesAndNewlines))
                            dismiss()
                        }
                        .disabled(!compose.optional && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }
}

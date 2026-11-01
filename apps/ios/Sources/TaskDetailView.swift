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
        } else if store.feed.fetching.contains(id) {
            // One the snapshot left out (finished over 14 days ago): on its way.
            ProgressView().navigationTitle(id).navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("Task not found", systemImage: "questionmark.square.dashed")
                .task(id: id) { store.fetchTask(id) }
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
        if !task.stages.isEmpty { TimeCard(task: task) }
        if !task.brief.isEmpty {
            Card("Brief", icon: "doc.text") {
                let brief = BriefContent.parse(task.brief)
                Text(LocalizedStringKey(brief.text)).font(.callout)
                    // The brief as written (links and all), for the UI tests.
                    .accessibilityIdentifier("task.brief").accessibilityValue(task.brief)
                if !brief.attachments.isEmpty { AttachmentGallery(attachments: brief.attachments) }
            }
        }
        if let effort = task.effort, !effort.isEmpty { EffortCard(task: task, effort: effort) }
        if !task.plan.isEmpty { PlanCard(task: task) }
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

/// How long the task has taken (MF-302): total, worked and waiting, a bar of its stages, and a row per stage.
struct TimeCard: View {
    let task: Wire.Task

    var body: some View {
        let finished = task.state == .merged || task.state == .cancelled || task.state == .closed
        TimelineView(.periodic(from: .now, by: finished ? 3600 : 15)) { context in
            let times = TaskTimes(task: task, now: context.date)
            Card("Time", icon: "clock", accessory: times.estimated ? AnyView(Text("estimated").font(.caption).foregroundStyle(.secondary)) : nil) {
                HStack(spacing: 18) {
                    headline("Total", times.total)
                    headline("Working", times.working)
                    headline("Waiting", times.waiting)
                }
                bar(times)
                ForEach(times.stages) { stage in
                    HStack(spacing: 8) {
                        Circle().fill(Theme.state(stage.stage)).frame(width: 8, height: 8)
                        Text(stage.stage.title)
                        if stage.open { Text("now").font(.caption2.weight(.semibold)).foregroundStyle(Theme.state(stage.stage)) }
                        Spacer(minLength: 8)
                        Text(Self.detail(stage)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.subheadline)
                }
            }
            .accessibilityIdentifier("task.time")
        }
    }

    private func headline(_ label: String, _ ms: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(TaskTimes.format(ms)).font(.title3.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func bar(_ times: TaskTimes) -> some View {
        let total = max(1, times.stages.reduce(0) { $0 + $1.total })
        return GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(times.stages) { stage in
                    let width = geo.size.width * CGFloat(stage.total) / CGFloat(total)
                    let waitShare = stage.total == 0 ? 0 : CGFloat(stage.waiting) / CGFloat(stage.total)
                    Rectangle().fill(Theme.state(stage.stage)).frame(width: width * (1 - waitShare))
                    Rectangle().fill(Theme.state(stage.stage).opacity(0.3)).frame(width: width * waitShare)
                }
            }
        }
        .frame(height: 8)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    /// "1h 40m · 22m queued · 10m on a hand".
    static func detail(_ stage: TaskTimes.Stage) -> String {
        var parts = [TaskTimes.format(stage.total)]
        if stage.queued > 0 { parts.append("\(TaskTimes.format(stage.queued)) queued") }
        if stage.hand > 0 { parts.append("\(TaskTimes.format(stage.hand)) on a hand") }
        if stage.question > 0 { parts.append("\(TaskTimes.format(stage.question)) on a question") }
        return parts.joined(separator: " · ")
    }
}

struct Card<Content: View>: View {
    let title: String
    let icon: String
    /// Shown at the header's trailing edge, e.g. a Select toggle.
    var accessory: AnyView?
    @ViewBuilder let content: Content

    init(_ title: String, icon: String, accessory: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.accessory = accessory
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: icon).font(.headline)
                if let accessory { Spacer(); accessory }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color(.separator).opacity(0.4)))
    }
}

extension Wire.Task {
    /// Whether the plan's step changes (`added`/`from`, against the version before) are news:
    /// only while a revised plan (v2+) waits on approval. After that they're history.
    var planChangesFresh: Bool {
        planVersion > 1 && state == .awaitingApproval && plan.contains { $0.added || $0.from != nil }
    }
}

/// The plan's steps, with a revision's changes marked up while it awaits approval, and a toggle for them otherwise.
struct PlanCard: View {
    let task: Wire.Task
    /// The reader's own Show/Hide choice; nil follows `planChangesFresh`. Reset when the plan or stage moves on.
    @State private var showChangesOverride: Bool?

    private var hasChanges: Bool { task.plan.contains { $0.added || $0.from != nil } }
    private var showChanges: Bool { showChangesOverride ?? task.planChangesFresh }

    var body: some View {
        Card("Plan v\(task.planVersion)", icon: "list.number", accessory: hasChanges ? AnyView(toggle) : nil) {
            if let summary = task.planSummary { Text(summary).font(.callout).foregroundStyle(.secondary) }
            ForEach(Array(task.plan.enumerated()), id: \.offset) { index, step in
                PlanStepRow(number: index + 1, step: step, showChanges: showChanges)
            }
            if task.approvalsNeeded > 0 {
                Label("\(task.approvals.count) of \(task.approvalsNeeded) approvals\(task.approvals.isEmpty ? "" : ": " + task.approvals.joined(separator: ", "))", systemImage: "checkmark.seal")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .onChange(of: task.planVersion) { showChangesOverride = nil }
        .onChange(of: task.state) { showChangesOverride = nil }
    }

    private var toggle: some View {
        Button(showChanges ? "Hide changes" : "Show changes from v\(task.planVersion - 1)") {
            withAnimation(.snappy(duration: 0.2)) { showChangesOverride = !showChanges }
        }
        .font(.footnote)
    }
}

struct PlanStepRow: View {
    let number: Int
    let step: Wire.PlanStep
    /// Marks what changed from the previous plan version.
    var showChanges = true

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
                if showChanges, let from = step.from { Text("Was: \(from)").font(.caption).strikethrough().foregroundStyle(.tertiary) }
                if showChanges, step.added { Text("New in this version").font(.caption2.weight(.semibold)).foregroundStyle(Theme.approve) }
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
    @Environment(FactoryStore.self) private var store
    let task: Wire.Task

    /// Picking findings to turn into follow-up tasks.
    @State private var selecting = false
    @State private var picked: Set<String> = []
    @State private var followUps: FollowUpBatch?
    /// The CI check whose log sheet is open.
    @State private var checkLogShown: CheckLogRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) { sections }
            .sheet(item: $followUps) { batch in
                FollowUpSheet(task: task, drafts: batch.drafts) {
                    selecting = false
                    picked = []
                }
            }
            .sheet(item: $checkLogShown) { CheckLogSheet(request: $0) }
    }

    /// Opens the log sheet on one of the pull request's checks and reads its log.
    private func showLog(_ check: Wire.CICheck) {
        store.loadCheckLog(task: task.id, check: check.name)
        checkLogShown = CheckLogRequest(task: task.id, check: check.name)
    }

    private var selectToggle: some View {
        Button(selecting ? "Done" : "Select") {
            selecting.toggle()
            if !selecting { picked = [] }
        }
        .font(.subheadline.weight(.medium))
        .accessibilityIdentifier("findings-select")
    }

    private func findingRow(_ finding: Wire.Finding, pickable: Bool, followedBy: String?) -> some View {
        let on = picked.contains(finding.id)
        return HStack(alignment: .top, spacing: 10) {
            if pickable {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(on ? Color.accentColor : .secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(finding.severity.rawValue).font(.caption2.weight(.bold)).foregroundStyle(finding.severity == .blocker ? Theme.danger : Theme.warning)
                    Text(finding.kind.rawValue).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text(finding.status == .fixed ? "Fixed in round \(finding.fixedIn ?? 0)" : finding.status.rawValue).font(.caption2).foregroundStyle(finding.status == .fixed ? Theme.approve : .secondary)
                }
                Text(finding.text).font(.callout).strikethrough(finding.status == .fixed, color: .secondary)
                if let file = finding.file { Text(file).font(.caption.monospaced()).foregroundStyle(.secondary) }
                if let followedBy {
                    Label("Follow-up: \(followedBy)", systemImage: "arrowshape.turn.up.right")
                        .font(.caption.weight(.medium)).foregroundStyle(Theme.state(.drafting))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Follow-up: \(followedBy)")
                        .accessibilityIdentifier("finding-followed-\(finding.id)")
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard pickable else { return }
            if on { picked.remove(finding.id) } else if picked.count < FactoryStore.maxFollowUps { picked.insert(finding.id) }
        }
        .accessibilityElement(children: pickable ? .combine : .contain)
        .accessibilityAddTraits(pickable ? [.isButton] : [])
        .accessibilityAddTraits(on ? [.isSelected] : [])
        .accessibilityIdentifier(pickable ? "finding-pick-\(finding.id)" : "finding-\(finding.id)")
    }

    @ViewBuilder private var sections: some View {
        let block = FactoryStore.followUpBlock(task, feed: store.feed)
        let followable = Set(FactoryStore.followableFindings(task, feed: store.feed).map(\.id))
        let followed = FactoryStore.followedUp(store.feed)
        if let review = task.autoReview {
            Card("Automatic review", icon: "sparkle.magnifyingglass") {
                if let round = review.rounds.last {
                    Label("Round \(round.number) of \(review.maxRounds): \(round.verdict == .inProgress ? "reviewing…" : round.verdict.rawValue)",
                          systemImage: round.verdict == .passed ? "checkmark.seal.fill" : "arrow.triangle.2.circlepath")
                        .foregroundStyle(round.verdict == .passed ? Theme.approve : Theme.warning)
                        .font(.subheadline.weight(.medium))
                        .accessibilityIdentifier("review-round")
                    if let focus = round.focus {
                        Label("\(round.by ?? "Someone") asked it to look at: \(focus)", systemImage: "eye")
                            .font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("review-round-focus")
                    }
                }
                Text(review.summary).font(.callout)
                ForEach(review.ask + review.proofs, id: \.text) { check in
                    Label(check.text, systemImage: check.verdict == .met ? "checkmark" : "exclamationmark")
                        .font(.footnote).foregroundStyle(check.verdict == .met ? Theme.approve : Theme.warning)
                }
            }
            if !review.findings.isEmpty {
                let canSelect = block == nil && !followable.isEmpty
                Card("Findings", icon: "ladybug", accessory: canSelect ? AnyView(selectToggle) : nil) {
                    ForEach(review.findings, id: \.id) { finding in
                        findingRow(finding, pickable: selecting && followable.contains(finding.id), followedBy: followed["\(task.id)#\(finding.id)"])
                        Divider()
                    }
                    if selecting && canSelect {
                        Button {
                            let drafts = review.findings.filter { picked.contains($0.id) }.map(FollowUpDraft.init(finding:))
                            followUps = FollowUpBatch(drafts: drafts)
                        } label: {
                            Label("Make \(picked.count) follow-up task\(picked.count == 1 ? "" : "s")", systemImage: "arrowshape.turn.up.right")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(picked.isEmpty)
                        .accessibilityIdentifier("make-follow-ups")
                    }
                }
                .onChange(of: followable) { picked.formIntersection(followable) }
            }
        } else {
            ContentUnavailableView("No review yet", systemImage: "eye", description: Text("The review agent reads the change once it's pushed."))
        }
        if block == nil {
            Button {
                followUps = FollowUpBatch(drafts: [FollowUpDraft(finding: nil)])
            } label: {
                Label("Follow-up from a note…", systemImage: "square.and.pencil").font(.subheadline)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("follow-up-note")
        }
        if let pr = task.pr {
            Card("Pull request #\(pr.number)", icon: "arrow.triangle.pull") {
                Text("\(pr.branch) → \(pr.base) · \(pr.state.rawValue)").font(.footnote.monospaced()).foregroundStyle(.secondary)
                ForEach(pr.checks, id: \.name) { check in
                    Button {
                        showLog(check)
                    } label: {
                        HStack {
                            CheckLogSheet.icon(check.status)
                            Text(check.name).foregroundStyle(.primary)
                            Spacer()
                            Text(check.duration ?? "").font(.caption).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .font(.callout)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(check.status == .queued || pr.url == nil)
                    .accessibilityIdentifier("check-\(check.name)")
                    .accessibilityValue(check.status.rawValue)
                    .contextMenu {
                        Button("View log", systemImage: "text.alignleft") { showLog(check) }
                            .disabled(check.status == .queued || pr.url == nil)
                        Button("Re-run", systemImage: "arrow.clockwise") { store.rerunCheck(task.id, check: check.name) }
                            .disabled(!FactoryStore.canRerun(check, pr: pr))
                        if let url = FactoryStore.githubURL(check, pr: pr) {
                            Divider()
                            Link(destination: url) { Label("Open on GitHub", systemImage: "arrow.up.right.square") }
                        }
                    }
                }
                if pr.checks.contains(where: { $0.status == .failed }), pr.state == .open || pr.state == .draft, pr.url != nil {
                    Button {
                        store.rerunFailedChecks(task.id)
                    } label: {
                        Label("Rerun failed checks", systemImage: "arrow.clockwise").font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("rerun-failed-checks")
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
    @State private var compose: Compose?

    private var key: String { "\(task.pr?.head ?? "")-\(task.diff?.added ?? 0)-\(task.diff?.removed ?? 0)" }
    /// Notes go to the builder, so only while the task's still open.
    private var reviewable: Bool { task.state != .merged && task.state != .cancelled }

    var body: some View {
        Group {
            if let notes = store.reviewNotes[task.id], !notes.isEmpty { ReviewBar(task: task, notes: notes) }
            if let files = store.diffs[task.id]?.files {
                if files.isEmpty {
                    ContentUnavailableView("No changes yet", systemImage: "doc.text.magnifyingglass")
                }
                ForEach(files) { file in
                    DiffFileView(file: file, noted: noted(file.path), onNote: reviewable ? { line in note(file.path, line) } : nil)
                }
            } else if task.diff == nil && task.pr == nil {
                ContentUnavailableView("No changes yet", systemImage: "doc.text.magnifyingglass", description: Text("The diff appears once the builder starts writing."))
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .task(id: key) { await store.loadDiff(task: task.id, key: key) }
        .sheet(item: $compose) { ComposeSheet(compose: $0) }
    }

    /// The lines of `path` with a pending note, as `<side><n>`.
    private func noted(_ path: String) -> Set<String> {
        Set((store.reviewNotes[task.id] ?? []).filter { $0.path == path }.map { "\($0.side.rawValue)\($0.start)" })
    }

    private func note(_ path: String, _ line: DiffLine) {
        guard let number = line.kind == .removed ? line.old : line.new else { return }
        compose = Compose(title: "Note on \(path):\(number)", placeholder: "What should the builder change here?", send: "Add") { [store, task] in
            store.addReviewNote(task: task.id, path: path, line: line, text: $0)
        }
    }
}

/// The draft review: how many notes are pending, each one (✕ to drop it), and Submit review.
struct ReviewBar: View {
    @Environment(FactoryStore.self) private var store
    let task: Wire.Task
    let notes: [Wire.ReviewNote]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { withAnimation { expanded.toggle() } } label: {
                    Label("\(notes.count) pending note\(notes.count == 1 ? "" : "s")", systemImage: expanded ? "chevron.down" : "chevron.right")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("pending-notes")
                Spacer()
                Button("Submit review") { store.submitReview(task.id) }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.approve)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("submit-review")
            }
            if expanded {
                ForEach(Array(notes.enumerated()), id: \.offset) { index, note in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(FactoryStore.anchor(note)).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text(note.text).font(.callout)
                        }
                        Spacer()
                        Button { withAnimation { store.removeReviewNote(task: task.id, at: index) } } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove note")
                        .accessibilityIdentifier("remove-note-\(index)")
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemGroupedBackground)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.approve.opacity(0.5)))
    }
}

struct DiffFileView: View {
    let file: DiffFile
    /// Lines with a pending note, as `<side><n>`.
    var noted: Set<String> = []
    /// Long-press → Add note on a line; nil when the task can't take notes.
    var onNote: ((DiffLine) -> Void)?
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
                            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in row(line) }
                        }
                    }
                    .font(.caption2.monospaced())
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemGroupedBackground)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(.separator).opacity(0.4)))
    }

    /// `old12` for a removed line, `new12` for any other: the side a note on it is numbered on.
    private func place(_ line: DiffLine) -> String {
        line.kind == .removed ? "old\(line.old ?? 0)" : "new\(line.new ?? 0)"
    }

    @ViewBuilder
    private func row(_ line: DiffLine) -> some View {
        let content = HStack(spacing: 6) {
            Text(line.new.map(String.init) ?? line.old.map(String.init) ?? "").foregroundStyle(.tertiary).frame(width: 30, alignment: .trailing)
            Text(line.kind == .added ? "+" : line.kind == .removed ? "−" : " ")
            Text(line.text)
            if noted.contains(place(line)) {
                Image(systemName: "text.bubble.fill").foregroundStyle(Theme.approve).accessibilityIdentifier("note-marker-\(file.path)-\(place(line))")
            }
        }
        .padding(.horizontal, 8)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background(line.kind == .added ? Theme.approve.opacity(0.12) : line.kind == .removed ? Theme.danger.opacity(0.12) : .clear)
        .contentShape(Rectangle())
        if let onNote {
            content
                .contextMenu { Button("Add note", systemImage: "text.bubble") { onNote(line) } }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("diff-line-\(file.path)-\(place(line))")
        } else {
            content
        }
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
                        NoteWithAttachments(source: comment.text, compact: true)
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
                    // Another automated-review round with your focus, once the last one is in (the Mac's ReviewActions).
                    if task.autoReview?.rounds.isEmpty == false {
                        let running = task.autoReview?.rounds.last?.verdict == .inProgress
                        action(running ? "Reviewing…" : "Request review…", "eye", enabled: FactoryStore.canRequestReview(task, feed: store.feed)) {
                            compose = Compose(title: "Request a review of \(task.id)", placeholder: "What should it look for? e.g. check security", send: "Send") { [store, task] in
                                store.requestReview(task.id, focus: $0)
                            }
                        }
                        .accessibilityIdentifier("request-review")
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
        .accessibilityIdentifier("action-bar")
        .background(.bar)
    }

    @ViewBuilder
    private func action(_ title: String, _ icon: String, prominent: Bool = false, enabled: Bool = true, _ perform: @escaping () -> Void) -> some View {
        if prominent {
            Button(action: perform) { Label(title, systemImage: icon).font(.subheadline.weight(.semibold)) }
                .buttonStyle(.borderedProminent)
                .tint(Theme.approve)
                .disabled(!enabled)
        } else {
            Button(action: perform) { Label(title, systemImage: icon).font(.subheadline) }
                .buttonStyle(.bordered)
                .disabled(!enabled)
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

// MARK: - Follow-ups

/// One draft task to make from a finding, or from a note when `finding` is nil.
struct FollowUpDraft: Identifiable {
    let id = UUID()
    let finding: Wire.Finding?
    var title: String
    var note = ""

    /// Its title starts as the finding's first line, at most 120 characters (the server's cap).
    init(finding: Wire.Finding?) {
        self.finding = finding
        let line = finding?.text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        title = String(line.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
    }

    /// A note-only follow-up needs a brief as well as a title, as the server requires.
    var isReady: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (finding != nil || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var item: Wire.FollowUpItem {
        .init(finding: finding?.id, title: title.trimmingCharacters(in: .whitespacesAndNewlines), brief: note.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

struct FollowUpBatch: Identifiable {
    let id = UUID()
    let drafts: [FollowUpDraft]
}

/// Edit each follow-up's title and note, then Make sends them as one `task.followUp`. A refusal, or the
/// toast saying where they went, shows in the notice banner.
struct FollowUpSheet: View {
    @Environment(FactoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let task: Wire.Task
    @State var drafts: [FollowUpDraft]
    let onSent: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                ForEach(Array($drafts.enumerated()), id: \.element.id) { index, $draft in
                    Section {
                        TextField("Title", text: $draft.title, axis: .vertical)
                            .lineLimit(1...3)
                            .accessibilityIdentifier("follow-up-title-\(index)")
                        TextField(draft.finding == nil ? "What should it do?" : "Note (optional)", text: $draft.note, axis: .vertical)
                            .lineLimit(2...6)
                            .accessibilityIdentifier("follow-up-brief-\(index)")
                    } header: {
                        if let finding = draft.finding {
                            Text("\(finding.severity.rawValue) \(finding.kind.rawValue) · \(finding.id)")
                        } else {
                            Text("From a note")
                        }
                    } footer: {
                        if let finding = draft.finding { Text(finding.text).lineLimit(3) }
                    }
                }
                Section {
                    Text("They're made as drafts in \(store.feed.goal(task.goal)?.name ?? "the goal"), linked back to \(task.id).")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(drafts.count == 1 ? "Follow-up of \(task.id)" : "\(drafts.count) follow-ups of \(task.id)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Make") {
                        store.followUp(task.id, items: drafts.map(\.item))
                        onSent()
                        dismiss()
                    }
                    .disabled(drafts.isEmpty || !drafts.allSatisfy(\.isReady))
                }
            }
        }
    }
}

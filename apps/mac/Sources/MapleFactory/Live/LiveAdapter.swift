import SwiftUI

/// Turns the factory's tasks and goals (as the server sends them) into the models the views were
/// designed around, so a signed-in app shows real work in the same board, list and task screens.
@MainActor enum LiveAdapter {
    static let palette: [Color] = [
        Color(light: 0xD9488F, dark: 0xF07AB4), Color(light: 0xE0662F, dark: 0xFF8A5B), Color(light: 0x2F80ED, dark: 0x5EA2FF),
        Color(light: 0x1F9D6B, dark: 0x3CCB8F), Color(light: 0x8B5CF6, dark: 0xA98BFF), Color(light: 0xC2410C, dark: 0xF59E0B),
    ]

    static func color(for login: String) -> Color {
        palette[Int(login.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value } % UInt32(palette.count))]
    }

    static func person(_ login: String, members: [Wire.Member]) -> Person {
        switch login {
        case "planner", "builder", "reviewer", "factory":
            return role(login)
        default:
            let member = members.first { $0.login == login }
            return Person(name: member?.name ?? login, color: color(for: login), isHuman: true, github: login)
        }
    }

    static func role(_ name: String) -> Agent {
        switch name {
        case "planner": Agent(name: "Planner", color: Theme.State.planning)
        case "builder": Agent(name: "Builder", color: Theme.State.building)
        case "reviewer": FactoryData.reviewer
        default: Agent(name: "Factory", color: Theme.textMuted)
        }
    }

    /// "now", "4m", "2h", "3d": how the mockup labels times.
    static func ago(_ ms: UInt64) -> String {
        let seconds = max(0, Date().timeIntervalSince1970 - Double(ms) / 1000)
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86400: return "\(Int(seconds / 3600))h"
        default: return "\(Int(seconds / 86400))d"
        }
    }

    static func day(_ ms: UInt64) -> Int {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        return Calendar.current.dateComponents([.day], from: FactoryData.timelineStart, to: date).day ?? FactoryData.todayOffset
    }

    static func goal(_ goal: Wire.Goal, members: [Wire.Member], following: Bool) -> Goal {
        let due = goal.due.map(day) ?? (FactoryData.todayOffset + 21)
        return Goal(name: goal.name, color: Color(hexString: goal.color) ?? Theme.State.building, dueOffset: due,
                    lead: person(goal.lead, members: members), summary: goal.summary, archived: goal.archived ?? false,
                    prefix: goal.prefix, team: goal.team, following: following)
    }

    static func task(_ t: Wire.Task, goals: [Wire.Goal], members: [Wire.Member], me: String?) -> FactoryTask {
        let who = { (login: String) in person(login, members: members) }
        let goalName = goals.first { $0.id == t.goal }?.name ?? "No goal"
        let done = t.plan.filter { $0.progress == .done }.count
        let start = day(t.createdAt)

        var task = FactoryTask(id: t.id, goal: goalName, title: t.title, state: state(t.state),
                               detail: detail(t), span: start...max(start + 1, day(t.updatedAt) + 1), updated: ago(t.updatedAt))
        task.agent = t.worker.map { role($0.role.rawValue) }
        task.worker = t.worker.map { FactoryTask.Worker(role: $0.role.rawValue, agent: $0.agent, machine: $0.machine, session: $0.session) }
        task.owner = who(t.owner)
        task.machine = t.machine
        task.pushed = t.pr?.head
        task.gitBranch = t.branch
        task.splitFrom = t.splitFrom
        let goal = goals.first { $0.id == t.goal }
        if let goal, goal.repos.count > 1 { task.repo = t.repo ?? goal.repo }
        task.after = t.after
        task.followUps = t.followUps.map { (repo: $0.repo, title: $0.title, task: $0.task) }
        task.brief = t.brief
        task.spec = t.brief
        task.progress = t.state == .building && !t.plan.isEmpty ? max(0.04, Double(done) / Double(t.plan.count)) : nil
        task.diff = t.diff.map { ($0.added.int, $0.removed.int) }
        task.diffKey = t.diff.map { "\(t.pr?.head ?? "")+\($0.added)-\($0.removed)" }
        task.plan = t.plan.map { step in
            PlanStep(text: step.text, file: step.file,
                     change: step.added ? .added : step.from.map { .modified(from: $0) },
                     progress: t.state == .building || t.state == .planning ? step.progress.map(progress) : nil)
        }
        task.planVersion = max(1, t.planVersion.int)
        task.question = t.question?.text
        task.questionOptions = t.question?.options ?? []
        task.activity = t.events.reversed().map { ActivityItem(who: who($0.who).name, text: $0.text, when: ago($0.at)) }
        task.approvals = t.approvals.map(who)
        task.approvalsNeeded = t.approvalsNeeded.int
        task.reviews = t.reviews.map(who)
        task.comments = t.comments.map { Comment(author: who($0.author), text: $0.text, when: ago($0.at), anchor: $0.anchor, via: $0.via) }
        task.changeRequests = t.changes.map { change in
            var request = ChangeRequest(author: who(change.author), text: change.text, anchor: change.anchor,
                                        status: changeStatus(change.status), when: ago(change.at))
            request.timing = change.timing
            return request
        }
        task.doneWhen = t.doneWhen.map { item in
            DoneCriterion(text: item.text, proof: proofKind(item.proof), status: proofStatus(item.status), evidence: item.evidence.map(evidence))
        }
        task.liveLog = t.waiting ?? t.liveLog
        task.footprint = t.diff.map { ($0.files.count, ($0.added + $0.removed).int, false) } ?? t.footprint.map { ($0.files.int, $0.lines.int, $0.estimated) }
        task.areas = t.risk?.areas ?? []
        task.plannedRisk = t.risk.map { riskLevel($0.level) } ?? .low
        task.pr = t.pr.map { pr in
            var request = PullRequest(number: pr.number.int, state: prState(pr.state), checks: pr.checks.map(check))
            request.link = pr.url.flatMap(URL.init(string:))
            request.branch = pr.branch
            request.base = pr.base
            // Cancelling closes it; older servers left it marked open.
            if t.state == .cancelled, request.state == .open || request.state == .draft { request.state = .closed }
            return request
        }
        task.autoReview = t.autoReview.map(review)
        // A round still open on a cancelled task never finished (older servers left it behind).
        if t.state == .cancelled, task.autoReview?.rounds.last?.verdict == .inProgress {
            task.autoReview?.rounds.removeLast()
            if task.autoReview?.rounds.isEmpty == true { task.autoReview = nil }
        }
        task.hand = t.hand.map { hand(t, $0, assignee: who($0.assignee)) }
        task.shareable = t.shareable
        task.tickets = t.tickets.map {
            TicketLink(system: $0.system.lowercased() == "jira" ? .jira : .linear, key: $0.key, title: $0.title, status: $0.status, asContext: $0.asContext)
        }
        task.mockups = t.mockups.map(mockup)
        task.intakeID = t.intake
        task.needsYou = needsYou(t, me: me)
        return task
    }

    private static func needsYou(_ t: Wire.Task, me: String?) -> Bool {
        guard let me else { return false }
        if t.hand?.assignee == me || (t.question != nil && t.owner == me) { return true }
        if t.state == .awaitingApproval && !t.approvals.contains(me) { return true }
        if t.state == .reviewing && t.autoReview?.rounds.last?.verdict == .passed && !t.reviews.contains(me) { return true }
        return false
    }

    private static func detail(_ t: Wire.Task) -> String {
        if t.hand != nil { return "Needs a hand" }
        if t.question != nil { return "Asked a question" }
        if let waiting = t.waiting { return waiting }
        switch t.state {
        case .drafting: return "Draft"
        case .planning: return t.worker == nil ? "Waiting for a planner" : "Drafting the plan"
        case .awaitingApproval: return t.approvalsNeeded == 0 ? "Plan v\(t.planVersion) ready" : "Plan v\(t.planVersion) · \(t.approvals.count) of \(t.approvalsNeeded) approvals"
        case .building:
            let done = t.plan.filter { $0.progress == .done }.count
            return t.worker == nil ? "Queued" : "Step \(min(done + 1, max(t.plan.count, 1))) of \(max(t.plan.count, 1))"
        case .reviewing:
            guard let round = t.autoReview?.rounds.last else { return "In review" }
            switch round.verdict {
            case .inProgress: return "Review round \(round.number)"
            case .passed: return t.reviewsNeeded == 0 ? "Ready to merge" : "\(t.reviews.count) of \(t.reviewsNeeded) reviews"
            case .changesRequested: return "Changes requested"
            case .escalated: return "Escalated"
            }
        case .merged: return t.pr.map { "#\($0.number) merged" } ?? "Merged"
        case .cancelled: return "Cancelled"
        }
    }

    static func state(_ s: Wire.TaskState) -> TaskState {
        switch s {
        case .drafting: .drafting
        case .planning: .planning
        case .awaitingApproval: .awaitingApproval
        case .building: .building
        case .reviewing: .reviewing
        case .merged: .merged
        case .cancelled: .cancelled
        }
    }

    static func request(_ r: Wire.IntakeRequest, goals: [Wire.Goal], members: [Wire.Member]) -> IntakeRequest {
        let source: IntakeSource = switch r.source {
        case "slack": .slack(channel: r.channel ?? "")
        case "linear": .linear
        case "jira": .jira
        default: .api
        }
        let who = { (name: String) in
            members.contains { $0.login == name } ? person(name, members: members) : Person(name: name, color: color(for: name), isHuman: true)
        }
        let status: IntakeRequest.Status = switch r.status {
        case "clarifying": .clarifying
        case "accepted": .accepted(taskID: r.taskId ?? "")
        case "declined": .declined
        default: .new
        }
        return IntakeRequest(
            id: r.id, source: source, requester: who(r.requester), title: r.title, when: ago(r.at),
            thread: r.thread.map { m in
                ThreadMessage(author: m.bot ? FactoryData.bot : who(m.author), text: m.text, when: ago(m.at), isBot: m.bot, relayedFrom: m.relayedFrom)
            },
            tickets: r.tickets.map { TicketLink(system: $0.system.lowercased() == "jira" ? .jira : .linear, key: $0.key, title: $0.title, status: $0.status, asContext: $0.asContext) },
            status: status,
            suggestedGoal: goals.first { $0.id == r.suggestedGoal }?.name ?? goals.first?.name ?? "",
            relatedTask: r.relatedTask,
            gaps: r.gaps
        )
    }

    static func note(_ n: Wire.Note) -> Note {
        Note(id: UUID(uuidString: n.id) ?? UUID(), title: n.title, body: n.body, updated: ago(n.updatedAt), taskID: n.taskId)
    }

    static func wire(_ n: Note, owner: String) -> Wire.Note {
        Wire.Note(id: n.id.uuidString.lowercased(), owner: owner, title: n.title, body: n.body, updatedAt: 0, taskId: n.taskID)
    }

    static func riskLevel(_ level: Wire.RiskLevel) -> RiskLevel {
        switch level {
        case .low: .low
        case .medium: .medium
        case .high: .high
        }
    }

    static func wireLevel(_ level: RiskLevel) -> Wire.RiskLevel {
        switch level {
        case .low: .low
        case .medium: .medium
        case .high: .high
        }
    }

    static func policy(_ p: Wire.RiskPolicy) -> RiskPolicy {
        var policy = RiskPolicy()
        policy.maxFiles = Int(p.maxFiles)
        policy.maxLines = Int(p.maxLines)
        policy.sensitiveAreas = p.areas.map { SensitiveArea(name: $0.name, paths: $0.paths, level: riskLevel($0.level), enabled: $0.enabled) }
        for level in RiskLevel.allCases {
            let key = wireLevel(level).rawValue
            policy.planApprovals[level] = p.planApprovals[key].map(Int.init) ?? policy.planApprovals[level]
            policy.finalReviews[level] = p.finalReviews[key].map(Int.init) ?? policy.finalReviews[level]
            policy.autoMerge[level] = p.autoMerge[key] ?? policy.autoMerge[level]
        }
        return policy
    }

    static func wire(_ policy: RiskPolicy) -> Wire.RiskPolicy {
        let keyed = { (values: [RiskLevel: Int]) in Dictionary(uniqueKeysWithValues: values.map { (wireLevel($0.key).rawValue, UInt32($0.value)) }) }
        return Wire.RiskPolicy(
            maxFiles: UInt32(policy.maxFiles), maxLines: UInt32(policy.maxLines),
            areas: policy.sensitiveAreas.map { Wire.SensitiveArea(name: $0.name, paths: $0.paths, level: wireLevel($0.level), enabled: $0.enabled) },
            planApprovals: keyed(policy.planApprovals), finalReviews: keyed(policy.finalReviews),
            autoMerge: Dictionary(uniqueKeysWithValues: policy.autoMerge.map { (wireLevel($0.key).rawValue, $0.value) })
        )
    }

    private static func progress(_ p: Wire.StepProgress) -> PlanStep.Progress {
        switch p {
        case .done: .done
        case .active: .active
        case .pending: .pending
        }
    }

    private static func changeStatus(_ s: Wire.ChangeStatus) -> ChangeRequest.Status {
        switch s {
        case .queued: .queued
        case .applying: .applying
        case .applied: .applied
        }
    }

    private static func proofKind(_ k: Wire.ProofKind) -> DoneCriterion.ProofKind {
        switch k {
        case .screenshot: .screenshot
        case .video: .video
        case .terminal: .terminal
        case .tests: .tests
        }
    }

    private static func proofStatus(_ s: Wire.ProofStatus) -> DoneCriterion.Status {
        switch s {
        case .pending: .pending
        case .proving: .proving
        case .proven: .proven
        case .failed: .failed
        }
    }

    private static func evidence(_ e: Wire.Evidence) -> DoneCriterion.Evidence {
        switch e.kind {
        case .tests: .tests(suite: e.summary, passed: Int(e.passed ?? 0), failed: Int(e.failed ?? 0))
        case .terminal: .terminal(command: e.command ?? e.summary, output: e.output.isEmpty ? [e.summary] : e.output)
        case .screenshot: .screenshot(caption: e.summary)
        case .video: .video(caption: e.summary, duration: "")
        }
    }

    private static func prState(_ s: Wire.PRState) -> PullRequest.State {
        switch s {
        case .draft: .draft
        case .open: .open
        case .closed: .closed
        case .merged: .merged
        }
    }

    private static func check(_ c: Wire.CICheck) -> CICheck {
        let status: CICheck.Status = switch c.status {
        case .queued: .queued
        case .running: .running
        case .passed: .passed
        case .failed: .failed
        }
        return CICheck(name: c.name, status: status, duration: c.duration ?? "", required: c.required)
    }

    private static func review(_ r: Wire.AutoReview) -> AutoReview {
        let verdict = { (v: Wire.CheckVerdict) -> ReviewCheck.Verdict in
            switch v {
            case .met: .met
            case .partial: .partial
            case .missed: .missed
            }
        }
        return AutoReview(
            maxRounds: r.maxRounds.int,
            rounds: r.rounds.map { round in
                let v: ReviewRound.Verdict = switch round.verdict {
                case .changesRequested: .changesRequested
                case .passed: .passed
                case .escalated: .escalated
                case .inProgress: .inProgress
                }
                return ReviewRound(number: round.number.int, verdict: v, found: round.found.int, when: ago(round.at), fix: round.fix)
            },
            summary: r.summary,
            ask: r.ask.map { ReviewCheck(text: $0.text, verdict: verdict($0.verdict), note: $0.note) },
            proofs: r.proofs.map { ReviewCheck(text: $0.text, verdict: verdict($0.verdict), note: $0.note) },
            findings: r.findings.map { f in
                let kind: ReviewFinding.Kind = switch f.kind {
                case .scope: .scope
                case .proof: .proof
                case .code: .code
                case .risk: .risk
                }
                let severity: ReviewFinding.Severity = switch f.severity {
                case .blocker: .blocker
                case .major: .major
                case .minor: .minor
                }
                let status: ReviewFinding.Status = switch f.status {
                case .open: .open
                case .fixed: .fixed(round: Int(f.fixedIn ?? f.raisedIn))
                case .disputed: .disputed
                }
                return ReviewFinding(kind: kind, severity: severity, text: f.text, file: f.file, raisedIn: f.raisedIn.int, status: status)
            }
        )
    }

    private static func hand(_ t: Wire.Task, _ h: Wire.Hand, assignee: Person) -> HandRaise {
        let reason: HandRaise.Reason = switch h.reason {
        case .reviewLoop: .reviewLoop
        case .proofBurden: .proofBurden
        case .needsInput: .needsInput
        case .overBudget: .overBudget
        case .sessionEnded: .sessionEnded
        }
        return HandRaise(reason: reason, since: ago(h.at), assignee: assignee, headline: reason.title, explanation: h.summary, tried: [],
                         options: h.options.map { HandRaise.Option(title: $0.title, detail: $0.detail, recommended: $0.recommended) })
    }

    private static func mockup(_ m: Wire.Mockup) -> Mockup {
        let status: Mockup.Status = switch m.status {
        case .proposed: .proposed
        case .approved: .approved
        case .changesRequested: .changesRequested
        }
        let kind: Mockup.Kind
        if m.kind == "terminal" {
            kind = .terminal(m.lines.map { line in
                let style: TermMockLine.Style = switch line.style {
                case "command": .command
                case "highlight": .highlight
                case "dim": .dim
                case "error": .error
                default: .output
                }
                return TermMockLine(text: line.text, style: style, callout: line.callout.map(Int.init))
            })
        } else {
            kind = .html(m.html ?? "", url: m.url ?? "")
        }
        return Mockup(id: m.id, title: m.title, kind: kind, notes: m.notes, status: status, version: m.version.int,
                      match: m.visualMatch, differences: m.differences)
    }
}

private extension UInt32 {
    var int: Int { Int(self) }
}

extension Color {
    /// "#RRGGBB" (or without the #).
    init?(hexString: String) {
        let hex = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(hex: value)
    }
}

extension TicketLink {
    var wire: Wire.TicketLink {
        Wire.TicketLink(system: system.rawValue, key: key, title: title, status: status, url: nil, asContext: asContext)
    }
}

/// Lays its children out in rows, wrapping when the next one doesn't fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map { $0.map { $0.size.height }.max() ?? 0 }.reduce(0) { $0 + $1 } + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map { row in row.map(\.size.width).reduce(0, +) + spacing * CGFloat(max(row.count - 1, 0)) }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            let height = row.map(\.size.height).max() ?? 0
            for item in row {
                item.view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += height + spacing
        }
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [[(view: LayoutSubview, size: CGSize)]] {
        var rows: [[(view: LayoutSubview, size: CGSize)]] = [[]]
        var x: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, !(rows.last?.isEmpty ?? true) {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append((view, size))
            x += size.width + spacing
        }
        return rows
    }
}

extension LiveAdapter {
    /// One card per plan account the machines report, newest reading first: machines signed in to
    /// the same account share its limits.
    /// `tasks` gives each account the factory sessions running on its machines with its agent.
    static func usageAccounts(machines: [Wire.Machine], members: [Wire.Member], tasks: [FactoryTask] = []) -> [UsageAccount] {
        var byAccount: [String: (reading: Wire.AgentUsage, machine: Wire.Machine, machines: [Wire.Machine])] = [:]
        for machine in machines {
            for reading in machine.usage {
                let key = "\(reading.agent)-\(reading.account?.id ?? machine.id)"
                if let seen = byAccount[key] {
                    let newer = reading.observedAt > seen.reading.observedAt
                    byAccount[key] = (newer ? reading : seen.reading, newer ? machine : seen.machine, seen.machines + [machine])
                } else {
                    byAccount[key] = (reading, machine, [machine])
                }
            }
        }
        return byAccount.map { key, entry in
            let r = entry.reading
            let ids = Set(entry.machines.map(\.id))
            let routed = tasks.compactMap { task -> Agent? in
                guard let w = task.worker, ids.contains(w.machine), w.agent == r.agent else { return nil }
                return Agent(name: "\(task.id) \(w.role)", color: role(w.role).color)
            }
            return UsageAccount(
                id: key,
                product: r.agent == "codex" ? .codex : .claudeCode,
                plan: r.plan ?? "plan",
                owner: person(entry.machine.owner, members: members),
                accountName: r.account?.name,
                machines: entry.machines.map(\.name),
                windows: r.windows.map(window),
                agents: routed,
                updated: ago(r.observedAt),
                updatedFrom: entry.machine.name,
                source: r.source == "statusline" ? "From the status line of Claude Code sessions." : "From Codex's own usage reports.",
                freeResets: r.resetCredits.map(Int.init)
            )
        }
        .sorted { ($0.product == .claudeCode ? 0 : 1, $0.id) < ($1.product == .claudeCode ? 0 : 1, $1.id) }
    }

    static func window(_ w: Wire.UsageReading) -> UsageWindow {
        let now = Date()
        let resets = w.resetsAt.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        let minutes = Double(w.windowMinutes ?? (w.label == "5h" ? 300 : w.label == "7d" ? 10080 : 0))
        let left = resets.map { max(0, $0.timeIntervalSince(now)) } ?? 0
        let elapsed = minutes > 0 ? min(1, max(0, 1 - left / (minutes * 60))) : 0
        let label = switch w.label {
        case "5h": "Current session"
        case "7d": w.name.map { "This week · \($0)" } ?? "This week"
        case "spend": "Spend"
        default: w.label
        }
        let resetsIn: String = {
            let h = Int(left) / 3600, m = Int(left) % 3600 / 60
            return h >= 24 ? "\(h / 24)d \(h % 24)h" : h > 0 ? "\(h)h \(m)m" : "\(m)m"
        }()
        let resetsAt = resets.map {
            Calendar.current.isDateInToday($0) ? $0.formatted(date: .omitted, time: .shortened) : $0.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        } ?? ""
        let used = w.usedPercent / 100
        // At this pace, when it runs dry, if before it resets.
        let runsOut: String? = {
            guard elapsed > 0.05, used / elapsed > 1, minutes > 0, let resets else { return nil }
            let dry = now.addingTimeInterval((1 - used) / (used / (elapsed * minutes * 60)))
            return dry < resets ? dry.formatted(date: .omitted, time: .shortened) : nil
        }()
        return UsageWindow(label: label, span: w.label, used: used, resetsIn: resetsIn, resetsAt: resetsAt, elapsed: elapsed, runsOutAt: runsOut)
    }
}

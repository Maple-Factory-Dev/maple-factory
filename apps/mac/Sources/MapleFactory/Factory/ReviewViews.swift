import SwiftUI

// MARK: Automated review

/// The review agent's read on the finished change: verdict, which round it's on, did it do the ask,
/// are the proofs real, and what it flagged along the way.
struct AutoReviewSection: View {
    let task: FactoryTask
    let review: AutoReview
    @State private var showResolved = false

    var body: some View {
        TaskSection(title: "Automated review") {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(16)

                Hairline()

                Text(review.summary)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.text.opacity(0.9))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(16)

                Hairline()

                HStack(alignment: .top, spacing: 0) {
                    checkColumn("Did it do the ask?", checks: review.ask)
                    Hairline(vertical: true)
                    checkColumn("Is it proven?", checks: review.proofs)
                }

                if !review.findings.isEmpty {
                    Hairline()
                    findings.padding(16)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.cardBG)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke))
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                AgentAvatar(agent: review.reviewer, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(review.reviewer.name)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        Text("review agent")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textMuted)
                    }
                    Text(roundLine)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                }
                Spacer()
                VerdictPill(verdict: review.current?.verdict ?? .inProgress)
            }
            RoundTrack(review: review)
        }
    }

    private var roundLine: String {
        guard let current = review.current else { return "Not started" }
        let when = current.when == "now" ? "reviewing now" : "\(current.when) ago"
        return "Round \(current.number) of \(review.maxRounds) · \(when) · reviews the PR independently of \(task.agent?.name ?? "the builder")"
    }

    private func checkColumn(_ title: String, checks: [ReviewCheck]) -> some View {
        let met = checks.filter { $0.verdict == .met }.count

        return VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text("\(met)/\(checks.count)")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(met == checks.count ? Theme.State.merged : Theme.textMuted)
            }
            ForEach(checks) { check in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: check.verdict.icon)
                        .font(.system(size: 11.5))
                        .foregroundStyle(check.verdict.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(check.text)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.text)
                        if let note = check.note {
                            Text(note)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.textMuted)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var findings: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Findings")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(review.open.isEmpty ? "none open" : "\(review.open.count) open")
                    .font(.system(size: 11.5))
                    .foregroundStyle(review.open.isEmpty ? Theme.State.merged : Theme.State.cancelled)
                Spacer()
                if !review.resolved.isEmpty {
                    HStack(spacing: 4) {
                        Text("\(review.resolved.count) fixed")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(showResolved ? 180 : 0))
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textMuted)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.snappy(duration: 0.2)) { showResolved.toggle() } }
                }
            }
            ForEach(review.open) { FindingRow(finding: $0) }
            if showResolved || review.open.isEmpty {
                ForEach(review.resolved) { FindingRow(finding: $0) }
            }
        }
    }
}

/// Review → fix → review, as a row of numbered rounds up to the auto-review cap.
struct RoundTrack: View {
    let review: AutoReview

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(1...review.maxRounds, id: \.self) { number in
                let round = review.rounds.first { $0.number == number }
                VStack(alignment: .leading, spacing: 5) {
                    Capsule()
                        .fill(round.map { color(for: $0.verdict) } ?? Theme.fill)
                        .frame(height: 4)
                    HStack(spacing: 4) {
                        Text("R\(number)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(round == nil ? Theme.textFaint : Theme.text)
                        if let round {
                            Text(label(round))
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textMuted)
                                .lineLimit(1)
                        }
                    }
                    if let fix = round?.fix {
                        Text(fix.prefix(7))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Theme.textFaint)
                            .help("Fix pushed: \(fix)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func label(_ round: ReviewRound) -> String {
        switch round.verdict {
        case .passed: "passed"
        case .inProgress: "reviewing…"
        case .escalated: "escalated"
        case .changesRequested: "\(round.found) found"
        }
    }

    private func color(for verdict: ReviewRound.Verdict) -> Color {
        switch verdict {
        case .passed: Theme.State.merged
        case .changesRequested: Theme.State.awaitingApproval
        case .escalated: Theme.State.cancelled
        case .inProgress: Theme.State.reviewing
        }
    }
}

struct VerdictPill: View {
    let verdict: ReviewRound.Verdict

    var body: some View {
        let (title, icon, color): (String, String, Color) = switch verdict {
        case .passed: ("Passed · ready for you", "checkmark.seal.fill", Theme.State.merged)
        case .changesRequested: ("Changes requested", "arrow.uturn.backward", Theme.State.awaitingApproval)
        case .escalated: ("Escalated to a human", "hand.raised.fill", Theme.State.cancelled)
        case .inProgress: ("Reviewing", "eye.fill", Theme.State.reviewing)
        }

        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10.5))
            Text(title)
        }
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}

struct FindingRow: View {
    let finding: ReviewFinding

    private var fixedRound: Int? {
        if case .fixed(let round) = finding.status { round } else { nil }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(finding.severity.title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(fixedRound == nil ? finding.severity.color : Theme.textFaint)
                .frame(width: 50, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(finding.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(fixedRound == nil ? Theme.text : Theme.textMuted)
                    .strikethrough(fixedRound != nil, color: Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text(finding.kind.rawValue)
                    if let file = finding.file {
                        Text(file).font(.system(size: 11, design: .monospaced))
                    }
                    Text("raised R\(finding.raisedIn)")
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.textFaint)
            }
            Spacer(minLength: 8)
            if let fixedRound {
                Label("Fixed R\(fixedRound)", systemImage: "checkmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.State.merged)
            } else {
                Text("Open")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(finding.severity.color)
            }
        }
    }
}

// MARK: Hand raises

/// An agent's request for help, with what it tried and the calls it thinks you could make.
struct HandRaiseCard: View {
    @Environment(AppState.self) private var state
    let task: FactoryTask
    let hand: HandRaise
    /// On the Needs a hand page the card also names the task; inside the task it doesn't need to.
    var showsTask = true
    @State private var choice: String?
    @State private var note = ""

    init(task: FactoryTask, hand: HandRaise, showsTask: Bool = true) {
        self.task = task
        self.hand = hand
        self.showsTask = showsTask
        _choice = State(initialValue: hand.options.first { $0.recommended }?.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            topLine

            VStack(alignment: .leading, spacing: 8) {
                Text(hand.headline)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(hand.explanation)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text.opacity(0.85))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if showsTask, let review = task.autoReview, hand.reason == .reviewLoop {
                RoundTrack(review: review)
            }

            tried

            VStack(alignment: .leading, spacing: 8) {
                Text("Your call")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                ForEach(hand.options) { option in optionRow(option) }
            }

            reply
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.cardBG)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(hand.reason.color.opacity(0.35)))
        )
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12)
                .fill(hand.reason.color)
                .frame(width: 3)
        }
    }

    private var topLine: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: hand.reason.icon).font(.system(size: 10.5, weight: .semibold))
                Text(hand.reason.title)
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(hand.reason.color)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(hand.reason.color.opacity(0.12)))

            if showsTask {
                Text(task.id)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textMuted)
                Text(task.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Circle().fill(FactoryData.goal(named: task.goal).color).frame(width: 6, height: 6)
            }
            Spacer()
            if let agent = task.agent {
                AgentAvatar(agent: agent, size: 18)
                Text("\(agent.name) · \(hand.since) ago")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
            }
            Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(Theme.textFaint)
            AgentAvatar(agent: hand.assignee, size: 18)
                .help("Asking \(hand.assignee.firstName)")
        }
    }

    private var tried: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What \(task.agent?.name ?? "it") already tried")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
            ForEach(Array(hand.tried.enumerated()), id: \.offset) { index, attempt in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.textFaint)
                        .frame(width: 12)
                    Text(attempt)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textMuted)
                }
            }
        }
    }

    private func optionRow(_ option: HandRaise.Option) -> some View {
        let selected = choice == option.title

        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 13))
                .foregroundStyle(selected ? Theme.accent : Theme.textFaint)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(option.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text)
                    if option.recommended {
                        Text("\(task.agent?.name ?? "Agent") suggests")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 6)
                            .frame(height: 17)
                            .background(Capsule().fill(Theme.accent.opacity(0.12)))
                    }
                }
                Text(option.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(selected ? Theme.accent.opacity(0.06) : Theme.fillSubtle)
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Theme.accent.opacity(0.45) : Theme.stroke))
        )
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy(duration: 0.15)) { choice = selected ? nil : option.title } }
    }

    private var reply: some View {
        let option = hand.options.first { $0.title == choice }
        let canSend = option != nil || !note.trimmingCharacters(in: .whitespaces).isEmpty

        return HStack(spacing: 8) {
            TextField(option == nil ? "Or tell \(task.agent?.name ?? "the agent") something else…" : "Add a note (optional)", text: $note)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.fillSubtle)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke))
                )
                .onSubmit { if canSend { send(option) } }

            if showsTask {
                smallButton("Open task", icon: "arrow.up.right") {
                    state.destination = .goal(task.goal)
                    state.openFocus(task.id)
                }
            }
            smallButton("Take over", icon: "person.crop.circle.badge.checkmark") {
                state.showToast("Checked out \(task.id.lowercased()) for you · \(task.agent?.name ?? "agent") paused", icon: "person.crop.circle.badge.checkmark")
            }

            HStack(spacing: 6) {
                Image(systemName: "paperplane.fill").font(.system(size: 10.5))
                Text("Send")
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 13)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent.opacity(canSend ? 1 : 0.4)))
            .contentShape(Rectangle())
            .onTapGesture { if canSend { send(option) } }
        }
    }

    private func send(_ option: HandRaise.Option?) {
        state.resolveHand(task.id, option: option, note: note.trimmingCharacters(in: .whitespaces))
    }

    private func smallButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10.5))
            Text(title)
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.fill)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

/// Every task where an agent stopped and asked for a human.
struct NeedsHandView: View {
    @Environment(AppState.self) private var state
    @State private var mineOnly = false

    var body: some View {
        let hands = (mineOnly ? state.myHandRaises : state.handRaises)

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Needs a hand")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text("Agents that stopped and asked for a person: review rounds that ran out, proofs they can't produce, briefs that need more input, or fixes that would break the budget. Nothing here moves until someone answers.")
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 6) {
                    filter("Everyone", count: state.handRaises.count, active: !mineOnly) { mineOnly = false }
                    filter("Asking me", count: state.myHandRaises.count, active: mineOnly) { mineOnly = true }
                    Spacer()
                    reasonSummary
                }

                if hands.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "hand.thumbsup").font(.system(size: 26)).foregroundStyle(Theme.textFaint)
                        Text("No one's stuck").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text)
                        Text("Agents will show up here when they need you.").font(.system(size: 12.5)).foregroundStyle(Theme.textMuted)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                }

                ForEach(hands) { task in
                    if let hand = task.hand {
                        HandRaiseCard(task: task, hand: hand)
                            .id(task.id)
                            .transition(.opacity.combined(with: .move(edge: .leading)))
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 30)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.top)
    }

    private var reasonSummary: some View {
        HStack(spacing: 12) {
            ForEach([HandRaise.Reason.reviewLoop, .proofBurden, .needsInput, .overBudget], id: \.self) { reason in
                let count = state.handRaises.filter { $0.hand?.reason == reason }.count
                if count > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: reason.icon).foregroundStyle(reason.color)
                        Text("\(count) \(reason.title.lowercased())")
                    }
                }
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.textMuted)
    }

    private func filter(_ title: String, count: Int, active: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            Text(title)
            Text("\(count)").foregroundStyle(active ? Theme.text.opacity(0.6) : Theme.textFaint).monospacedDigit()
        }
        .font(.system(size: 12.5, weight: active ? .medium : .regular))
        .foregroundStyle(active ? Theme.text : Theme.textMuted)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Capsule().fill(active ? Theme.fillSelected : .clear))
        .contentShape(Capsule())
        .onTapGesture { withAnimation(.snappy(duration: 0.2)) { action() } }
    }
}

/// Slim version for the side panel: what's wrong and a way into the full card.
struct InspectorHandCallout: View {
    @Environment(AppState.self) private var state
    let task: FactoryTask
    let hand: HandRaise

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: hand.reason.icon).foregroundStyle(hand.reason.color)
                Text("\(task.agent?.name ?? "Agent") needs a hand")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(hand.reason.title)
                    .font(.system(size: 11))
                    .foregroundStyle(hand.reason.color)
            }
            Text(hand.headline)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            Text("\(hand.options.count) options · open to answer")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hand.reason.color)
                .contentShape(Rectangle())
                .onTapGesture { state.openFocus(task.id) }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(hand.reason.color.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(hand.reason.color.opacity(0.25)))
        )
    }
}

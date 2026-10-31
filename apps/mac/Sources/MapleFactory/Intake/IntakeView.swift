import SwiftUI

/// Work asked for from Slack, Linear and Jira, before it becomes a task.
struct IntakeView: View {
    @Environment(AppState.self) private var state
    @AppStorage("intakeFilter") private var filter: IntakeFilter = .all
    @State private var showingHowTo = false

    /// A linked task's state, or nil when this app doesn't know the task. (`state.task(_:)` falls back to the first task.)
    private func taskState(_ id: String) -> TaskState? { state.tasks.first { $0.id == id }?.state }

    private var visible: [IntakeRequest] { IntakeFilter.visible(state.intake, filter: filter, taskState: taskState) }

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: state.contentWidth < 900 ? 260 : 320)
            Hairline(vertical: true)
            if let id = state.selectedIntake, visible.contains(where: { $0.id == id }), let request = state.intakeRequest(id) {
                IntakeDetail(request: request)
                    .id(request.id)
            } else {
                PlaceholderView(title: "No request selected", icon: "tray.and.arrow.down")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: visible.map(\.id), initial: true) { _, ids in
            if !ids.contains(where: { $0 == state.selectedIntake }) { state.selectedIntake = ids.first }
        }
    }

    /// Where requests come in from: the mockup's integrations, or what a real factory takes.
    private var integrations: [(name: String, detail: String, icon: String, color: Color)] {
        guard state.isLive else { return FactoryData.integrations }
        return [
            ("Slack", "/maple <what you need>, once the Slack app is set up", "number", IntakeSource.slack(channel: "").color),
            ("API", "POST /api/intake with the org's intake key", "curlybraces", Theme.textMuted),
        ]
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text("Requests")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text("\(state.intake.count)")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textFaint)
                    Spacer()
                    Button { showingHowTo.toggle() } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textMuted)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("How requests come in")
                    .popover(isPresented: $showingHowTo, arrowEdge: .bottom) { howTo }
                }
                filterPills
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Hairline()

            if visible.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(visible) { request in row(request) }
                    }
                    .padding(8)
                }
            }
        }
    }

    /// The popover behind the ⓘ: where requests come in from, and what becomes of them.
    private var howTo: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How requests come in")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(integrations, id: \.name) { integration in
                    HStack(spacing: 7) {
                        SourceGlyph(icon: integration.icon, color: integration.color, size: 16)
                        Text(integration.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
                        Text(integration.detail).font(.system(size: 11.5)).foregroundStyle(Theme.textMuted)
                    }
                }
            }
            Text("Each request becomes a task with Turn into task, or joins an existing one.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
    }

    private var filterPills: some View {
        let counts = IntakeFilter.counts(state.intake, taskState: taskState)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(IntakeFilter.allCases) { option in
                    let active = filter == option
                    HStack(spacing: 4) {
                        Text(option.title)
                        Text("\(counts[option] ?? 0)")
                            .foregroundStyle(active ? Theme.textMuted : Theme.textFaint)
                            .monospacedDigit()
                    }
                    .font(.system(size: 11.5, weight: active ? .medium : .regular))
                    .foregroundStyle(active ? Theme.text : Theme.textMuted)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Capsule().fill(active ? Theme.fillSelected : .clear))
                    .contentShape(Capsule())
                    .onTapGesture { withAnimation(.snappy(duration: 0.2)) { filter = option } }
                }
            }
        }
        .scrollClipDisabled()
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: filter.icon)
                .font(.system(size: 20))
                .foregroundStyle(Theme.textFaint)
            Text(filter.emptyTitle)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textMuted)
            if filter != .all {
                Button("Show all") { withAnimation(.snappy(duration: 0.2)) { filter = .all } }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }

    /// The row's status pill: an accepted request shows its task's live state.
    private func statusPill(_ request: IntakeRequest) -> StatusPill {
        if case .accepted(let id) = request.status, let task = taskState(id) {
            return StatusPill(text: "\(id) · \(task.title)", color: task.color)
        }
        return StatusPill(text: request.status.title, color: request.status.color)
    }

    private func row(_ request: IntakeRequest) -> some View {
        let selected = request.id == state.selectedIntake

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                SourceGlyph(icon: request.source.icon, color: request.source.color, size: 16)
                Text(request.source.title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                Spacer()
                Text(request.when).font(.system(size: 11)).foregroundStyle(Theme.textFaint)
            }
            Text(request.title)
                .font(.system(size: 13, weight: request.status == .new ? .semibold : .regular))
                .foregroundStyle(request.status == .declined ? Theme.textMuted : Theme.text)
                .lineLimit(2)
            HStack(spacing: 6) {
                AgentAvatar(agent: request.requester, size: 16)
                Text(request.requester.firstName).font(.system(size: 11.5)).foregroundStyle(Theme.textMuted)
                if !request.tickets.isEmpty {
                    Label("\(request.tickets.count)", systemImage: "ticket")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                }
                Spacer()
                statusPill(request)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.fillSelected : .clear))
        .contentShape(Rectangle())
        .onTapGesture { state.selectedIntake = request.id }
    }
}

// MARK: Detail

private struct IntakeDetail: View {
    @Environment(AppState.self) private var state
    let request: IntakeRequest
    @State private var reply = ""

    private var narrow: Bool { state.contentWidth < 1100 }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    (narrow ? AnyLayout(VStackLayout(alignment: .leading, spacing: 22)) : AnyLayout(HStackLayout(alignment: .top, spacing: 28))) {
                        thread
                            .frame(maxWidth: .infinity, alignment: .leading)
                        reading
                            .frame(width: narrow ? nil : 320)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 26)
                .frame(maxWidth: 1080, alignment: .leading)
            }
            .defaultScrollAnchor(.top)
            if !isClosed { actionBar }
        }
    }

    private var isClosed: Bool {
        if case .accepted = request.status { return true }
        return request.status == .declined
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SourceGlyph(icon: request.source.icon, color: request.source.color, size: 20)
                Text(request.source.title).font(.system(size: 12.5)).foregroundStyle(Theme.textMuted)
                Text("·").foregroundStyle(Theme.textFaint)
                AgentAvatar(agent: request.requester, size: 18)
                Text("\(request.requester.name) · \(request.when) ago").font(.system(size: 12.5)).foregroundStyle(Theme.textMuted)
                Spacer()
                StatusPill(text: request.status.title, color: request.status.color)
                if case .accepted(let taskID) = request.status {
                    Text("Open \(taskID)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.fill))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            state.destination = .goal(state.task(taskID).goal)
                            state.openFocus(taskID)
                        }
                }
            }
            Text(request.title)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The conversation as it reads in Slack (or the ticket's comments).
    private var thread: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel(title: request.source.title.hasPrefix("Slack") ? "Thread" : "Conversation")
                Spacer()
                Text("Synced both ways")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textFaint)
            }
            .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 16) {
                ForEach(request.thread) { message in
                    HStack(alignment: .top, spacing: 10) {
                        if message.isBot {
                            MapleMark(size: 30)
                        } else {
                            AgentAvatar(agent: message.author, size: 30)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(message.isBot ? "Maple" : message.author.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.text)
                                if message.isBot {
                                    Text("APP")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(Theme.textMuted)
                                        .padding(.horizontal, 4)
                                        .frame(height: 14)
                                        .background(RoundedRectangle(cornerRadius: 3).fill(Theme.fill))
                                }
                                Text(message.when == "now" ? "just now" : "\(message.when) ago")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Theme.textFaint)
                                if let task = message.relayedFrom {
                                    Label("from \(task)", systemImage: "arrow.turn.down.right")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(Theme.State.planning)
                                }
                            }
                            Text(styled(message.text))
                                .font(.system(size: 13.5))
                                .foregroundStyle(Theme.text.opacity(0.9))
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.cardBG)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke))
            )
        }
    }

    /// What Forge makes of the request: where it goes, what it links, what's missing.
    private var reading: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "sparkle").foregroundStyle(Theme.State.planning)
                Text("Maple reads this as").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
            }

            card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text("Goal").foregroundStyle(Theme.textMuted).frame(width: 64, alignment: .leading)
                        Circle().fill(FactoryData.goal(named: request.suggestedGoal).color).frame(width: 7, height: 7)
                        Text(request.suggestedGoal).foregroundStyle(Theme.text)
                    }
                    if let related = request.relatedTask {
                        HStack(alignment: .top, spacing: 8) {
                            Text("Related").foregroundStyle(Theme.textMuted).frame(width: 64, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(related).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textMuted)
                                Text(state.task(related).title).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .font(.system(size: 12.5))
            }

            card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        SectionLabel(title: "Tickets")
                        Spacer()
                        Text("agent context").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                    }
                    ForEach(request.tickets) { ticket in TicketRow(ticket: ticket) }
                }
            }

            if !request.gaps.isEmpty {
                card {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(title: "Missing before planning")
                        ForEach(request.gaps, id: \.self) { gap in
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Image(systemName: "questionmark.circle").font(.system(size: 11)).foregroundStyle(Theme.State.awaitingApproval)
                                Text(gap).font(.system(size: 12.5)).foregroundStyle(Theme.text)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { reply = "Quick question: \(gap.prefix(1).lowercased() + gap.dropFirst())?" }
                        }
                        Text("Click one to ask it in the thread.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textFaint)
                    }
                }
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                SourceGlyph(icon: request.source.icon, color: request.source.color, size: 16)
                TextField("Reply to \(request.requester.firstName) in \(request.source.title)…", text: $reply)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit(send)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.fillSubtle)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke))
            )

            button("Decline", primary: false) { state.declineIntake(request.id) }
            if let related = request.relatedTask {
                button("Add to \(related)", primary: false) { state.attachIntake(request.id, to: related) }
            }
            button("Turn into task", primary: true) { state.composeFromIntake(request.id) }
        }
        .padding(.horizontal, 24)
        .frame(height: 60)
        .overlay(alignment: .top) { Hairline() }
    }

    private func send() {
        state.askInThread(request.id, reply.trimmingCharacters(in: .whitespaces))
        reply = ""
    }

    private func button(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Text(title)
            .font(.system(size: 13, weight: primary ? .semibold : .regular))
            .foregroundStyle(primary ? Theme.onAccent : Theme.text)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(primary ? Theme.accent : Theme.fill)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(primary ? .clear : Theme.stroke))
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.cardBG)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke))
            )
    }

    /// Ticket keys and @mentions stand out like they would in Slack.
    private func styled(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        let tokens = text.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "." || $0 == "(" || $0 == ")" })
            .map(String.init)
            .filter { $0.hasPrefix("@") || $0.range(of: #"^[A-Z][A-Z0-9]{0,9}-\d+$"#, options: .regularExpression) != nil }
        for token in Set(tokens) {
            var searchRange = result.startIndex..<result.endIndex
            while let range = result[searchRange].range(of: token) {
                result[range].foregroundColor = token.hasPrefix("@") ? Theme.mention : Theme.State.building
                result[range].font = .system(size: 13.5, weight: .medium)
                searchRange = range.upperBound..<result.endIndex
            }
        }
        return result
    }
}

// MARK: Shared pieces

struct SourceGlyph: View {
    let icon: String
    let color: Color
    var size: CGFloat = 18

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28).fill(color))
    }
}

struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(Capsule().fill(color.opacity(0.13)))
            .lineLimit(1)
    }
}

/// A linked tracker ticket. With `toggle`, the eye flips whether the agent reads it as context.
struct TicketRow: View {
    let ticket: TicketLink
    var toggle: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            SourceGlyph(icon: ticket.system.glyph, color: ticket.system.color, size: 16)
            // Key over title, so titles stay readable in narrow rails.
            VStack(alignment: .leading, spacing: 2) {
                Text(ticket.key)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.text)
                Text(ticket.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.text.opacity(0.85))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Text(ticket.status)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.textMuted)
                .padding(.horizontal, 6)
                .frame(height: 17)
                .background(Capsule().fill(Theme.fill))
                .lineLimit(1)
            Image(systemName: ticket.asContext ? "eye" : "eye.slash")
                .font(.system(size: 11))
                .foregroundStyle(ticket.asContext ? Theme.State.planning : Theme.textFaint)
                .frame(width: 18)
                .contentShape(Rectangle())
                .onTapGesture { toggle?() }
                .help(ticket.asContext
                      ? "The agent reads this ticket's description and \(ticket.comments) comments"
                      : "Linked, but not given to the agent")
        }
    }
}

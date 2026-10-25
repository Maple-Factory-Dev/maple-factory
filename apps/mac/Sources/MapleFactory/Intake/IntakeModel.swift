import SwiftUI

// MARK: Tickets

/// A ticket in the team's tracker. Tasks link to tickets (often several) rather than being them;
/// linked tickets are handed to the agent as context.
struct TicketLink: Identifiable, Hashable {
    enum System: String {
        case linear = "Linear", jira = "Jira"

        var color: Color {
            switch self {
            case .linear: Color(hex: 0x5E6AD2)
            case .jira: Color(hex: 0x2684FF)
            }
        }

        var glyph: String {
            switch self {
            case .linear: "line.diagonal"
            case .jira: "diamond.fill"
            }
        }
    }

    let system: System
    let key: String
    let title: String
    var status: String
    /// Comments the agent gets along with the description.
    var comments: Int = 0
    var asContext = true
    var id: String { key }
}

// MARK: Intake

/// Where a request came from.
enum IntakeSource: Hashable {
    case slack(channel: String)
    case linear
    case jira

    var title: String {
        switch self {
        case .slack(let channel): "Slack \(channel)"
        case .linear: "Linear"
        case .jira: "Jira"
        }
    }

    var icon: String {
        switch self {
        case .slack: "number"
        case .linear: "line.diagonal"
        case .jira: "diamond.fill"
        }
    }

    var color: Color {
        switch self {
        case .slack: Color(hex: 0xE01E5A)
        case .linear: TicketLink.System.linear.color
        case .jira: TicketLink.System.jira.color
        }
    }
}

/// One message in the request's conversation, mirrored from Slack (or the ticket's comments).
struct ThreadMessage: Identifiable {
    let id = UUID()
    let author: Person
    let text: String
    let when: String
    /// Posted by the Forge bot on behalf of an agent or a teammate.
    var isBot = false
    /// A question an agent relayed from a task.
    var relayedFrom: String? = nil
}

/// Work asked for from outside the app, waiting to be triaged into a task.
struct IntakeRequest: Identifiable {
    enum Status: Equatable {
        case new
        /// Forge asked a follow-up and is waiting on the requester.
        case clarifying
        case accepted(taskID: String)
        case declined

        var title: String {
            switch self {
            case .new: "New"
            case .clarifying: "Waiting on requester"
            case .accepted(let id): "Became \(id)"
            case .declined: "Declined"
            }
        }

        var color: Color {
            switch self {
            case .new: Theme.State.building
            case .clarifying: Theme.State.awaitingApproval
            case .accepted: Theme.State.merged
            case .declined: Theme.textFaint
            }
        }
    }

    let id: String
    let source: IntakeSource
    let requester: Person
    let title: String
    let when: String
    var thread: [ThreadMessage]
    var tickets: [TicketLink]
    var status: Status
    /// Forge's guess at where this belongs.
    let suggestedGoal: String
    /// An existing task this looks like, if any.
    var relatedTask: String? = nil
    /// What's missing before an agent could plan it.
    var gaps: [String] = []
}

extension FactoryData {
    /// The Slack and tracker bot that speaks for the factory.
    static let bot = Person(name: "Maple", color: Theme.accent, isHuman: false)

    static let dana = Person(name: "Dana Ruiz", color: Color(hex: 0x0E9F8E), isHuman: true)
    static let mei = Person(name: "Mei Tanaka", color: Color(hex: 0x8B5CF6), isHuman: true)
    static let sam = Person(name: "Sam Ortiz", color: Color(hex: 0xD97706), isHuman: true)

    static let integrations: [(name: String, detail: String, icon: String, color: Color)] = [
        ("Slack", "#maple-requests · @maple anywhere", "number", IntakeSource.slack(channel: "").color),
        ("Linear", "ENG, MOB · issues labelled maple", "line.diagonal", TicketLink.System.linear.color),
        ("Jira", "SUP · tickets assigned to Maple", "diamond.fill", TicketLink.System.jira.color),
    ]

    static let seedIntake: [IntakeRequest] = [
        IntakeRequest(
            id: "req-mobile-logout", source: .slack(channel: "#maple-requests"), requester: mei,
            title: "iOS app logs people out after about an hour in the background", when: "6m",
            thread: [
                ThreadMessage(author: mei, text: "@maple the iOS app logs people out after ~1h in the background. Repro and logs are in MOB-231. Can someone take a look?", when: "6m"),
                ThreadMessage(author: bot, text: "On it. This looks related to ATL-147 (refresh-token rotation), which is waiting on plan approval. I can add MOB-231 to that task, or open a new one. I'll post any questions here.", when: "6m", isBot: true),
            ],
            tickets: [
                TicketLink(system: .linear, key: "MOB-231", title: "Users logged out after backgrounding the app", status: "Triage", comments: 6),
                TicketLink(system: .linear, key: "MOB-198", title: "Silent refresh fails on flaky networks", status: "Backlog", comments: 2),
            ],
            status: .new, suggestedGoal: "Auth overhaul", relatedTask: "ATL-147",
            gaps: ["Which app versions are affected", "Whether Android sees it too"]
        ),
        IntakeRequest(
            id: "req-public-rate-limits", source: .linear, requester: sam,
            title: "Rate limits for the public API", when: "40m",
            thread: [
                ThreadMessage(author: sam, text: "Two customers hammered /v2/projects last week and slowed everyone down. We need rate limits on the public API before the launch.", when: "1h"),
                ThreadMessage(author: bot, text: "Should limits apply per API key or per org? Per org is fairer to customers with many keys, but per key is simpler to explain.", when: "40m", isBot: true),
            ],
            tickets: [
                TicketLink(system: .linear, key: "ENG-412", title: "Rate limits for the public API", status: "Todo", comments: 3),
            ],
            status: .clarifying, suggestedGoal: "Performance budget",
            gaps: ["Per key or per org"]
        ),
        IntakeRequest(
            id: "req-invoice-pdf", source: .jira, requester: sam,
            title: "Customers can't download invoice PDFs over 10 MB", when: "2h",
            thread: [
                ThreadMessage(author: sam, text: "Three enterprise customers can't download their annual invoices. The PDF request times out after 30s once the file is over ~10 MB.", when: "2h"),
            ],
            tickets: [
                TicketLink(system: .jira, key: "SUP-1182", title: "Invoice PDF download times out", status: "Open", comments: 9),
                TicketLink(system: .jira, key: "SUP-1190", title: "Annual invoice won't download (Acme)", status: "Open", comments: 4),
                TicketLink(system: .jira, key: "SUP-1194", title: "Large invoice PDF error", status: "Open", comments: 1),
            ],
            status: .new, suggestedGoal: "Billing v2",
            gaps: []
        ),
        IntakeRequest(
            id: "req-sso", source: .slack(channel: "#maple-requests"), requester: dana,
            title: "SSO for enterprise orgs", when: "2d",
            thread: [
                ThreadMessage(author: dana, text: "@maple three enterprise deals are blocked on SSO. They need SAML, and one also needs OIDC.", when: "2d"),
                ThreadMessage(author: bot, text: "Tracking this as ATL-160. Maple-4 is planning it, and I'll post questions in this thread.", when: "2d", isBot: true),
                ThreadMessage(author: bot, text: "Question from Maple-4: should users who sign in through SAML be auto-provisioned into the org's default team, or need an invite first?", when: "12m", isBot: true, relayedFrom: "ATL-160"),
                ThreadMessage(author: dana, text: "All three prospects expect auto-provisioning (JIT). An invite step would be a dealbreaker for Acme.", when: "4m"),
            ],
            tickets: [
                TicketLink(system: .jira, key: "SALES-77", title: "Acme: SAML SSO requirement", status: "In Progress", comments: 5),
                TicketLink(system: .linear, key: "ENG-388", title: "Enterprise SSO (SAML + OIDC)", status: "In Progress", comments: 11),
            ],
            status: .accepted(taskID: "ATL-160"), suggestedGoal: "Auth overhaul"
        ),
    ]

    /// Tickets linked to existing tasks.
    static let seedTicketLinks: [String: [TicketLink]] = [
        "ATL-160": [
            TicketLink(system: .linear, key: "ENG-388", title: "Enterprise SSO (SAML + OIDC)", status: "In Progress", comments: 11),
            TicketLink(system: .jira, key: "SALES-77", title: "Acme: SAML SSO requirement", status: "In Progress", comments: 5),
        ],
        "ATL-147": [
            TicketLink(system: .linear, key: "ENG-351", title: "Refresh tokens never rotate", status: "In Progress", comments: 4),
        ],
        "BIL-91": [
            TicketLink(system: .jira, key: "SUP-1104", title: "Customer charged twice after webhook retry", status: "In Progress", comments: 7),
            TicketLink(system: .linear, key: "ENG-402", title: "Stripe webhook idempotency", status: "In Review", comments: 2),
        ],
    ]
}

// MARK: Actions

extension AppState {
    var newIntake: Int { intake.filter { $0.status == .new }.count }

    func intakeRequest(_ id: String) -> IntakeRequest? { intake.first { $0.id == id } }

    private func updateIntake(_ id: String, _ mutate: (inout IntakeRequest) -> Void) {
        guard let index = intake.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.snappy(duration: 0.25)) { mutate(&intake[index]) }
    }

    /// Opens the composer with the request's conversation and tickets already in the brief.
    func composeFromIntake(_ id: String) {
        guard let request = intakeRequest(id) else { return }
        let quoted = request.thread.filter { !$0.isBot }.map { "> \($0.text)\n> — \($0.author.firstName)" }.joined(separator: "\n>\n")
        let tickets = request.tickets.map { "- \($0.key): \($0.title)" }.joined(separator: "\n")
        let body = """
        \(quoted)

        ## Context
        Requested by \(request.requester.name) in \(request.source.title).
        \(tickets)

        ## Done when
        - [ ] 
        """
        startCompose(goal: request.suggestedGoal, title: request.title, body: body)
        draft.tickets = request.tickets
        draft.intakeID = id
        draft.shareable = true
    }

    /// Called when a task is created from a request: the bot tells the requester where it went.
    func acceptIntake(_ id: String, as taskID: String, agent: String?) {
        updateIntake(id) { request in
            request.status = .accepted(taskID: taskID)
            request.thread.append(ThreadMessage(
                author: FactoryData.bot,
                text: "Tracking this as \(taskID)\(agent.map { ". \($0) is planning it" } ?? ""). I'll post questions here, and the thread updates when it merges.",
                when: "now", isBot: true))
        }
    }

    /// Adds the request's tickets to an existing task instead of making a new one.
    func attachIntake(_ id: String, to taskID: String) {
        guard let request = intakeRequest(id) else { return }
        update(taskID) { task in
            for ticket in request.tickets where !task.tickets.contains(where: { $0.key == ticket.key }) {
                task.tickets.append(ticket)
            }
            task.activity.insert(ActivityItem(who: FactoryData.me.name,
                                              text: "Linked \(request.tickets.map(\.key).joined(separator: ", ")) from \(request.requester.firstName)'s request", when: "now"), at: 0)
        }
        updateIntake(id) { request in
            request.status = .accepted(taskID: taskID)
            request.thread.append(ThreadMessage(author: FactoryData.bot,
                                                text: "Added to \(taskID). Its agent will read \(request.tickets.map(\.key).joined(separator: " and ")) as context. I'll update this thread when it ships.",
                                                when: "now", isBot: true))
        }
        showToast("Linked \(request.tickets.count) ticket\(request.tickets.count == 1 ? "" : "s") to \(taskID)", icon: "link")
    }

    /// Posts a follow-up into the request's thread as the bot. The mock requester answers a moment later.
    func askInThread(_ id: String, _ text: String) {
        guard let request = intakeRequest(id), !text.isEmpty else { return }
        updateIntake(id) { request in
            request.thread.append(ThreadMessage(author: FactoryData.bot, text: text, when: "now", isBot: true))
            request.status = .clarifying
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            updateIntake(id) { request in
                request.thread.append(ThreadMessage(author: request.requester,
                                                    text: "Good question. 2.31 and up, iOS only so far. Android looks fine.",
                                                    when: "now"))
                request.status = .new
                request.gaps.removeAll()
            }
            showToast("\(request.requester.firstName) replied in \(request.source.title)", icon: "bubble.left.fill", color: request.source.color)
        }
    }

    func toggleTicketContext(_ taskID: String, key: String) {
        update(taskID) { task in
            guard let index = task.tickets.firstIndex(where: { $0.key == key }) else { return }
            task.tickets[index].asContext.toggle()
        }
    }

    func declineIntake(_ id: String) {
        updateIntake(id) { request in
            request.status = .declined
            request.thread.append(ThreadMessage(author: FactoryData.bot,
                                                text: "\(FactoryData.me.firstName) passed on this for now. Reply here if it becomes urgent.",
                                                when: "now", isBot: true))
        }
    }
}

/// Where a task came from and the tickets it works on, with which ones its agent reads.
struct LinkedCard: View {
    @Environment(AppState.self) private var state
    let task: FactoryTask

    var body: some View {
        let request = task.intakeID.flatMap { state.intakeRequest($0) }
        let reading = task.tickets.filter(\.asContext)

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel(title: "Linked")
                Spacer()
                Image(systemName: "plus")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                    .help("Link a Linear or Jira ticket")
            }

            if let request {
                HStack(alignment: .top, spacing: 8) {
                    SourceGlyph(icon: request.source.icon, color: request.source.color, size: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Requested by \(request.requester.firstName) in \(request.source.title)")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Theme.text)
                        Text("Agent questions go to the thread · \(request.thread.count) messages")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textMuted)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.textMuted)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    state.selectedIntake = request.id
                    state.closeFocus()
                    state.destination = .intake
                }
            }

            ForEach(task.tickets) { ticket in
                TicketRow(ticket: ticket) { state.toggleTicketContext(task.id, key: ticket.key) }
            }

            if !task.tickets.isEmpty {
                Text(reading.isEmpty
                     ? "No tickets are given to the agent."
                     : "\(task.agent?.name ?? "The agent") reads \(reading.count) ticket\(reading.count == 1 ? "" : "s") (\(reading.map(\.comments).reduce(0, +)) comments) as context. Status syncs back when this merges.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

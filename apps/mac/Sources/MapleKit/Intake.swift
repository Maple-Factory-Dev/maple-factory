import Foundation

// Intake (MF-278): the parts of the Requests list that don't depend on an app, shared by the Mac and the iPhone.

/// Where a request stands.
public enum IntakeStatus: Hashable, Sendable {
    case new
    /// The factory asked a follow-up and is waiting on the requester.
    case clarifying
    case accepted(taskID: String)
    case declined

    /// Parses the wire's status string; anything unknown reads as new.
    public init(wire status: String, taskID: String?) {
        switch status {
        case "clarifying": self = .clarifying
        case "accepted": self = .accepted(taskID: taskID ?? "")
        case "declined": self = .declined
        default: self = .new
        }
    }

    public var title: String {
        switch self {
        case .new: "New"
        case .clarifying: "Waiting on requester"
        case .accepted(let id): "Became \(id)"
        case .declined: "Declined"
        }
    }

    /// Accepted or declined: nothing left to triage.
    public var isSettled: Bool {
        switch self {
        case .accepted, .declined: true
        case .new, .clarifying: false
        }
    }
}

/// Anything the Requests filter can sort into buckets.
public protocol IntakeTriageable {
    var id: String { get }
    var intakeStatus: IntakeStatus { get }
}

extension Wire.IntakeRequest: IntakeTriageable {
    public var intakeStatus: IntakeStatus { IntakeStatus(wire: status, taskID: taskId) }
}

/// The Requests list's filter pills (MF-197): which requests still need an answer, which wait on the
/// requester, which became tasks that are still running, and which are over.
public enum IntakeFilter: String, CaseIterable, Identifiable, Sendable {
    case all, unanswered, waiting, inFlight, done

    public var id: Self { self }

    public var title: String {
        switch self {
        case .all: "All"
        case .unanswered: "Unanswered"
        case .waiting: "Waiting"
        case .inFlight: "In flight"
        case .done: "Done"
        }
    }

    public var icon: String {
        switch self {
        case .all: "tray"
        case .unanswered: "bubble.left"
        case .waiting: "hourglass"
        case .inFlight: "hammer"
        case .done: "checkmark.circle"
        }
    }

    /// What the list says when nothing matches.
    public var emptyTitle: String {
        switch self {
        case .all: "No requests yet"
        case .unanswered: "No unanswered requests"
        case .waiting: "Nobody to wait on"
        case .inFlight: "Nothing in flight"
        case .done: "Nothing done yet"
        }
    }

    /// The bucket a request lands in. An accepted request is in flight until its task finishes; a task
    /// the app doesn't know should read as unfinished.
    public static func bucket(for status: IntakeStatus, isFinished: (String) -> Bool) -> IntakeFilter {
        switch status {
        case .new: .unanswered
        case .clarifying: .waiting
        case .declined: .done
        case .accepted(let id): isFinished(id) ? .done : .inFlight
        }
    }

    public static func bucket<R: IntakeTriageable>(for request: R, isFinished: (String) -> Bool) -> IntakeFilter {
        bucket(for: request.intakeStatus, isFinished: isFinished)
    }

    /// The requests the filter shows, in the order given. `keeping` stays in the list even when it no longer
    /// matches: the request just acted on, so answering one doesn't swap it for another.
    public static func visible<R: IntakeTriageable>(_ requests: [R], filter: IntakeFilter, keeping: String? = nil,
                                                    isFinished: (String) -> Bool) -> [R] {
        guard filter != .all else { return requests }
        return requests.filter { $0.id == keeping || bucket(for: $0, isFinished: isFinished) == filter }
    }

    /// The filter to show when `selected` is picked from outside the list: this one if it shows the
    /// request, otherwise All, so the request isn't dropped for another.
    public func revealing<R: IntakeTriageable>(_ selected: String?, in requests: [R], isFinished: (String) -> Bool) -> IntakeFilter {
        guard let selected, let request = requests.first(where: { $0.id == selected }) else { return self }
        return self == .all || Self.bucket(for: request, isFinished: isFinished) == self ? self : .all
    }

    /// How many requests each pill shows.
    public static func counts<R: IntakeTriageable>(_ requests: [R], isFinished: (String) -> Bool) -> [IntakeFilter: Int] {
        var counts: [IntakeFilter: Int] = [.all: requests.count]
        for request in requests { counts[bucket(for: request, isFinished: isFinished), default: 0] += 1 }
        return counts
    }
}

/// The brief a task starts with when it's made from a request: the requester's words quoted, where it
/// came from, its tickets, and an empty Done when.
public enum IntakeBrief {
    public struct Message: Sendable {
        public var author: String
        public var text: String
        public var isBot: Bool
        public init(author: String, text: String, isBot: Bool) {
            self.author = author
            self.text = text
            self.isBot = isBot
        }
    }

    public static func compose(requester: String, source: String, thread: [Message], tickets: [(key: String, title: String)]) -> String {
        let quoted = thread.filter { !$0.isBot }.map { "> \($0.text)\n> — \(firstName($0.author))" }.joined(separator: "\n>\n")
        let ticketLines = tickets.map { "- \($0.key): \($0.title)" }.joined(separator: "\n")
        return """
        \(quoted)

        ## Context
        Requested by \(requester) in \(source).
        \(ticketLines)

        ## Done when
        - [ ]
        """
    }

    /// The brief for a request as it comes off the wire.
    public static func compose(_ request: Wire.IntakeRequest, sourceTitle: String? = nil) -> String {
        compose(requester: request.requester, source: sourceTitle ?? Self.sourceTitle(request),
                thread: request.thread.map { Message(author: $0.author, text: $0.text, isBot: $0.bot) },
                tickets: request.tickets.map { ($0.key, $0.title) })
    }

    /// "Slack #channel", "Linear", "Jira" or "the API".
    public static func sourceTitle(_ request: Wire.IntakeRequest) -> String {
        switch request.source {
        case "slack": "Slack \(request.channel ?? "")".trimmingCharacters(in: .whitespaces)
        case "linear": "Linear"
        case "jira": "Jira"
        default: "the API"
        }
    }

    private static func firstName(_ name: String) -> String {
        name.split(separator: " ").first.map(String.init) ?? name
    }
}

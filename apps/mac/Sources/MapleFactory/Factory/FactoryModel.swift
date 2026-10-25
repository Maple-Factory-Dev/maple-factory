import SwiftUI

enum TaskState: CaseIterable, Identifiable {
    case drafting, planning, awaitingApproval, building, reviewing, merged, cancelled

    var id: Self { self }

    /// The happy path a task moves through; `cancelled` can branch off from any of these.
    static let pipeline: [TaskState] = [.drafting, .planning, .awaitingApproval, .building, .reviewing, .merged]

    var title: String {
        switch self {
        case .drafting: "Drafting"
        case .planning: "Planning"
        case .awaitingApproval: "Awaiting approval"
        case .building: "Building"
        case .reviewing: "Reviewing"
        case .merged: "Merged"
        case .cancelled: "Cancelled"
        }
    }

    var icon: String {
        switch self {
        case .drafting: "pencil.line"
        case .planning: "list.bullet.indent"
        case .awaitingApproval: "hand.raised"
        case .building: "hammer"
        case .reviewing: "eye"
        case .merged: "arrow.triangle.merge"
        case .cancelled: "xmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .drafting: Theme.State.drafting
        case .planning: Theme.State.planning
        case .awaitingApproval: Theme.State.awaitingApproval
        case .building: Theme.State.building
        case .reviewing: Theme.State.reviewing
        case .merged: Theme.State.merged
        case .cancelled: Theme.State.cancelled
        }
    }
}

/// Humans and agents share one identity model so they can sit side by side in avatars, owners and activity.
struct Agent: Identifiable {
    let name: String
    let color: Color
    var isHuman = false
    var github: String? = nil
    var id: String { name }

    var firstName: String { String(name.split(separator: " ").first ?? "") }

    var avatarURL: URL? {
        github.flatMap { URL(string: "https://github.com/\($0).png?size=96") }
    }

    var initials: String {
        isHuman ? String(name.split(separator: " ").compactMap(\.first)) : String(name.suffix(1))
    }
}

typealias Person = Agent

struct Comment {
    let author: Person
    let text: String
    let when: String
    var anchor: String? = nil
    /// Set when the comment came in from outside, e.g. "Slack #maple-requests".
    var via: String? = nil
}

struct PlanStep {
    enum Change { case added, modified(from: String) }
    enum Progress { case done, active, pending }

    let text: String
    let file: String
    /// How this step differs from the previous plan version, if it does.
    var change: Change? = nil
    /// Only set once the task is building (or while a planner is still drafting).
    var progress: Progress? = nil
}

/// A request to redirect a planner or builder agent mid-flight.
struct ChangeRequest: Identifiable {
    enum Status { case queued, applying, applied }

    let id = UUID()
    let author: Person
    let text: String
    var anchor: String? = nil
    var status: Status = .queued
    var when = "now"
    /// When the agent will pick it up, e.g. "After step 4".
    var timing: String? = nil
}

/// An acceptance check the building agent has to prove with evidence before the task can merge.
struct DoneCriterion: Identifiable {
    enum ProofKind {
        case screenshot, video, terminal, tests

        var title: String {
            switch self {
            case .screenshot: "Screenshot"
            case .video: "Video"
            case .terminal: "Terminal output"
            case .tests: "Test results"
            }
        }

        var icon: String {
            switch self {
            case .screenshot: "photo"
            case .video: "play.rectangle"
            case .terminal: "terminal"
            case .tests: "checklist"
            }
        }
    }

    enum Status { case pending, proving, proven, failed }

    enum Evidence {
        case screenshot(caption: String)
        case video(caption: String, duration: String)
        case terminal(command: String, output: [String])
        case tests(suite: String, passed: Int, failed: Int)
    }

    let text: String
    let proof: ProofKind
    var status: Status = .pending
    var evidence: Evidence? = nil
    var id: String { text }
}

struct ActivityItem {
    let who: String
    let text: String
    let when: String
}

struct FactoryTask: Identifiable {
    let id: String
    var goal = "Auth overhaul"
    var title: String
    var state: TaskState
    var agent: Agent? = nil
    var owner: Person = FactoryData.me
    var detail: String
    var progress: Double? = nil
    var diff: (added: Int, removed: Int)? = nil
    var checksFailing = false
    var needsYou = false
    /// Start and (projected) end, in days since `FactoryData.timelineStart`.
    var span: ClosedRange<Int> = 0...1
    var updated = "1h"
    var brief = ""
    var plan: [PlanStep] = []
    var question: String? = nil
    var activity: [ActivityItem] = []
    /// Teammates who have this task open right now.
    var viewers: [Person] = []
    var approvals: [Person] = []
    var approvalsNeeded = 1
    var comments: [Comment] = []
    var planVersion = 1
    var changeRequests: [ChangeRequest] = []
    var doneWhen: [DoneCriterion] = []
    /// What the agent is doing this second, for planning and building tasks.
    var liveLog: String? = nil
    /// Size of the change: estimated from the plan until there's a real diff.
    var footprint: (files: Int, lines: Int, estimated: Bool)? = nil
    /// Names of sensitive areas (see `RiskPolicy`) the change touches.
    var areas: [String] = []
    /// Teammates who signed off on the finished change.
    var reviews: [Person] = []
    var pr: PullRequest? = nil
    /// Set on tasks created by splitting an over-budget task.
    var splitFrom: String? = nil
    /// The full Markdown brief the task was composed from, when there is one.
    var spec: String? = nil
    /// What the dedicated review agent found, once the task reaches review.
    var autoReview: AutoReview? = nil
    /// Set when an agent has stopped and asked a human for help.
    var hand: HandRaise? = nil
    /// Can run in teammates' team slots. Otherwise it only runs on its owner's machines.
    var shareable = false
    /// Tracker tickets this task works on. Many tickets can feed one task.
    var tickets: [TicketLink] = []
    /// The intake request it came from, so questions can go back to the requester.
    var intakeID: String? = nil
    /// Screens and terminal output the planner drew for the change.
    var mockups: [Mockup] = []

    var proven: Int { doneWhen.filter { $0.status == .proven }.count }
}

struct PullRequest {
    enum State { case draft, open, merged }

    var number: Int
    var state: State
    var checks: [CICheck]

    var url: URL { URL(string: "https://github.com/\(FactoryData.repo)/pull/\(number)")! }
    var requiredChecksPassing: Bool { checks.filter(\.required).allSatisfy { $0.status == .passed } }
}

struct CICheck: Identifiable {
    enum Status { case queued, running, passed, failed }

    let name: String
    var status: Status
    var duration: String
    var required = true
    var id: String { name }

    private static let suite: [(name: String, duration: String, required: Bool)] = [
        ("lint", "0:41", true),
        ("typecheck", "1:12", true),
        ("unit tests", "2:38", true),
        ("e2e", "6:20", true),
        ("CodeQL", "3:04", false),
        ("preview deploy", "1:51", false),
    ]

    /// The repo's standard workflow, with the named jobs failing or still running.
    static func standard(failing: Set<String> = [], running: Set<String> = []) -> [CICheck] {
        suite.map { job in
            let status: Status = failing.contains(job.name) ? .failed : running.contains(job.name) ? .running : .passed
            return CICheck(name: job.name, status: status, duration: status == .running ? "" : job.duration, required: job.required)
        }
    }

    static func queued() -> [CICheck] {
        suite.map { CICheck(name: $0.name, status: .queued, duration: "", required: $0.required) }
    }
}

struct Goal: Identifiable {
    let name: String
    let color: Color
    let dueOffset: Int
    let lead: Person
    let summary: String
    var id: String { name }
}

struct InboxItem: Identifiable {
    enum Kind: CaseIterable {
        case mention, approval, question, failing, review

        var title: String {
            switch self {
            case .mention: "Mentions"
            case .approval: "Plans awaiting approval"
            case .question: "Questions from agents"
            case .failing: "Failing checks"
            case .review: "Ready for review"
            }
        }

        var shortTitle: String {
            switch self {
            case .mention: "Mentions"
            case .approval: "Approvals"
            case .question: "Questions"
            case .failing: "Failing"
            case .review: "Review"
            }
        }

        var icon: String {
            switch self {
            case .mention: "at"
            case .approval: "hand.raised.fill"
            case .question: "questionmark.bubble.fill"
            case .failing: "xmark.octagon.fill"
            case .review: "eye.fill"
            }
        }

        var color: Color {
            switch self {
            case .mention: Theme.mention
            case .approval: Theme.State.awaitingApproval
            case .question: Theme.State.planning
            case .failing: Theme.State.cancelled
            case .review: Theme.State.reviewing
            }
        }

        var action: String {
            switch self {
            case .mention: "Reply"
            case .approval: "Approve"
            case .question: "Reply"
            case .failing: "Retry"
            case .review: "Review"
            }
        }
    }

    let kind: Kind
    let taskID: String
    var assignee: Person = FactoryData.me
    let message: String
    let when: String
    var id: String { "\(kind)-\(taskID)" }
}

enum Destination: Hashable {
    case inbox, myTasks, activity, scratchpad, usage, needsHand, machines, intake
    case goal(String)
}

struct Note: Identifiable {
    let id: UUID
    var title: String
    var body: String
    var updated: String
    /// Set once the note has been turned into a task.
    var taskID: String? = nil
}

/// The in-progress brief in the composer.
struct ComposeDraft {
    var title = ""
    var body = ""
    var goal = "Auth overhaul"
    /// An agent's name, or nil to let the factory pick the least busy one.
    var agent: String? = nil
    var fromNote: UUID? = nil
    var shareable = false
    var tickets: [TicketLink] = []
    var intakeID: String? = nil
}

enum GoalLayout: String, CaseIterable {
    case board = "Board", list = "List", timeline = "Timeline"
}

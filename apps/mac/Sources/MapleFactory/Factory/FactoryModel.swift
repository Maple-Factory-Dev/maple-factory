import SwiftUI

enum TaskState: CaseIterable, Identifiable {
    case drafting, planning, awaitingApproval, backlog, building, reviewing, merged, cancelled, closed

    var id: Self { self }

    /// Nothing more happens on it: merged, cancelled, or closed with nothing to merge.
    var isFinished: Bool { self == .merged || self == .cancelled || self == .closed }

    /// The happy path a task moves through; `cancelled` can branch off from any of these, `closed`
    /// ends one with nothing to merge (its planner proposed tasks instead of a plan), and a draft
    /// or a plan waiting for approval can be parked in `backlog`.
    static let pipeline: [TaskState] = [.drafting, .planning, .awaitingApproval, .backlog, .building, .reviewing, .merged]

    /// The stages a task's own track shows: Backlog only while it's parked there, since most never are.
    static func stages(for state: TaskState) -> [TaskState] {
        pipeline.filter { $0 != .backlog || state == .backlog }
    }

    var title: String {
        switch self {
        case .drafting: "Drafting"
        case .planning: "Planning"
        case .awaitingApproval: "Awaiting approval"
        case .backlog: "Backlog"
        case .building: "Building"
        case .reviewing: "Reviewing"
        case .merged: "Merged"
        case .cancelled: "Cancelled"
        case .closed: "Closed"
        }
    }

    var icon: String {
        switch self {
        case .drafting: "pencil.line"
        case .planning: "list.bullet.indent"
        case .awaitingApproval: "hand.raised"
        case .backlog: "tray.full"
        case .building: "hammer"
        case .reviewing: "eye"
        case .merged: "arrow.triangle.merge"
        case .cancelled: "xmark.circle"
        case .closed: "checkmark.circle"
        }
    }

    /// What kind of task lands in this state's column, for the empty column's tooltip.
    var emptyHint: String {
        switch self {
        case .drafting: "Tasks land here while their brief is still being written."
        case .planning: "Tasks land here while a planner works out how to build them."
        case .awaitingApproval: "Tasks land here once their plan is ready and waiting on your approval."
        case .backlog: "Tasks parked for later land here; nothing runs on them until someone picks them up."
        case .building: "Tasks land here while a builder works through the approved plan."
        case .reviewing: "Tasks land here once their build is proven and waiting on a review."
        case .merged: "Tasks land here once their branch is merged."
        case .cancelled: "Tasks land here when they're cancelled."
        case .closed: "Tasks land here when they finish with nothing to merge, like a scan that proposed tasks."
        }
    }

    var color: Color {
        switch self {
        case .drafting: Theme.State.drafting
        case .planning: Theme.State.planning
        case .awaitingApproval: Theme.State.awaitingApproval
        case .backlog: Theme.State.backlog
        case .building: Theme.State.building
        case .reviewing: Theme.State.reviewing
        case .merged: Theme.State.merged
        case .cancelled: Theme.State.cancelled
        case .closed: Theme.State.closed
        }
    }
}

/// Humans and agents share one identity model so they can sit side by side in avatars, owners and activity.
struct Agent: Identifiable {
    let name: String
    let color: Color
    var isHuman = false
    var github: String? = nil
    /// Online only on the iPhone or Android app, where presence says so (task viewers carry it).
    var mobile = false
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
    /// The factory's id for it, when it's live.
    var id: String? = nil
    /// The logins it @mentions, as the server worked them out; nil from a server older than mentions.
    var mentions: [String]? = nil
    /// The id of its thread's first comment, when it's a reply.
    var replyTo: String? = nil

    /// Whether it @mentions this login, by the server's list or, from an older server, its text.
    func mentions(_ login: String) -> Bool {
        if let mentions { return mentions.contains { $0.caseInsensitiveCompare(login) == .orderedSame } }
        let pattern = "(?<![\\w.@])@\(NSRegularExpression.escapedPattern(for: login))(?![A-Za-z0-9-])"
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
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
        /// `file`: the runner's upload, `/attachments/<id>/<name>`; nil for demo data, which draws a placeholder.
        case screenshot(caption: String, file: String? = nil)
        case video(caption: String, duration: String, file: String? = nil)
        case terminal(command: String, output: [String])
        case tests(suite: String, passed: Int, failed: Int)
        /// A person signed it off themselves instead of the agent proving it.
        case attested(by: String, reason: String?, when: String)
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
    /// The answers the agent suggested for `question`.
    var questionOptions: [String] = []
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
    /// Why the server gave it the risk it has (live only).
    var riskFactors: [RiskFactor] = []
    /// The org's risk classifier asked for a person's review of the built change (live only).
    var classifierReview = false
    /// The session working on it right now (live only).
    struct Worker: Equatable {
        let role: String
        let agent: String
        let machine: String
        let session: String
    }
    var worker: Worker? = nil
    /// What builds it, claude or codex, and the model its sessions ask for (nil: the agent's own default).
    var builder = "claude"
    var model: String? = nil
    /// The machine its worktree is on, once it has one (live only).
    var machine: String? = nil
    /// Machine tags it needs (macos, xcode…): only a machine with every one takes it (live only).
    var requires: [String] = []
    /// Its last pushed commit (live only).
    var pushed: String? = nil
    /// Its git branch, once it has one (live only).
    var gitBranch: String? = nil
    /// Changes whenever the task's pushed change does, so its diff is fetched again (live only).
    var diffKey: String? = nil
    /// The risk the planner (or the factory's assessment) gave it, before areas and size.
    var plannedRisk: RiskLevel = .low
    /// Teammates who signed off on the finished change.
    var reviews: [Person] = []
    /// Teammates asked to approve its plan or review its changes, like GitHub review requests.
    var requested: [Person] = []
    var pr: PullRequest? = nil
    /// Set on tasks created by splitting an over-budget task.
    var splitFrom: String? = nil
    /// What a Scout run picked it up from: a task (MF-98), or one of its review findings (MF-98#f3).
    var scoutedFrom: String? = nil
    /// What it follows up: one of a task's review findings (MF-98#f3), or the task itself (MF-98).
    var followUpOf: String? = nil
    /// How soon it should be done: p0 (do it right away) to p3 (when there's room); none when unset (live only).
    var priority: String? = nil
    /// The planner's proposed title, taken when the plan is approved (unless an approver keeps the current one).
    var suggestedTitle: String? = nil
    /// The bigger effort it's part of, like an epic: tasks in its goal with the same name are its siblings.
    var effort: String? = nil
    /// The GitHub repo it changes (live goals that span several), and the tasks it builds on.
    var repo: String? = nil
    var after: [String] = []
    /// Its plan's parts for the goal's other repos, and the tasks made for them once approved.
    var followUps: [(repo: String, title: String, task: String?)] = []
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
    /// Files its agents shared: charts, pages, images (MF-205).
    var artifacts: [Wire.Artifact] = []
    /// Its time, span by span, and when it was made (ms): the Time card adds them up (MF-302, live only).
    var stages: [Wire.StageSpan] = []
    var createdAtMs: UInt64 = 0
    /// Waiting for its next session (to plan, build or review) with nobody on it: on the board's Queued column.
    var queued = false
    /// Its place in the queue: lower starts first.
    var queueRank: Double = 0
    /// Its place among its goal's drafts: lower first.
    var draftRank: Double = 0
    /// Held until then, when it was scheduled.
    var startAt: Date? = nil
    /// The factory auto-merges it then unless someone holds it; and when that countdown started.
    var mergeAt: Date? = nil
    var mergeFrom: Date? = nil
    /// The tasks in flight it overlaps, and conflicts a dry-run merge found with its base.
    var mergeForecast: MergeForecast? = nil

    /// The factory is merging it: the server marks that with this live log line (engine.ts startMerge).
    static let mergingLog = "Merging…"
    var merging: Bool { state == .reviewing && liveLog == Self.mergingLog }

    /// What its next session does, while it's queued.
    var nextStep: String {
        switch state {
        case .planning: "Plan"
        case .reviewing: "Review"
        default: "Build"
        }
    }

    /// Scheduled for later than now.
    var scheduled: Bool { startAt.map { $0 > Date() } ?? false }

    var proven: Int { doneWhen.filter { $0.status == .proven }.count }

    /// Stands in when there are no tasks yet, so views that need one have something to show.
    static let none = FactoryTask(id: "—", goal: "", title: "No tasks yet", state: .drafting, detail: "")
}

/// How a task's branch should merge, kept current by the factory as other tasks merge.
struct MergeForecast {
    struct Overlap: Hashable {
        var task: String
        var files: [String]
    }
    /// Other tasks building or in review that change some of the same files.
    var overlaps: [Overlap] = []
    /// Files a dry-run merge into its base conflicts in; empty: merges cleanly (or not checked yet).
    var conflicts: [String] = []
    /// The task whose merge brought the conflicts in.
    var since: String? = nil
    var checkedAt: Date? = nil
    var base: String? = nil
}

struct PullRequest {
    enum State { case draft, open, merged, closed }

    var number: Int
    var state: State
    var checks: [CICheck]
    /// Where it is on GitHub; none for a local repo's change.
    var link: URL? = nil
    /// Live only: the real branches (the mockup makes them up).
    var branch: String? = nil
    var base: String? = nil
    /// A change to a repo with no GitHub: pushed and merged on origin, with no PR page or CI.
    var isLocal: Bool { branch != nil && link == nil }

    var url: URL { link ?? URL(string: "https://github.com/\(FactoryData.repo)/pull/\(number)")! }
    var requiredChecksPassing: Bool { checks.filter(\.required).allSatisfy { $0.status == .passed } }
}

/// A CI check's log, as the log sheet shows it: the job's log, or the check run's output.
struct CheckLog: Equatable {
    var text: String
    /// Only the log's end came back.
    var truncated: Bool
    /// The first line GitHub marked as an error.
    var failedStep: String?
    var url: URL?
}

/// A check log asked for: on its way, there, or refused (expired, or a check from outside GitHub).
enum CheckLogLoad: Equatable {
    case loading
    case loaded(CheckLog)
    case failed(String)
}

/// The check whose log the log sheet shows.
struct CheckLogRequest: Identifiable, Equatable {
    let taskID: String
    let check: String
    var id: String { "\(taskID)/\(check)" }
}

struct CICheck: Identifiable {
    enum Status { case queued, running, passed, failed }

    let name: String
    var status: Status
    var duration: String
    var required = true
    /// Its run on GitHub (the job's page for GitHub Actions); none from an older server, and in the mockup.
    var url: URL? = nil
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
    /// None: nobody set a due date.
    let dueOffset: Int?
    let lead: Person
    let summary: String
    /// Done with: out of the sidebar and the composer, its tasks kept.
    var archived = false
    var prefix = ""
    /// The GitHub team it's for; its members follow it.
    var team: String? = nil
    /// In your sidebar: you lead it, work in it, are on its team, or chose to follow it.
    var following = true
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
    /// For a mention, the comment it's about, so each one in a task is its own row.
    var commentID: String? = nil
    var id: String { commentID.map { "\(kind)-\($0)" } ?? "\(kind)-\(taskID)" }
}

enum Destination: Hashable {
    case inbox, myTasks, dayReport, activity, scratchpad, usage, statistics, needsHand, machines, intake, allGoals
    case goal(String)

    /// The pages that aren't goals, by the names `-destination` takes.
    private static let pages: [String: Destination] = [
        "inbox": .inbox, "mytasks": .myTasks, "report": .dayReport, "activity": .activity, "scratchpad": .scratchpad, "usage": .usage, "statistics": .statistics,
        "hands": .needsHand, "machines": .machines, "requests": .intake, "goals": .allGoals,
    ]

    /// Stored form: `goal:<name>` for a goal, so a goal named "inbox" isn't the Inbox; the page's name otherwise.
    var encoded: String {
        if case .goal(let name) = self { return "goal:\(name)" }
        return Self.pages.first { $0.value == self }!.key
    }

    init?(encoded: String) {
        if encoded.hasPrefix("goal:") {
            self = .goal(String(encoded.dropFirst(5)))
        } else if let page = Self.pages[encoded] {
            self = page
        } else {
            return nil
        }
    }

    /// A `-destination` argument: a page's name, else a goal's.
    init(argument: String) {
        self = Self.pages[argument] ?? .goal(argument)
    }
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
    /// Which of the goal's repos it changes; nil: the goal's default.
    var repo: String? = nil
    var fromNote: UUID? = nil
    var shareable = false
    var tickets: [TicketLink] = []
    var intakeID: String? = nil
    /// Picked by the person (or the page they started from), so Draft with AI keeps it.
    var goalChosen = false
}

enum GoalLayout: String, CaseIterable {
    case overview = "Overview", board = "Board", list = "List", timeline = "Timeline"
}

extension FactoryTask {
    /// The mockup's branch name for it: its ID and the first words of its title.
    var mockBranch: String {
        let slug = title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(3)
            .joined(separator: "-")
        return "\(id.lowercased())-\(slug)"
    }

    /// Whether the plan's step changes (`PlanStep.change`, measured against the version
    /// before) are news: only while a revised plan (v2+) waits on approval. Once it's
    /// approved, the marks are history and the plain current steps are what matter.
    var planChangesFresh: Bool {
        planVersion > 1 && state == .awaitingApproval && plan.contains { $0.change != nil }
    }
}

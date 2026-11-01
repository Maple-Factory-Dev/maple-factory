import Foundation

/// How long a task has taken, from its stage spans (MF-302): the total, time worked, time waiting,
/// and time per stage in pipeline order. Shared by the Mac and iPhone apps.
public struct TaskTimes: Equatable, Sendable {
    public struct Stage: Equatable, Sendable, Identifiable {
        public var stage: Wire.TaskState
        /// All of its time, waits included (ms).
        public var total: UInt64
        /// The waits inside it (ms): queued for a slot, hands, questions. Awaiting approval is all wait.
        public var queued: UInt64 = 0
        public var hand: UInt64 = 0
        public var question: UInt64 = 0
        /// It's the stage the task is in now, so it keeps counting.
        public var open = false
        public var id: String { stage.rawValue }
        public var waiting: UInt64 { stage == .awaitingApproval ? total : queued + hand + question }
    }

    /// From createdAt to the end (or to now while unfinished), in ms.
    public var total: UInt64
    /// Planning, building and reviewing while nothing held it up.
    public var working: UInt64 = 0
    /// Awaiting approval, queued for a slot, hands and questions.
    public var waiting: UInt64 = 0
    /// Drafting and backlog: nobody had asked for it to move yet.
    public var idle: UInt64 = 0
    public var stages: [Stage] = []
    /// Some spans were worked out from its events after the fact.
    public var estimated = false
    /// It had no spans (an older server): only `total` means anything.
    public var hasBreakdown: Bool { !stages.isEmpty }

    public static let order: [Wire.TaskState] = [.drafting, .planning, .awaitingApproval, .backlog, .building, .reviewing]
    static let terminal: [Wire.TaskState] = [.merged, .cancelled, .closed]

    public init(task: Wire.Task, now: Date = Date()) {
        self.init(createdAt: task.createdAt, stages: task.stages, now: now)
    }

    public init(createdAt: UInt64, stages spans: [Wire.StageSpan], now: Date = Date()) {
        let nowMs = UInt64(max(0, now.timeIntervalSince1970 * 1000))
        let end = spans.last.flatMap { Self.terminal.contains($0.stage) ? $0.from : nil } ?? max(nowMs, createdAt)
        total = end > createdAt ? end - createdAt : 0
        var byStage: [Wire.TaskState: Stage] = [:]
        for span in spans {
            if span.inferred == true { estimated = true }
            guard !Self.terminal.contains(span.stage) else { continue }
            let to = span.to ?? max(nowMs, span.from)
            let ms = to > span.from ? to - span.from : 0
            var stage = byStage[span.stage] ?? Stage(stage: span.stage, total: 0)
            stage.total += ms
            if span.to == nil { stage.open = true }
            switch span.wait {
            case .queued?: stage.queued += ms
            case .hand?: stage.hand += ms
            case .question?: stage.question += ms
            default: break
            }
            byStage[span.stage] = stage
        }
        for stage in byStage.values {
            switch stage.stage {
            case .drafting, .backlog: idle += stage.total
            case .awaitingApproval: waiting += stage.total
            default:
                waiting += stage.waiting
                working += stage.total - stage.waiting
            }
        }
        stages = Self.order.compactMap { byStage[$0] }.filter { $0.total >= 1000 || $0.open }
            + byStage.values.filter { !Self.order.contains($0.stage) }.sorted { $0.stage.rawValue < $1.stage.rawValue }
    }

    /// A compact duration: "45s", "12m", "1h 12m", "3d 4h".
    public static func format(_ ms: UInt64) -> String {
        let s = ms / 1000
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h < 24 { return m % 60 == 0 ? "\(h)h" : "\(h)h \(m % 60)m" }
        let d = h / 24
        return h % 24 == 0 ? "\(d)d" : "\(d)d \(h % 24)h"
    }
}

import Foundation

/// What a waiting agent wants permission for, from the runner's `question.permission`.
public struct PermissionPrompt: Equatable, Sendable {
    public let tool: String
    public let summary: String
    public let detail: String?
    public let warning: String?

    public init(tool: String, summary: String, detail: String? = nil, warning: String? = nil) {
        self.tool = tool
        self.summary = summary
        self.detail = detail
        self.warning = warning
    }
}

extension Wire.Activity {
    /// The permission prompt it's stopped at, when it's waiting on one.
    public var permission: PermissionPrompt? {
        guard state == .waiting, case .object(let q)? = question, case .object(let p)? = q["permission"], case .string(let tool)? = p["tool"] else { return nil }
        let text = { (key: String) -> String? in
            if case .string(let s)? = p[key], !s.isEmpty { return s }
            return nil
        }
        return PermissionPrompt(tool: tool, summary: text("summary") ?? tool, detail: text("detail"), warning: text("warning"))
    }
}

extension Wire.Machine {
    /// What a session on one of these machines is doing: nil when the machine isn't known, it doesn't
    /// list that session, or the session has no activity yet.
    public static func activity(machine: String, session: String, in machines: [Wire.Machine]) -> Wire.Activity? {
        machines.first { $0.id == machine }?.sessions.first { $0.session.id == session }?.activity ?? nil
    }
}

extension FeedState {
    /// What the task's worker session is doing, from its machine's live sessions: nil when there's no
    /// worker, its machine isn't known, or the machine doesn't list that session.
    public func workerActivity(for worker: Wire.Worker?) -> Wire.Activity? {
        guard let worker else { return nil }
        return Wire.Machine.activity(machine: worker.machine, session: worker.session, in: machines)
    }
}

import Foundation
import Testing
@testable import MapleKit

/// Reading a waiting agent's `question.permission`, and finding a task's worker session, shared by
/// the Mac's and the iPhone's "waiting on you" cards.
struct PermissionPromptTests {
    private let session = "6f1c2a1e-0000-4000-8000-000000000001"

    private func waiting(_ permission: [String: Wire.JSONValue]) -> Wire.Activity {
        .init(state: .waiting, message: "Claude needs your permission", question: .object(["permission": .object(permission)]), at: 7)
    }

    @Test func toolOnlyUsesTheToolAsItsSummary() {
        #expect(waiting(["tool": .string("Bash")]).permission == PermissionPrompt(tool: "Bash", summary: "Bash", detail: nil, warning: nil))
        // Empty strings and nulls read as missing.
        #expect(waiting(["tool": .string("Bash"), "summary": .string(""), "detail": .null]).permission == PermissionPrompt(tool: "Bash", summary: "Bash"))
    }

    @Test func readsEveryField() {
        let prompt = waiting([
            "tool": .string("Bash"), "summary": .string("npm install @sentry/react-native"),
            "detail": .string("cd app && npm install @sentry/react-native"), "warning": .string("Runs install scripts"),
        ]).permission
        #expect(prompt == PermissionPrompt(tool: "Bash", summary: "npm install @sentry/react-native",
                                           detail: "cd app && npm install @sentry/react-native", warning: "Runs install scripts"))
    }

    @Test func nilUnlessWaitingOnAPermission() {
        let question: Wire.JSONValue = .object(["permission": .object(["tool": .string("Bash")])])
        #expect(Wire.Activity(state: .working, question: question, at: 1).permission == nil)
        #expect(Wire.Activity(state: .waiting, question: .object(["questions": .array([])]), at: 1).permission == nil)
        #expect(Wire.Activity(state: .waiting, question: .object(["permission": .object(["summary": .string("no tool")])]), at: 1).permission == nil)
        #expect(Wire.Activity(state: .waiting, at: 1).permission == nil)
    }

    @Test func feedFindsTheWorkersActivity() {
        let activity = waiting(["tool": .string("Bash")])
        var machine = Wire.Machine(id: "studio", name: "studio", owner: "andrea", online: true, capacity: 4)
        machine.sessions = [
            .init(session: .init(id: "other", agent: "claude", cwd: "/w", startedAt: 1, taskId: "MF-1"), activity: .init(state: .done, at: 1)),
            .init(session: .init(id: session, agent: "claude", cwd: "/w", startedAt: 1, taskId: "MF-45"), activity: activity),
        ]
        var feed = FeedState()
        feed.machines = [machine]
        let worker = Wire.Worker(role: .builder, agent: "claude", machine: "studio", session: session, startedAt: 1)
        #expect(feed.workerActivity(for: worker) == activity)
        #expect(feed.workerActivity(for: nil) == nil)
        var elsewhere = worker
        elsewhere.machine = "laptop"
        #expect(feed.workerActivity(for: elsewhere) == nil)
    }
}

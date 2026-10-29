import Foundation
import Testing
@testable import MapleFactory

/// The task page's "waiting on you" card: finding the worker's session activity, reading its
/// permission prompt, and the message that answers it.
@MainActor struct PermissionPromptTests {
    private let session = "6f1c2a1e-0000-4000-8000-000000000001"
    private let worker = FactoryTask.Worker(role: "builder", agent: "claude", machine: "studio", session: "6f1c2a1e-0000-4000-8000-000000000001")

    private let prompt: Wire.JSONValue = .object(["permission": .object([
        "tool": .string("Bash"), "summary": .string("Run the tests"), "detail": .string("npm test"), "warning": .null,
    ])])

    private func machine(_ id: String, sessions: [(String, Wire.Activity?)]) -> Wire.Machine {
        var m = Wire.Machine(id: id, name: id, owner: "andrea", online: true, capacity: 4)
        m.sessions = sessions.map { .init(session: .init(id: $0.0, agent: "claude", cwd: "/w", startedAt: 1, taskId: "MF-45"), activity: $0.1) }
        return m
    }

    @Test func findsTheWaitingSessionOnTheWorkersMachine() {
        let waiting = Wire.Activity(state: .waiting, message: "Claude needs your permission to use Bash", question: prompt, at: 7)
        let machines = [
            machine("laptop", sessions: [(session, .init(state: .working, at: 1))]),
            machine("studio", sessions: [("6f1c2a1e-0000-4000-8000-000000000002", .init(state: .done, at: 2)), (session, waiting)]),
        ]
        let activity = FactoryClient.workerActivity(for: worker, in: machines)
        #expect(activity == waiting)
        #expect(activity?.permission == PermissionPrompt(tool: "Bash", summary: "Run the tests", detail: "npm test", warning: nil))
    }

    @Test func nilForAMissingOrDifferentSession() {
        #expect(FactoryClient.workerActivity(for: worker, in: []) == nil)
        #expect(FactoryClient.workerActivity(for: nil, in: [machine("studio", sessions: [(session, .init(state: .working, at: 1))])]) == nil)
        let other = [machine("studio", sessions: [("6f1c2a1e-0000-4000-8000-000000000002", .init(state: .waiting, question: prompt, at: 3))])]
        #expect(FactoryClient.workerActivity(for: worker, in: other) == nil)
        // The session without an activity yet.
        #expect(FactoryClient.workerActivity(for: worker, in: [machine("studio", sessions: [(session, nil)])]) == nil)
    }

    @Test func onlyAWaitingPermissionIsAPrompt() {
        #expect(Wire.Activity(state: .working, question: prompt, at: 1).permission == nil)
        #expect(Wire.Activity(state: .waiting, message: "Lunch?", question: .object(["questions": .array([])]), at: 1).permission == nil)
        #expect(Wire.Activity(state: .waiting, at: 1).permission == nil)
    }

    @Test func answerPromptRoundTrips() throws {
        let message = Wire.ClientMessage.taskAnswerPrompt(.init(id: "MF-45", choice: .yes))
        let data = try JSONEncoder().encode(message)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: String]
        #expect(json == ["type": "task.answerPrompt", "id": "MF-45", "choice": "yes"])
        #expect(try JSONDecoder().decode(Wire.ClientMessage.self, from: data) == message)
        let no = try JSONDecoder().decode(Wire.ClientMessage.self, from: Data(#"{"type":"task.answerPrompt","id":"MF-45","choice":"no"}"#.utf8))
        #expect(no == .taskAnswerPrompt(.init(id: "MF-45", choice: .no)))
    }
}

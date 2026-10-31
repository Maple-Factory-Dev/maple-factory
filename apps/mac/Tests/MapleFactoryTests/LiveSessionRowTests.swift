import MapleKit
import Testing
@testable import MapleFactory

/// A Machines row leads with what its session works on: the task's title, else the agent (MF-193).
@MainActor struct LiveSessionRowTests {
    private func live(agent: String = "claude", taskId: String? = nil, message: String? = nil) -> Wire.LiveSession {
        Wire.LiveSession(
            session: .init(id: "s1", agent: agent, cwd: "/Users/me/.worktrees/mf-193", startedAt: 0, taskId: taskId),
            activity: message.map { .init(state: .working, message: $0, at: 1) }
        )
    }

    @Test func aKnownTaskShowsItsTitle() {
        let task = FactoryTask(id: "MF-193", title: "Show each session's task title", state: .building, detail: "")
        let headline = LiveSessionRow.headline(task: task, live: live(taskId: "MF-193", message: "Editing files"))
        #expect(headline.title == "Show each session's task title")
        #expect(headline.detail == "Editing files")
    }

    @Test func anUnknownTaskFallsBackToTheAgent() {
        let headline = LiveSessionRow.headline(task: nil, live: live(taskId: "MF-999"))
        #expect(headline.title == agentTitle("claude"))
    }

    @Test func aShellReadsAsBefore() {
        let headline = LiveSessionRow.headline(task: nil, live: live(agent: "shell"))
        #expect(headline.title == agentTitle("shell"))
        #expect(headline.detail == "Interactive shell")
    }

    @Test func anEmptyTitleFallsBackToTheAgent() {
        let task = FactoryTask(id: "MF-193", title: "  ", state: .building, detail: "")
        #expect(LiveSessionRow.headline(task: task, live: live(taskId: "MF-193")).title == agentTitle("claude"))
    }
}

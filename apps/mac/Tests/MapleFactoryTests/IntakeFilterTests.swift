import Testing
@testable import MapleFactory

/// The Requests list's filter pills (MF-197): each request's bucket comes from its status, and for an
/// accepted one, from the state of the task it became.
@MainActor struct IntakeFilterTests {
    private func request(_ id: String, _ status: IntakeRequest.Status) -> IntakeRequest {
        IntakeRequest(id: id, source: .api, requester: FactoryData.mei, title: id, when: "1m",
                      thread: [], tickets: [], status: status, suggestedGoal: "")
    }

    private func bucket(_ status: IntakeRequest.Status, task: TaskState? = nil) -> IntakeFilter {
        IntakeFilter.bucket(for: request("r", status)) { _ in task }
    }

    @Test func newIsUnanswered() { #expect(bucket(.new) == .unanswered) }
    @Test func clarifyingIsWaiting() { #expect(bucket(.clarifying) == .waiting) }
    @Test func declinedIsDone() { #expect(bucket(.declined) == .done) }

    @Test func acceptedWithARunningTaskIsInFlight() {
        for state in [TaskState.drafting, .planning, .awaitingApproval, .backlog, .building, .reviewing] {
            #expect(bucket(.accepted(taskID: "MF-1"), task: state) == .inFlight)
        }
    }

    @Test func acceptedWithAFinishedTaskIsDone() {
        for state in [TaskState.merged, .cancelled, .closed] {
            #expect(bucket(.accepted(taskID: "MF-1"), task: state) == .done)
        }
    }

    @Test func acceptedWithAnUnknownTaskIsInFlight() {
        #expect(bucket(.accepted(taskID: "MF-404"), task: nil) == .inFlight)
    }

    @Test func seedCounts() {
        let state = AppState()
        let taskState: (String) -> TaskState? = { id in state.tasks.first { $0.id == id }?.state }
        let counts = IntakeFilter.counts(FactoryData.seedIntake, taskState: taskState)
        #expect(counts[.all] == 4)
        #expect(counts[.unanswered] == 2)
        #expect(counts[.waiting] == 1)
        #expect(counts[.inFlight] == 1)
        #expect(counts[.done, default: 0] == 0)
        for filter in IntakeFilter.allCases where filter != .all {
            #expect(IntakeFilter.visible(FactoryData.seedIntake, filter: filter, taskState: taskState).count == counts[filter, default: 0])
        }
    }

    @Test func allKeepsTheOrder() {
        let requests = [request("a", .declined), request("b", .new), request("c", .accepted(taskID: "X")), request("d", .clarifying)]
        #expect(IntakeFilter.visible(requests, filter: .all) { _ in nil }.map(\.id) == ["a", "b", "c", "d"])
        let done = [request("a", .declined), request("b", .accepted(taskID: "M")), request("c", .new), request("d", .declined)]
        #expect(IntakeFilter.visible(done, filter: .done) { _ in .merged }.map(\.id) == ["a", "b", "d"])
    }

    @Test func rawValuesRoundTrip() {
        for filter in IntakeFilter.allCases { #expect(IntakeFilter(rawValue: filter.rawValue) == filter) }
        #expect(IntakeFilter(rawValue: "nonsense") == nil)
    }
}

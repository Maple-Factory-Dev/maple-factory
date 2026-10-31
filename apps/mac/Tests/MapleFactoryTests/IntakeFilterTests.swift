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

    /// R1.1: a task's linked request opened while the remembered filter hides it shows All, not another request.
    @Test func revealingAHiddenSelectionShowsAll() {
        let requests = [request("new", .new), request("ask", .clarifying), request("sso", .accepted(taskID: "T")), request("no", .declined)]
        let running: (String) -> TaskState? = { _ in .building }
        #expect(IntakeFilter.unanswered.revealing("sso", in: requests, taskState: running) == .all)
        #expect(IntakeFilter.waiting.revealing("sso", in: requests, taskState: running) == .all)
        #expect(IntakeFilter.done.revealing("sso", in: requests, taskState: running) == .all)
        #expect(IntakeFilter.inFlight.revealing("sso", in: requests, taskState: running) == .inFlight)
        #expect(IntakeFilter.done.revealing("sso", in: requests) { _ in .merged } == .done)
        #expect(IntakeFilter.unanswered.revealing("new", in: requests, taskState: running) == .unanswered)
        // Nothing selected, or a request that's gone: the filter stays.
        #expect(IntakeFilter.waiting.revealing(nil, in: requests, taskState: running) == .waiting)
        #expect(IntakeFilter.waiting.revealing("gone", in: requests, taskState: running) == .waiting)
    }

    /// R1.2: the request just acted on stays in the list, in place, after it leaves the filter.
    @Test func keepingHoldsTheActedOnRequestInPlace() {
        let requests = [request("a", .new), request("b", .accepted(taskID: "T")), request("c", .new)]
        let running: (String) -> TaskState? = { _ in .building }
        #expect(IntakeFilter.visible(requests, filter: .unanswered, taskState: running).map(\.id) == ["a", "c"])
        #expect(IntakeFilter.visible(requests, filter: .unanswered, keeping: "b", taskState: running).map(\.id) == ["a", "b", "c"])
        #expect(IntakeFilter.visible(requests, filter: .unanswered, keeping: "gone", taskState: running).map(\.id) == ["a", "c"])
    }

    @Test func rawValuesRoundTrip() {
        for filter in IntakeFilter.allCases { #expect(IntakeFilter(rawValue: filter.rawValue) == filter) }
        #expect(IntakeFilter(rawValue: "nonsense") == nil)
    }
}

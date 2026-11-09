import Testing
@testable import MapleKit

/// Intake shared by the Mac and the iPhone (MF-197, MF-278): status parsing, the Requests filter's
/// buckets, and the brief a request's task starts with.
struct IntakeTests {
    private func request(_ id: String, _ status: String, task: String? = nil) -> Wire.IntakeRequest {
        Wire.IntakeRequest(id: id, source: "api", requester: "mei", title: id, at: 0, status: status, taskId: task)
    }

    private func bucket(_ status: String, task: String? = nil, finished: Bool = false) -> IntakeFilter {
        IntakeFilter.bucket(for: request("r", status, task: task)) { _ in finished }
    }

    // MARK: Status

    @Test func parsesEveryStatus() {
        #expect(IntakeStatus(wire: "new", taskID: nil) == .new)
        #expect(IntakeStatus(wire: "clarifying", taskID: nil) == .clarifying)
        #expect(IntakeStatus(wire: "accepted", taskID: "MF-9") == .accepted(taskID: "MF-9"))
        #expect(IntakeStatus(wire: "declined", taskID: nil) == .declined)
    }

    @Test func unknownStatusIsNew() {
        #expect(IntakeStatus(wire: "snoozed", taskID: nil) == .new)
        #expect(IntakeStatus(wire: "", taskID: "MF-1") == .new)
    }

    @Test func titles() {
        #expect(IntakeStatus.accepted(taskID: "MF-9").title == "Became MF-9")
        #expect(IntakeStatus.clarifying.title == "Waiting on requester")
        #expect(IntakeStatus.declined.isSettled && !IntakeStatus.new.isSettled)
    }

    // MARK: Filter

    @Test func newIsUnanswered() { #expect(bucket("new") == .unanswered) }
    @Test func clarifyingIsWaiting() { #expect(bucket("clarifying") == .waiting) }
    @Test func declinedIsDone() { #expect(bucket("declined") == .done) }
    @Test func acceptedWithARunningTaskIsInFlight() { #expect(bucket("accepted", task: "MF-1") == .inFlight) }
    @Test func acceptedWithAFinishedTaskIsDone() { #expect(bucket("accepted", task: "MF-1", finished: true) == .done) }

    @Test func countsMatchVisible() {
        let requests = [request("a", "new"), request("b", "new"), request("c", "clarifying"),
                        request("d", "accepted", task: "MF-1"), request("e", "accepted", task: "MF-2")]
        let finished: (String) -> Bool = { $0 == "MF-2" }
        let counts = IntakeFilter.counts(requests, isFinished: finished)
        #expect(counts[.all] == 5)
        #expect(counts[.unanswered] == 2)
        #expect(counts[.waiting] == 1)
        #expect(counts[.inFlight] == 1)
        #expect(counts[.done] == 1)
        for filter in IntakeFilter.allCases where filter != .all {
            #expect(IntakeFilter.visible(requests, filter: filter, isFinished: finished).count == counts[filter, default: 0])
        }
    }

    @Test func allKeepsTheOrder() {
        let requests = [request("a", "declined"), request("b", "new"), request("c", "accepted", task: "X"), request("d", "clarifying")]
        #expect(IntakeFilter.visible(requests, filter: .all) { _ in false }.map(\.id) == ["a", "b", "c", "d"])
        let done = [request("a", "declined"), request("b", "accepted", task: "M"), request("c", "new"), request("d", "declined")]
        #expect(IntakeFilter.visible(done, filter: .done) { _ in true }.map(\.id) == ["a", "b", "d"])
    }

    /// R1.1: a linked request opened while the remembered filter hides it shows All, not another request.
    @Test func revealingAHiddenSelectionShowsAll() {
        let requests = [request("new", "new"), request("ask", "clarifying"), request("sso", "accepted", task: "T"), request("no", "declined")]
        let running: (String) -> Bool = { _ in false }
        #expect(IntakeFilter.unanswered.revealing("sso", in: requests, isFinished: running) == .all)
        #expect(IntakeFilter.waiting.revealing("sso", in: requests, isFinished: running) == .all)
        #expect(IntakeFilter.done.revealing("sso", in: requests, isFinished: running) == .all)
        #expect(IntakeFilter.inFlight.revealing("sso", in: requests, isFinished: running) == .inFlight)
        #expect(IntakeFilter.done.revealing("sso", in: requests) { _ in true } == .done)
        #expect(IntakeFilter.unanswered.revealing("new", in: requests, isFinished: running) == .unanswered)
        #expect(IntakeFilter.waiting.revealing(nil, in: requests, isFinished: running) == .waiting)
        #expect(IntakeFilter.waiting.revealing("gone", in: requests, isFinished: running) == .waiting)
    }

    /// R1.2: the request just acted on stays in the list, in place, after it leaves the filter.
    @Test func keepingHoldsTheActedOnRequestInPlace() {
        let requests = [request("a", "new"), request("b", "accepted", task: "T"), request("c", "new")]
        let running: (String) -> Bool = { _ in false }
        #expect(IntakeFilter.visible(requests, filter: .unanswered, isFinished: running).map(\.id) == ["a", "c"])
        #expect(IntakeFilter.visible(requests, filter: .unanswered, keeping: "b", isFinished: running).map(\.id) == ["a", "b", "c"])
        #expect(IntakeFilter.visible(requests, filter: .unanswered, keeping: "gone", isFinished: running).map(\.id) == ["a", "c"])
    }

    @Test func rawValuesRoundTrip() {
        for filter in IntakeFilter.allCases { #expect(IntakeFilter(rawValue: filter.rawValue) == filter) }
        #expect(IntakeFilter(rawValue: "nonsense") == nil)
    }

    // MARK: Brief

    @Test func briefQuotesPeopleAndLeavesOutTheBot() {
        let request = Wire.IntakeRequest(
            id: "r", source: "slack", channel: "#maple-requests", requester: "Mei Tanaka", title: "Logout bug", at: 0,
            thread: [
                Wire.IntakeMessage(author: "Mei Tanaka", text: "The app logs people out.", at: 0, bot: false),
                Wire.IntakeMessage(author: "maple", text: "On it.", at: 0, bot: true),
                Wire.IntakeMessage(author: "Dana Ruiz", text: "Me too.", at: 0, bot: false),
            ],
            tickets: [
                Wire.TicketLink(system: "linear", key: "MOB-231", title: "Logged out after backgrounding", status: "Triage", asContext: true),
                Wire.TicketLink(system: "jira", key: "SUP-1", title: "Customer report", status: "Open", asContext: true),
            ],
            status: "new")
        let brief = IntakeBrief.compose(request)
        #expect(brief.hasPrefix("> The app logs people out.\n> — Mei\n>\n> Me too.\n> — Dana"))
        #expect(!brief.contains("On it."))
        #expect(brief.contains("Requested by Mei Tanaka in Slack #maple-requests."))
        #expect(brief.contains("- MOB-231: Logged out after backgrounding\n- SUP-1: Customer report"))
        #expect(brief.contains("## Done when\n- [ ] "))
    }

    @Test func sourceTitles() {
        #expect(IntakeBrief.sourceTitle(request("a", "new")) == "the API")
        var linear = request("b", "new"); linear.source = "linear"
        #expect(IntakeBrief.sourceTitle(linear) == "Linear")
    }
}

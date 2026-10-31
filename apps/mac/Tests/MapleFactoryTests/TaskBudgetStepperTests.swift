import Testing
@testable import MapleFactory

/// The Task budget stepper reaches the server's whole range (Off, 5–1440 minutes), and a value set on the web
/// off its grid moves to the next step either way instead of jumping down.
@MainActor struct TaskBudgetStepperTests {
    private func up(_ m: Int) -> Int { RiskPolicyEditor.stepMinutes(m, up: true) }
    private func down(_ m: Int) -> Int { RiskPolicyEditor.stepMinutes(m, up: false) }

    @Test func reachesFiveMinutesAndTwentyFourHours() {
        #expect(up(0) == 5)
        #expect(up(5) == 10)
        #expect(up(10) == 15)
        #expect(down(5) == 0)
        #expect(up(240) == 300)
        #expect(up(1380) == 1440)
        #expect(up(1440) == 1440)
        #expect(down(1440) == 1380)
    }

    @Test func offGridValuesMoveToTheirNeighbour() {
        #expect(up(600) == 660)
        #expect(down(600) == 540)
        #expect(up(1000) == 1020)
        #expect(down(1000) == 960)
        #expect(up(7) == 10)
        #expect(down(7) == 5)
        #expect(up(62) == 75)
        #expect(down(62) == 60)
    }
}

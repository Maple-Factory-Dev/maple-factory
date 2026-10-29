import Foundation
import Testing
@testable import MapleFactory

/// The sidebar keeps your machines and only those of teammates that lend the team something.
@MainActor struct SidebarMachinesTests {
    private func machine(_ name: String, owner: String, teamSlots: UInt32? = nil, lendIdle: Bool = false) -> Wire.Machine {
        let settings = teamSlots.map { Wire.MachineSettings(capacity: 4, teamSlots: $0, lendIdle: lendIdle, loadCap: 0.8, paused: false) }
        return Wire.Machine(id: name, name: name, owner: owner, online: true, settings: settings, capacity: 4)
    }

    private func shown(_ machines: [Wire.Machine]) -> [String] {
        FactoryClient.sidebarMachines(machines, me: "andrea").map(\.name)
    }

    @Test func mineShown() {
        #expect(shown([machine("studio", owner: "andrea", teamSlots: 0)]) == ["studio"])
    }

    @Test func mineShownWithoutSettings() {
        #expect(shown([machine("laptop", owner: "andrea")]) == ["laptop"])
    }

    @Test func teammateWithNoTeamSlotsHidden() {
        #expect(shown([machine("chris-mini", owner: "chris", teamSlots: 0)]).isEmpty)
    }

    @Test func teammateWithTeamSlotsShown() {
        #expect(shown([machine("chris-mini", owner: "chris", teamSlots: 2)]) == ["chris-mini"])
    }

    @Test func teammateLendingIdleOnlyShown() {
        #expect(shown([machine("sam-air", owner: "sam", teamSlots: 0, lendIdle: true)]) == ["sam-air"])
    }

    @Test func teammateWithoutSettingsHidden() {
        #expect(shown([machine("sam-air", owner: "sam")]).isEmpty)
    }

    @Test func mineFirstThenShared() {
        let machines = [
            machine("chris-mini", owner: "chris", teamSlots: 2),
            machine("sam-air", owner: "sam", teamSlots: 0),
            machine("studio", owner: "andrea", teamSlots: 1),
        ]
        #expect(shown(machines) == ["studio", "chris-mini"])
    }

    @Test func sharedPipsCountTeamSlots() {
        #expect(LivePips.sharedCount(machine("chris-mini", owner: "chris", teamSlots: 2), tasks: []) == 2)
        #expect(LivePips.sharedCount(machine("sam-air", owner: "sam", teamSlots: 1, lendIdle: true), tasks: []) == 4)
        #expect(LivePips.sharedCount(machine("sam-air", owner: "sam"), tasks: []) == 0)
    }
}

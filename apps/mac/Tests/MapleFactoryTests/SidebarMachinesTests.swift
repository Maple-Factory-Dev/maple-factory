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

    // MARK: The update badge

    private func runner(_ version: String, online: Bool = true, update: Wire.RunnerUpdateState? = nil) -> Wire.Machine {
        Wire.Machine(id: "studio", name: "studio", owner: "andrea", online: online, version: version,
                     update: update.map { Wire.MachineUpdate(state: $0, target: "0.41.0", from: version, at: 0) })
    }

    @Test func outdatedShowsTheBadge() {
        #expect(FactoryClient.sidebarUpdateBadge(runner("0.40.0"), latest: "0.41.0") == .available("0.41.0"))
    }

    @Test func currentShowsNoBadge() {
        #expect(FactoryClient.sidebarUpdateBadge(runner("0.41.0"), latest: "0.41.0") == nil)
        #expect(FactoryClient.sidebarUpdateBadge(runner("0.41.0", update: .upToDate), latest: "0.41.0") == nil)
        #expect(FactoryClient.sidebarUpdateBadge(runner("0.41.0", update: .updated), latest: "0.41.0") == nil)
        #expect(FactoryClient.sidebarUpdateBadge(runner("0.40.0"), latest: nil) == nil)
    }

    @Test func busyShowsTheSpinner() {
        for state in [Wire.RunnerUpdateState.checking, .installing, .restarting] {
            #expect(FactoryClient.sidebarUpdateBadge(runner("0.40.0", update: state), latest: "0.41.0") == .updating)
        }
    }

    @Test func offlineShowsNoBadge() {
        #expect(FactoryClient.sidebarUpdateBadge(runner("0.40.0", online: false), latest: "0.41.0") == nil)
        #expect(FactoryClient.sidebarUpdateBadge(runner("0.40.0", online: false, update: .restarting), latest: "0.41.0") == nil)
    }

    @Test func runnerReleasedUpdatesTheLatest() throws {
        let client = FactoryClient()
        let json = #"{"type":"runner.released","runnerLatest":"0.42.0","runnerReleases":[{"version":"0.42.0","notes":"- Faster."},{"version":"0.41.0"}]}"#
        client.apply(try JSONDecoder().decode(Wire.ServerToClient.self, from: Data(json.utf8)))
        #expect(client.runnerLatest == "0.42.0")
        #expect(client.runnerReleases.map(\.version) == ["0.42.0", "0.41.0"])
        #expect(client.runnerOutdated(runner("0.41.0")))
        #expect(client.updatePhase(runner("0.41.0")) == .outdated("0.42.0"))
    }
}

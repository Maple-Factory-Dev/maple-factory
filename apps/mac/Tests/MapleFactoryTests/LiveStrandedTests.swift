import Foundation
import Testing
import MapleKit
@testable import MapleFactory

/// A live task is stranded only when its machine went offline, was removed or was fully paused.
/// Pause New Work lets the task already running finish, so it shows no banner and keeps its LiveStrip.
@MainActor
struct LiveStrandedTests {
    private func building(_ state: TaskState = .building) -> FactoryTask {
        var task = FactoryData.seedTasks[0]
        task.state = state
        task.machine = "mac-1"
        task.hand = nil
        return task
    }

    private func machine(online: Bool = true, paused: Bool = false, pauseNew: Bool? = nil) -> Wire.Machine {
        Wire.Machine(id: "mac-1", name: "Studio", owner: "me", online: online, lastSeen: 42,
                     settings: Wire.MachineSettings(teamSlots: 1, lendIdle: false, loadCap: 1, paused: paused, pauseNew: pauseNew))
    }

    @Test func onlineAndUnpausedIsFine() {
        #expect(AppState.stranded(building(), machine: machine()) == nil)
    }

    @Test func aNewWorkPauseLetsItFinish() {
        #expect(AppState.stranded(building(), machine: machine(paused: true, pauseNew: true)) == nil)
    }

    @Test func aFullPauseStrandsIt() {
        #expect(AppState.stranded(building(), machine: machine(paused: true))?.why == "was paused")
        #expect(AppState.stranded(building(), machine: machine(paused: true, pauseNew: false))?.why == "was paused")
    }

    @Test func offlineStrandsIt() {
        let found = AppState.stranded(building(), machine: machine(online: false))
        #expect(found?.why == "went offline")
        #expect(found?.lastSeen == 42)
    }

    @Test func aMissingMachineWasRemoved() {
        let found = AppState.stranded(building(), machine: nil)
        #expect(found?.why == "was removed")
        #expect(found?.name == "mac-1")
    }

    @Test func aFinishedTaskIsNeverStranded() {
        #expect(AppState.stranded(building(.merged), machine: machine(online: false)) == nil)
    }
}

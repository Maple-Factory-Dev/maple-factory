import Foundation
import Testing
@testable import MapleFactory

/// A machine's runner update as the card shows it, and the releases What's New lists.
@MainActor struct RunnerUpdateTests {
    private let releases: [Wire.RunnerRelease] = [
        .init(version: "0.9.0", publishedAt: "2026-10-01T00:00:00.000Z", notes: "Nine."),
        .init(version: "0.11.0", publishedAt: "2026-10-03T00:00:00.000Z", notes: "Eleven."),
        .init(version: "0.10.0", publishedAt: "2026-10-02T00:00:00.000Z", notes: "Ten."),
        .init(version: "0.12.0-beta.1", publishedAt: "2026-10-04T00:00:00.000Z", notes: "A beta."),
    ]

    private func machine(_ version: String?, online: Bool = true, update: Wire.MachineUpdate? = nil) -> Wire.Machine {
        Wire.Machine(id: "studio", name: "studio", owner: "andrea", online: online, version: version, update: update)
    }

    private func update(_ state: Wire.RunnerUpdateState, target: String? = "0.11.0", from: String? = "0.9.0", message: String? = nil) -> Wire.MachineUpdate {
        Wire.MachineUpdate(state: state, target: target, from: from, message: message, at: 0)
    }

    @Test func releasesAfterAVersionUpToTheLatestNewestFirst() {
        let list = FactoryClient.releases(releases, newerThan: "0.9.0", through: "0.11.0")
        #expect(list.map(\.version) == ["0.11.0", "0.10.0"])
    }

    @Test func versionsCompareAsNumbersNotText() {
        #expect(FactoryClient.version("0.9.0", isOlderThan: "0.10.0"))
        #expect(!FactoryClient.version("0.10.0", isOlderThan: "0.9.0"))
        #expect(!FactoryClient.version("0.10.0", isOlderThan: "0.10.0"))
    }

    @Test func nothingNewerOnTheLatest() {
        #expect(FactoryClient.releases(releases, newerThan: "0.11.0", through: "0.11.0").isEmpty)
    }

    @Test func noLatestListsEverythingNewer() {
        let list = FactoryClient.releases(releases, newerThan: "0.10.0", through: nil)
        #expect(list.map(\.version) == ["0.12.0-beta.1", "0.11.0"])
    }

    @Test func noVersionListsEverythingUpToTheLatest() {
        #expect(FactoryClient.releases(releases, newerThan: nil, through: "0.10.0").map(\.version) == ["0.10.0", "0.9.0"])
    }

    @Test func outdatedWithNothingAsked() {
        #expect(FactoryClient.updatePhase(machine("0.9.0"), latest: "0.11.0") == .outdated("0.11.0"))
        #expect(FactoryClient.updatePhase(machine("0.11.0"), latest: "0.11.0") == .current)
        #expect(FactoryClient.updatePhase(machine("0.9.0"), latest: nil) == .current)
    }

    @Test func progressWhileItRuns() {
        #expect(FactoryClient.updatePhase(machine("0.9.0", update: update(.checking)), latest: "0.11.0") == .checking)
        #expect(FactoryClient.updatePhase(machine("0.9.0", update: update(.installing)), latest: "0.11.0") == .installing("0.11.0"))
        #expect(FactoryClient.updatePhase(machine("0.9.0", update: update(.installing)), latest: "0.11.0").isBusy)
    }

    @Test func offlineWhileRestartingIsRestartingNotOffline() {
        let phase = FactoryClient.updatePhase(machine("0.9.0", online: false, update: update(.restarting)), latest: "0.11.0")
        #expect(phase == .restarting("0.11.0"))
        #expect(phase.isBusy)
        #expect(phase.progressText?.contains("sessions keep running") == true)
    }

    @Test func updatedOnceItsBack() {
        let phase = FactoryClient.updatePhase(machine("0.11.0", update: update(.updated)), latest: "0.11.0")
        #expect(phase == .updated("0.11.0", from: "0.9.0"))
        #expect(!phase.isBusy)
    }

    @Test func failedKeepsItsReason() {
        let phase = FactoryClient.updatePhase(machine("0.9.0", update: update(.failed, message: "checksum mismatch")), latest: "0.11.0")
        #expect(phase == .failed("checksum mismatch", target: "0.11.0"))
        #expect(!phase.isBusy)
    }

    @Test func upToDateUnlessTheFeedSaysOtherwise() {
        #expect(FactoryClient.updatePhase(machine("0.11.0", update: update(.upToDate, target: "0.11.0")), latest: "0.11.0") == .upToDate("0.11.0"))
        #expect(FactoryClient.updatePhase(machine("0.9.0", update: update(.upToDate, target: "0.9.0")), latest: "0.11.0") == .outdated("0.11.0"))
    }

    @Test func aStateFromANewerServerFallsBackToOutdated() {
        #expect(FactoryClient.updatePhase(machine("0.9.0", update: update(.other("paused"))), latest: "0.11.0") == .outdated("0.11.0"))
    }

    @Test func releaseNotesDatesParseWithAndWithoutFractions() {
        #expect(RunnerChangesSheet.date("2026-10-29T22:56:07.917Z") != nil)
        #expect(RunnerChangesSheet.date("2026-10-29T00:00:00Z") != nil)
        #expect(RunnerChangesSheet.date("yesterday") == nil)
    }

    @Test func aReleaseWithNullsDecodes() throws {
        let json = #"{"version":"0.11.0","publishedAt":null,"notes":"x"}"#
        let release = try JSONDecoder().decode(Wire.RunnerRelease.self, from: Data(json.utf8))
        #expect(release.version == "0.11.0" && release.publishedAt == nil)
    }

    @Test func runnerMenuOnlyChecksUnlessANewerReleaseIsKnown() {
        #expect(FactoryClient.runnerAction(machine("0.11.0"), latest: "0.11.0") == .check)
        #expect(FactoryClient.runnerAction(machine("0.12.0"), latest: "0.11.0") == .check)
        #expect(FactoryClient.runnerAction(machine("0.9.0"), latest: nil) == .check)
        #expect(FactoryClient.runnerAction(machine(nil), latest: "0.11.0") == .check)
        #expect(FactoryClient.runnerAction(machine("0.9.0"), latest: "0.11.0") == .update("0.11.0"))
    }

    // MARK: Settings › Runner's Check for Update

    private let studio = Wire.Machine(id: "studio", name: "Studio", owner: "andrea", online: true, version: "0.9.0")
    private let mini = Wire.Machine(id: "mini", name: "Mini", owner: "andrea", online: true, version: "0.9.0")

    private func match(_ text: String, taskId: String? = nil, pending: [String: RunnerCheck]) -> String? {
        FactoryClient.matchRunnerCheck(text: text, taskId: taskId, pending: pending, machines: [studio, mini])
    }

    @Test func upToDateAnswersTheCheck() {
        #expect(match("Studio is on the latest runner (0.11.0).", pending: ["studio": .pending(since: .now)]) == "studio")
    }

    @Test func availableAnswersTheCheck() {
        #expect(match("Runner 0.11.0 is available for Studio.", pending: ["studio": .pending(since: .now)]) == "studio")
    }

    @Test func couldNotReadAnswersTheOldestCheck() {
        let pending: [String: RunnerCheck] = ["studio": .pending(since: .now), "mini": .pending(since: .now.addingTimeInterval(-5))]
        #expect(match("Couldn't read the runner releases.", pending: ["studio": .pending(since: .now)]) == "studio")
        #expect(match("Couldn't read the runner releases.", pending: pending) == "mini")
    }

    @Test func unrelatedToastsLeaveTheCheckPending() {
        let pending: [String: RunnerCheck] = ["studio": .pending(since: .now)]
        #expect(match("ATL-3 merged", pending: pending) == nil)
        #expect(match("Studio is on the latest runner (0.11.0).", taskId: "ATL-3", pending: pending) == nil)
        #expect(match("Runner 0.11.0 is available for Mini.", pending: pending) == nil)
        // Already answered: nothing waiting for it.
        #expect(match("Studio is on the latest runner (0.11.0).", pending: ["studio": .answered("x", at: .now)]) == nil)
    }

    @Test func onlyTheNamedMachineResolves() {
        let pending: [String: RunnerCheck] = ["studio": .pending(since: .now), "mini": .pending(since: .now)]
        #expect(match("Runner 0.11.0 is available for Mini.", pending: pending) == "mini")
        #expect(match("Studio is on the latest runner (0.11.0).", pending: pending) == "studio")
    }
}

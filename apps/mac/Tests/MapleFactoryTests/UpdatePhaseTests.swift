import Testing
@testable import MapleFactory

/// The sidebar update footer's phases: progress, which button each shows, and which clear themselves.
struct UpdatePhaseTests {
    private let all: [UpdatePhase] = [
        .idle, .checking, .available(version: "0.2.0"), .downloading(received: 10, expected: 100),
        .extracting(fraction: 0.5), .readyToRelaunch(version: "0.2.0"), .installing, .upToDate,
        .failed(message: "The feed is down"),
    ]

    @Test func downloadBytesBecomeAFraction() {
        #expect(UpdatePhase.downloading(received: 0, expected: 200).progress == 0)
        #expect(UpdatePhase.downloading(received: 50, expected: 200).progress == 0.25)
        #expect(UpdatePhase.downloading(received: 200, expected: 200).progress == 1)
        #expect(UpdatePhase.downloading(received: 50, expected: 200).detail == "25%")
    }

    @Test func moreBytesThanExpectedStopAtFull() {
        #expect(UpdatePhase.downloading(received: 300, expected: 200).progress == 1)
    }

    @Test func unknownSizeIsIndeterminate() {
        let phase = UpdatePhase.downloading(received: 4096, expected: 0)
        #expect(phase.progress == nil)
        #expect(phase.isBusy)
        #expect(phase.detail == nil)
    }

    @Test func extractionProgressIsClamped() {
        #expect(UpdatePhase.extracting(fraction: 0.4).progress == 0.4)
        #expect(UpdatePhase.extracting(fraction: 1.5).progress == 1)
        #expect(UpdatePhase.extracting(fraction: -1).progress == 0)
    }

    @Test func onlyDownloadAndExtractionHaveProgress() {
        for phase in all {
            switch phase {
            case .downloading, .extracting: #expect(phase.progress != nil)
            default: #expect(phase.progress == nil)
            }
        }
    }

    @Test func eachPhaseHasItsButton() {
        #expect(UpdatePhase.available(version: "0.2.0").action == .install)
        #expect(UpdatePhase.available(version: "0.2.0").buttonLabel == "Update")
        #expect(UpdatePhase.checking.action == .cancel)
        #expect(UpdatePhase.downloading(received: 1, expected: 2).buttonLabel == "Cancel")
        #expect(UpdatePhase.readyToRelaunch(version: "0.2.0").action == .relaunch)
        #expect(UpdatePhase.readyToRelaunch(version: "0.2.0").buttonLabel == "Relaunch")
        #expect(UpdatePhase.failed(message: "x").action == .retry)
        #expect(UpdatePhase.failed(message: "x").buttonLabel == "Retry")
        // Past the point of no return, and nothing to answer, there's no button.
        for phase: UpdatePhase in [.idle, .extracting(fraction: 0.2), .installing, .upToDate] {
            #expect(phase.action == nil)
            #expect(phase.buttonLabel == nil)
        }
    }

    @Test func onlyUpToDateAndFailedClearThemselves() {
        #expect(all.filter(\.clearsItself) == [.upToDate, .failed(message: "The feed is down")])
    }

    @Test func onlyIdleIsHidden() {
        #expect(all.filter { !$0.isVisible } == [.idle])
    }

    @Test func titlesNameTheVersion() {
        #expect(UpdatePhase.available(version: "0.2.0").detail == "Version 0.2.0")
        #expect(UpdatePhase.readyToRelaunch(version: "0.2.0").detail == "Relaunch for 0.2.0")
        #expect(UpdatePhase.failed(message: "The feed is down").detail == "The feed is down")
    }

    @Test func upToDateIsAToastNotAFooterCard() {
        #expect(UpdatePhase.upToDateToast == "You're up to date — thanks for staying up to date")
        #expect(UpdatePhase.upToDate.clearsItself)
        #expect(UpdatePhase.upToDate.action == nil)
        #expect(all.filter { !$0.showsInFooter } == [.idle, .upToDate])
    }
}

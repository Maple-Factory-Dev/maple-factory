import Foundation
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

    /// The busy footer is one line: the ring draws `progress` (nil spins) and `detail` sits by the title.
    @Test func busyFooterGetsItsRingAndPercentage() {
        let known = UpdatePhase.downloading(received: 42, expected: 100)
        #expect(known.isBusy)
        #expect(known.progress == 0.42)
        #expect(known.detail == "42%")

        let unknown = UpdatePhase.downloading(received: 42, expected: 0)
        #expect(unknown.isBusy)
        #expect(unknown.progress == nil)
        #expect(unknown.detail == nil)

        #expect(UpdatePhase.checking.isBusy)
        #expect(UpdatePhase.checking.progress == nil)
        #expect(UpdatePhase.checking.detail == nil)
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

    @Test func releaseNotesLinkShowsWhileAnUpdateIsOnOfferOrReady() {
        #expect(UpdatePhase.available(version: "0.2.0").showsReleaseNotesLink)
        #expect(UpdatePhase.readyToRelaunch(version: "0.2.0").showsReleaseNotesLink)
        #expect(all.filter(\.showsReleaseNotesLink) == [.available(version: "0.2.0"), .readyToRelaunch(version: "0.2.0")])
        for phase: UpdatePhase in [.checking, .downloading(received: 10, expected: 100), .failed(message: "The feed is down"), .upToDate] {
            #expect(!phase.showsReleaseNotesLink)
        }
    }

    @Test func releaseNotesLinkSaysWhatsNew() {
        #expect(UpdatePhase.releaseNotesLinkLabel == "What's new")
    }

    // MARK: The update toast

    @Test func toastShowsFromOfferToRelaunch() {
        for phase in all {
            switch phase {
            case .available, .downloading, .extracting, .installing, .readyToRelaunch: #expect(phase.showsUpdateToast)
            default: #expect(!phase.showsUpdateToast)
            }
        }
    }

    @Test func toastCopy() {
        #expect(UpdatePhase.updateToastTitle(version: "0.2.0") == "Maple Factory 0.2.0 is available")
        #expect(UpdatePhase.updateToastButtonLabel == "Update & Restart")
        #expect(UpdatePhase.downloading(received: 50, expected: 200).updateToastProgressLabel == "Downloading 25%")
        #expect(UpdatePhase.downloading(received: 50, expected: 0).updateToastProgressLabel == "Downloading…")
        #expect(UpdatePhase.extracting(fraction: 0.4).updateToastProgressLabel == "Preparing 40%")
        #expect(UpdatePhase.installing.updateToastProgressLabel == "Installing…")
        #expect(UpdatePhase.readyToRelaunch(version: "0.2.0").updateToastProgressLabel == "Restarting…")
        #expect(UpdatePhase.available(version: "0.2.0").updateToastProgressLabel == nil)
    }

    @MainActor @Test func toastNeedsAnOfferedVersion() {
        #expect(!Updater.showsToast(phase: .downloading(received: 1, expected: 2), offered: nil, dismissed: nil))
        #expect(Updater.showsToast(phase: .downloading(received: 1, expected: 2), offered: "0.2.0", dismissed: nil))
        #expect(!Updater.showsToast(phase: .upToDate, offered: "0.2.0", dismissed: nil))
    }

    @MainActor @Test func dismissingHidesOnlyThatVersion() {
        let offer = UpdatePhase.available(version: "0.2.0")
        #expect(!Updater.showsToast(phase: offer, offered: "0.2.0", dismissed: "0.2.0"))
        #expect(!Updater.showsToast(phase: .readyToRelaunch(version: "0.2.0"), offered: "0.2.0", dismissed: "0.2.0"))
        // A newer release toasts again.
        #expect(Updater.showsToast(phase: .available(version: "0.2.1"), offered: "0.2.1", dismissed: "0.2.0"))
    }

    @MainActor @Test func updateAndRestartRelaunchesOnceReady() {
        let ready = UpdatePhase.readyToRelaunch(version: "0.2.0")
        #expect(Updater.relaunchesAutomatically(at: ready, relaunchWhenReady: true))
        // The footer's Update still waits for its Relaunch.
        #expect(!Updater.relaunchesAutomatically(at: ready, relaunchWhenReady: false))
        for phase in all where phase != ready {
            #expect(!Updater.relaunchesAutomatically(at: phase, relaunchWhenReady: true))
        }
    }

    @Test func whatsNewOpensTheChangelogFromTheInstalledVersion() throws {
        let notes = URL(string: "https://updates.maplefactory.dev/releases/0.1.26/notes.html")
        let url = try #require(SidebarUserDriver.changelogURL(notes: notes, installed: "0.1.22", offered: "0.1.26"))
        #expect(url.absoluteString == "https://updates.maplefactory.dev/changelog.html?from=0.1.22&to=0.1.26")
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains(URLQueryItem(name: "from", value: "0.1.22")))
        #expect(query.contains(URLQueryItem(name: "to", value: "0.1.26")))
    }

    @Test func changelogIsOnTheAppcastsHost() {
        let notes = URL(string: "http://127.0.0.1:8759/releases/0.2.0/notes.html")
        let url = SidebarUserDriver.changelogURL(notes: notes, installed: "0.1.9", offered: "0.2.0")
        #expect(url?.absoluteString == "http://127.0.0.1:8759/changelog.html?from=0.1.9&to=0.2.0")
    }

    @Test func withoutAnInstalledVersionItsTheReleasesOwnNotes() {
        let notes = URL(string: "https://updates.maplefactory.dev/releases/0.2.0/notes.html")
        #expect(SidebarUserDriver.changelogURL(notes: notes, installed: nil, offered: "0.2.0") == notes)
        #expect(SidebarUserDriver.changelogURL(notes: notes, installed: "", offered: "0.2.0") == notes)
        #expect(SidebarUserDriver.changelogURL(notes: nil, installed: "0.1.0", offered: "0.2.0") == nil)
    }

    // MARK: The What's new sheet

    private let page = URL(string: "https://updates.maplefactory.dev/changelog.html?from=0.1.22&to=0.1.26")!

    @Test func releaseNotesStayOnTheChangelog() {
        let stays = [
            "https://updates.maplefactory.dev/changelog.html?from=0.1.22&to=0.1.26",
            "https://updates.maplefactory.dev/changelog.html?", // Show all releases
            "https://updates.maplefactory.dev/changelog.html",
            "https://updates.maplefactory.dev/changelog.html?from=0.1.22&to=0.1.26#v0.1.24",
            "HTTPS://Updates.MapleFactory.dev/changelog.html#top",
        ]
        for link in stays {
            #expect(ReleaseNotesSheet.releaseNotesNavigation(URL(string: link)!, page: page) == .stay, "\(link)")
        }
    }

    @Test func otherWebPagesGoToTheBrowser() {
        let out = [
            "https://updates.maplefactory.dev/releases/0.1.24/notes.html",
            "https://updates.maplefactory.dev/",
            "https://github.com/Maple-Factory-Dev/maple-factory/pull/34",
            "http://updates.maplefactory.dev/changelog.html", // another scheme is another page
            "https://updates.maplefactory.dev:8443/changelog.html",
        ]
        for link in out {
            #expect(ReleaseNotesSheet.releaseNotesNavigation(URL(string: link)!, page: page) == .browser, "\(link)")
        }
    }

    @Test func nonWebLinksGoNowhere() {
        for link in ["mailto:hi@maplefactory.dev", "file:///etc/hosts", "javascript:alert(1)", "about:blank", "maple://task/MF-1"] {
            #expect(ReleaseNotesSheet.releaseNotesNavigation(URL(string: link)!, page: page) == .block, "\(link)")
        }
    }

    @Test func whatsNewHasNoArrowNowItStaysInTheApp() {
        #expect(!UpdatePhase.releaseNotesLinkLabel.contains("↗"))
    }

    @Test func sheetsUpdateButtonFollowsThePhase() {
        #expect(ReleaseNotesSheet.updateButtonLabel(phase: .available(version: "0.2.0")) == "Update & Restart")
        #expect(ReleaseNotesSheet.updateButtonLabel(phase: .readyToRelaunch(version: "0.2.0")) == "Restart")
        for phase: UpdatePhase in [.checking, .downloading(received: 1, expected: 2), .extracting(fraction: 0.5), .installing, .idle] {
            #expect(ReleaseNotesSheet.updateButtonLabel(phase: phase) == nil)
        }
    }
}

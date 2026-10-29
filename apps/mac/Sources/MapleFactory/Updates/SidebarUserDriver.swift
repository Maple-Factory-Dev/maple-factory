import AppKit
import Sparkle

/// Sparkle's UI, as a footer in the sidebar instead of its own windows: each callback becomes an
/// UpdatePhase, and the replies Sparkle hands over wait here until the footer's button answers them.
@MainActor
final class SidebarUserDriver: NSObject, SPUUserDriver {
    private let onPhase: (UpdatePhase) -> Void
    private var phase: UpdatePhase = .idle
    private var version = ""
    private var expected: UInt64 = 0
    private var received: UInt64 = 0

    /// Whatever Sparkle is waiting on: a choice about a found or downloaded update, or a way to cancel.
    private var choice: ((SPUUserUpdateChoice) -> Void)?
    private var cancellation: (() -> Void)?

    /// The release notes page for the update on offer, for the footer to open in the browser.
    private(set) var releaseNotesURL: URL?

    init(show: @escaping (UpdatePhase) -> Void) {
        self.onPhase = show
    }

    private func move(to phase: UpdatePhase) {
        self.phase = phase
        onPhase(phase)
    }

    // MARK: Answers from the footer

    func install() { take(choice)?(.install) }
    func relaunch() { take(choice)?(.install) }
    func cancel() { take(cancellation)?() }

    /// Puts an offered update away until Sparkle's next reminder.
    func dismiss() {
        take(choice)?(.dismiss)
        move(to: .idle)
    }

    private func take<T>(_ block: T?) -> T? {
        choice = nil
        cancellation = nil
        return block
    }

    // MARK: SPUUserDriver

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // SUEnableAutomaticChecks already says yes; this only comes up if a build ever leaves it out.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        move(to: .checking)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        version = appcastItem.displayVersionString
        releaseNotesURL = appcastItem.fullReleaseNotesURL ?? appcastItem.releaseNotesURL ?? appcastItem.infoURL
        cancellation = nil
        choice = reply
        // Already downloaded (or installing in the background) means all that's left is the relaunch.
        move(to: state.stage == .notDownloaded ? .available(version: version) : .readyToRelaunch(version: version))
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        cancellation = nil
        acknowledgement()
        move(to: .upToDate)
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        choice = nil
        cancellation = nil
        acknowledgement()
        move(to: .failed(message: error.localizedDescription))
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        expected = 0
        received = 0
        move(to: .downloading(received: 0, expected: 0))
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expected = expectedContentLength
        received = 0
        move(to: .downloading(received: received, expected: expected))
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        received += length
        move(to: .downloading(received: received, expected: expected))
    }

    func showDownloadDidStartExtractingUpdate() {
        cancellation = nil
        move(to: .extracting(fraction: 0))
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        move(to: .extracting(fraction: progress))
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        choice = reply
        move(to: .readyToRelaunch(version: version))
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        move(to: .installing)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        move(to: .idle)
    }

    func showUpdateInFocus() {}

    func dismissUpdateInstallation() {
        choice = nil
        cancellation = nil
        // "Up to date" and errors stay up for their few seconds; everything else is over.
        if !phase.clearsItself { move(to: .idle) }
    }
}

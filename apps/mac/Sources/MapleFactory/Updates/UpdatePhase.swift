import Foundation

/// Where an update is, as the sidebar footer shows it. Sparkle's callbacks (SidebarUserDriver) move it
/// along; idle hides the footer.
enum UpdatePhase: Equatable {
    case idle
    case checking
    case available(version: String)
    /// Bytes so far, and the download's size, or 0 when the server didn't say.
    case downloading(received: UInt64, expected: UInt64)
    case extracting(fraction: Double)
    case readyToRelaunch(version: String)
    case installing
    case upToDate
    case failed(message: String)

    /// The toast a check you started shows when there's nothing new (the footer stays out of it).
    static let upToDateToast = "You're up to date — thanks for staying up to date"

    /// The link beside the version line that opens the release's notes.
    static let releaseNotesLinkLabel = "What's new"

    /// What the footer's one button does next.
    enum Action: Equatable { case install, cancel, relaunch, retry }

    /// 0…1 for a bar, or nil for none (or an indeterminate one while the size is unknown).
    var progress: Double? {
        switch self {
        case let .downloading(received, expected):
            expected == 0 ? nil : min(1, Double(received) / Double(expected))
        case let .extracting(fraction): min(1, max(0, fraction))
        default: nil
        }
    }

    /// Whether the phase is work in flight, so the footer shows a bar (or spinner) rather than a detail line.
    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .extracting, .installing: true
        default: false
        }
    }

    var isVisible: Bool { self != .idle }

    /// Whether the sidebar footer shows it: up to date is a toast instead.
    var showsInFooter: Bool { isVisible && self != .upToDate }

    /// Phases nobody has to answer, which clear themselves after a few seconds.
    var clearsItself: Bool {
        switch self {
        case .upToDate, .failed: true
        default: false
        }
    }

    /// An × to put it away, for the phases you might not want to act on now.
    var isDismissible: Bool {
        switch self {
        case .available, .failed: true
        default: false
        }
    }

    /// Whether the footer offers the release notes: while an update is on offer or waiting to relaunch.
    var showsReleaseNotesLink: Bool {
        switch self {
        case .available, .readyToRelaunch: true
        default: false
        }
    }

    var title: String {
        switch self {
        case .idle: ""
        case .checking: "Checking…"
        case .available: "Update available"
        case .downloading: "Downloading"
        case .extracting: "Preparing"
        case .readyToRelaunch: "Update ready"
        case .installing: "Installing"
        case .upToDate: "You're up to date"
        case .failed: "Couldn't update"
        }
    }

    var detail: String? {
        switch self {
        case let .available(version): "Version \(version)"
        case let .readyToRelaunch(version): "Relaunch for \(version)"
        case .upToDate: "You have the latest version"
        case let .failed(message): message
        default: progress.map { "\(Int(($0 * 100).rounded(.down)))%" }
        }
    }

    var icon: String {
        switch self {
        case .readyToRelaunch: "arrow.clockwise.circle"
        case .upToDate: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        default: "arrow.down.circle"
        }
    }

    var action: Action? {
        switch self {
        case .available: .install
        case .checking, .downloading: .cancel
        case .readyToRelaunch: .relaunch
        case .failed: .retry
        case .idle, .extracting, .installing, .upToDate: nil
        }
    }

    var buttonLabel: String? {
        switch action {
        case .install: "Update"
        case .cancel: "Cancel"
        case .relaunch: "Relaunch"
        case .retry: "Retry"
        case nil: nil
        }
    }
}

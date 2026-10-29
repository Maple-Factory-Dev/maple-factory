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

    var title: String {
        switch self {
        case .idle: ""
        case .checking: "Checking for updates…"
        case let .available(version): "Maple Factory \(version) is available"
        case .downloading: "Downloading update…"
        case .extracting: "Preparing update…"
        case let .readyToRelaunch(version): "Maple Factory \(version) is ready"
        case .installing: "Installing update…"
        case .upToDate: "Maple Factory is up to date"
        case .failed: "Couldn't update"
        }
    }

    var detail: String? {
        switch self {
        case .available: "Download and install it now"
        case .readyToRelaunch: "Relaunch to finish installing"
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

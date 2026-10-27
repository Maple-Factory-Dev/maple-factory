import Foundation
import Observation
import Sparkle

/// Updates to the app itself, with Sparkle: the appcast at `SUFeedURL` in Info.plist (scripts/bundle.sh
/// writes it), signed with the key `SUPublicEDKey` names. Inert when there's no feed to check, as in
/// `swift run`, so Settings can say so instead of offering a button that does nothing.
/// `MAPLE_APPCAST_URL` points it at another appcast, to try a release before publishing it.
@MainActor
@Observable
final class Updater: NSObject {
    static let shared = Updater()

    /// Stable, or beta too: Sparkle offers items tagged `<sparkle:channel>beta</sparkle:channel>` only
    /// to apps that ask for them, and a beta user still takes a stable release that passes theirs.
    enum Channel: String, CaseIterable {
        case stable, beta
        var title: String { rawValue.capitalized }
    }

    private(set) var available = false
    private(set) var canCheck = false
    private(set) var lastChecked: Date?
    /// What the last check this launch found: a version, or nil for up to date.
    private(set) var result: String??

    var automaticChecks: Bool {
        get { access(keyPath: \.automaticChecks); return updater?.automaticallyChecksForUpdates ?? false }
        set { withMutation(keyPath: \.automaticChecks) { updater?.automaticallyChecksForUpdates = newValue } }
    }

    var channel: Channel {
        get { access(keyPath: \.channel); return Channel(rawValue: UserDefaults.standard.string(forKey: "updateChannel") ?? "") ?? .stable }
        set {
            withMutation(keyPath: \.channel) { UserDefaults.standard.set(newValue.rawValue, forKey: "updateChannel") }
            result = nil // "up to date" was about the other channel
        }
    }

    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }

    @ObservationIgnored private var updater: SPUUpdater?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    func start() {
        guard updater == nil, Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main,
                                 userDriver: SPUStandardUserDriver(hostBundle: .main, delegate: nil), delegate: self)
        do {
            try updater.start()
        } catch {
            NSLog("Maple Factory: the updater didn't start: \(error.localizedDescription)")
            return
        }
        self.updater = updater
        available = true
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.canCheck = updater.canCheckForUpdates }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.lastChecked = updater.lastUpdateCheckDate }
            },
        ]
    }

    func checkForUpdates() { updater?.checkForUpdates() }
}

extension Updater: SPUUpdaterDelegate {
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        MainActor.assumeIsolated { channel == .beta ? ["beta"] : [] }
    }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        ProcessInfo.processInfo.environment["MAPLE_APPCAST_URL"]
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        MainActor.assumeIsolated { result = .some(version) }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        MainActor.assumeIsolated { result = .some(nil) }
    }
}

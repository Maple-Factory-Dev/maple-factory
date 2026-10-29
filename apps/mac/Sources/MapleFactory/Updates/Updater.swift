import Foundation
import Observation
import Sparkle

/// Updates to the app itself, with Sparkle: the appcast at `SUFeedURL` in Info.plist (scripts/bundle.sh
/// writes it), signed with the key `SUPublicEDKey` names. Inert when there's no feed to check, as in
/// `swift run`, so Settings can say so instead of offering a button that does nothing.
/// `MAPLE_APPCAST_URL` points it at another appcast, to try a release before publishing it.
/// Sparkle's own windows are replaced by SidebarUserDriver, which shows where an update is as `phase`
/// for the sidebar footer. `MAPLE_UPDATE_DEMO=1` plays a fake update through it, feed or not.
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
    /// Where an update is right now, for the sidebar footer; idle hides it.
    private(set) var phase: UpdatePhase = .idle

    /// Background checks run hourly. Set on every start too, so installs that saved the old
    /// six-hour interval pick it up.
    static let checkInterval: TimeInterval = 3600

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
    @ObservationIgnored private var driver: SidebarUserDriver?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var clearing: Task<Void, Never>?
    @ObservationIgnored private var demo: Task<Void, Never>?
    @ObservationIgnored private var demoInstall = false

    func start() {
        if ProcessInfo.processInfo.environment["MAPLE_UPDATE_DEMO"] == "1" { return playDemo() }
        guard updater == nil, Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        let driver = SidebarUserDriver { [weak self] in self?.show($0) }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        do {
            try updater.start()
        } catch {
            NSLog("Maple Factory: the updater didn't start: \(error.localizedDescription)")
            return
        }
        updater.updateCheckInterval = Self.checkInterval
        self.updater = updater
        self.driver = driver
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

    /// The release notes for the update on offer, in the browser.
    var releaseNotesURL: URL? { driver?.releaseNotesURL }

    // MARK: The footer's buttons

    func perform(_ action: UpdatePhase.Action) {
        switch action {
        case .install: install()
        case .cancel: cancel()
        case .relaunch: relaunch()
        case .retry: phase = .idle; checkForUpdates()
        }
    }

    func install() {
        if demo != nil { demoInstall = true } else { driver?.install() }
    }

    func cancel() {
        if demo != nil { stopDemo() } else { driver?.cancel() }
    }

    func relaunch() {
        if demo != nil { stopDemo() } else { driver?.relaunch() }
    }

    func dismiss() {
        if demo != nil { stopDemo() } else if phase.clearsItself { phase = .idle } else { driver?.dismiss() }
    }

    private func show(_ phase: UpdatePhase) {
        self.phase = phase
        clearing?.cancel()
        guard phase.clearsItself else { return }
        clearing = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self, self.phase == phase else { return }
            self.phase = .idle
        }
    }

    // MARK: Demo

    /// A fake update through every phase, so the footer can be seen (and recorded) from `swift run`.
    private func playDemo() {
        guard demo == nil else { return }
        demoInstall = false
        demo = Task { [weak self] in
            @MainActor func step(_ phase: UpdatePhase, for seconds: Double = 0) async {
                guard let self, !Task.isCancelled else { return }
                self.show(phase)
                if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) }
            }
            await step(.checking, for: 2)
            await step(.available(version: "0.2.0"))
            // Update moves it on; left alone it goes ahead after a few seconds anyway.
            for _ in 0..<40 {
                if self?.demoInstall ?? true { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            let size: UInt64 = 48_000_000
            for chunk in 0...50 { await step(.downloading(received: size * UInt64(chunk) / 50, expected: size), for: 0.1) }
            for tenth in 0...10 { await step(.extracting(fraction: Double(tenth) / 10), for: 0.08) }
            await step(.installing, for: 2)
            await step(.readyToRelaunch(version: "0.2.0"))
        }
    }

    private func stopDemo() {
        demo?.cancel()
        demo = nil
        show(.idle)
    }
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

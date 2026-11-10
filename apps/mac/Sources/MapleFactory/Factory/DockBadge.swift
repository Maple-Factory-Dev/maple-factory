import AppKit
import Observation

/// The Dock icon's count of what's waiting on you in the open factory: the Inbox's For you items plus the
/// hands raised on your tasks. It draws over whichever icon DockIcon shows (the factory's or Maple's), and
/// clears at zero, when signed out, or with Settings › Notifications' toggle off. Snoozing banners or quiet
/// hours don't hide it: it's the ambient count for when a banner was missed or silenced.
enum DockBadge {
    static let settingKey = "dockShowsBadge"

    /// The Settings › Notifications toggle, on unless it was turned off.
    static var isEnabled: Bool { AppDefaults.object(forKey: settingKey) as? Bool ?? true }

    /// How many things the badge counts: none signed out or with the setting off.
    static func count(inbox: Int, hands: Int, signedIn: Bool, enabled: Bool) -> Int {
        guard signedIn, enabled else { return 0 }
        return max(0, inbox) + max(0, hands)
    }

    /// The Dock's label for `count`: nil (no badge) at zero, "99+" past 99.
    static func label(for count: Int) -> String? {
        guard count > 0 else { return nil }
        return count > 99 ? "99+" : String(count)
    }

    /// The count for the app as it stands.
    @MainActor static func count(state: AppState, client: FactoryClient, enabled: Bool = isEnabled) -> Int {
        count(inbox: state.myInbox.count, hands: state.myHandRaises.count, signedIn: client.isSignedIn, enabled: enabled)
    }

    /// The label the Dock was last given, so an unchanged count doesn't touch the Dock or the trace.
    @MainActor private static var shown: String??

    /// Puts `count` on the Dock icon (nil label: clears it).
    @MainActor static func apply(_ count: Int) {
        let label = label(for: count)
        if shown == .some(label) { return }
        shown = .some(label)
        trace(label)
        // A headless run never shows in the Dock.
        guard !Headless.isOn else { return }
        // Nil in a test run, which has no app.
        NSApp?.dockTile.badgeLabel = label
    }

    /// Keeps the badge current from here on, window or not: re-applies whenever the inbox, your raised
    /// hands or signing in changes. Switching factories reloads both lists, so it's always the open factory's.
    @MainActor static func follow(state: AppState, client: FactoryClient) {
        let now = withObservationTracking {
            DockBadge.count(state: state, client: client)
        } onChange: {
            Task { @MainActor in follow(state: state, client: client) }
        }
        apply(now)
    }

    /// `-dockTrace <dir>`: a `badge N` line (or `badge none`) in `dock.log` each time the badge changes.
    @MainActor private static func trace(_ label: String?) {
        guard let dir = AppDefaults.string(forKey: "dockTrace") else { return }
        let folder = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let line = String(format: "%.3f badge %@\n", Date().timeIntervalSince1970, label ?? "none")
        let log = folder.appending(path: "dock.log")
        if let handle = try? FileHandle(forWritingTo: log) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: log)
        }
    }
}

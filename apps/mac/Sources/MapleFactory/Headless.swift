import AppKit
import Foundation

/// The app's defaults: the real ones, or a headless run's own suite, so a run never signs the real
/// app out or moves its sidebar. Every read and write in the app goes through this, not `.standard`.
/// UserDefaults is thread-safe; it just isn't marked Sendable.
nonisolated(unsafe) let AppDefaults: UserDefaults = Headless.isOn ? Headless.defaults : .standard

/// `-snapshot <dir>` runs the app without a screen: a background app that never activates, its window
/// off screen, rendered to PNGs once the launch flags and `-actions` script have played, and then it quits.
/// `scripts/headless.sh` wraps it. Other flags: `-name` (the PNG's name; defaults to `-destination`),
/// `-appearance light|dark|both`, `-settle 1.5` (seconds before the shot), `-frames N` and `-fps 10`
/// (a frame sequence, for video), `-timeout 60`, `-height 1000`, `-instance` (the defaults suite's name).
enum Headless {
    static let isOn = isOn(arguments: ProcessInfo.processInfo.arguments)
    static let suiteName = suiteName(arguments: ProcessInfo.processInfo.arguments, pid: ProcessInfo.processInfo.processIdentifier)
    /// Wiped at launch, so every run starts signed out with no settings but its arguments.
    nonisolated(unsafe) static let defaults: UserDefaults = {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }()

    /// Empties the suite and deletes its plist, so runs leave nothing in ~/Library/Preferences.
    static func removeSuite(_ name: String = suiteName) {
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        CFPreferencesAppSynchronize(name as CFString)
        let plist = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(name).plist")
        try? FileManager.default.removeItem(at: plist)
    }

    static func isOn(arguments: [String]) -> Bool { value("snapshot", in: arguments) != nil }

    static func suiteName(arguments: [String], pid: Int32) -> String {
        "dev.maplefactory.headless.\(value("instance", in: arguments) ?? String(pid))"
    }

    /// `-key value` from the command line, as the arguments domain reads it.
    static func value(_ key: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "-\(key)"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// Far outside every screen: right of the rightmost one, so nothing of the window is ever seen.
    static func offscreenFrame(size: CGSize, screens: [CGRect]) -> CGRect {
        let right = screens.map(\.maxX).max() ?? 0
        let top = screens.map(\.maxY).max() ?? 0
        return CGRect(origin: CGPoint(x: right + 10_000, y: top + 10_000), size: size)
    }

    /// Takes `<dir>/<name>.png` mid-script (`shot:<name>`); nothing when not headless.
    @MainActor static func shot(_ name: String) async {
        await Snapshotter.shared?.settleThenShoot(name)
    }

    /// Waits until `busy` is false (polling every 50ms), or `timeout` passes; false on timeout.
    @MainActor static func untilIdle(timeout: Duration, _ busy: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while busy() {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    /// Called by AppDelegate: hides the app and starts the driver.
    @MainActor static func start(state: AppState, client: FactoryClient) {
        NSApp.setActivationPolicy(.accessory)
        Snapshotter.shared = Snapshotter(state: state, client: client)
        Snapshotter.shared?.run()
    }

    /// Keeps a window off screen and out of the way: never key, main or in the window menu.
    @MainActor static func hide(_ window: NSWindow) {
        let width = AppDefaults.double(forKey: "width")
        let height = AppDefaults.double(forKey: "height")
        let size = CGSize(width: width > 0 ? width : 1600, height: height > 0 ? height : 1000)
        window.setFrame(offscreenFrame(size: size, screens: NSScreen.screens.map(\.frame)), display: false)
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior.insert([.transient, .ignoresCycle])
        window.resignKey()
        window.resignMain()
    }
}

/// Plays a headless run: waits for the app to be ready and the script to finish, renders, writes
/// done.json and quits.
@MainActor final class Snapshotter {
    static var shared: Snapshotter?

    private let state: AppState
    private let client: FactoryClient
    private let dir: URL
    private var files: [String] = []
    private var errors: [String] = []
    private var finished = false

    init(state: AppState, client: FactoryClient) {
        self.state = state
        self.client = client
        dir = URL(fileURLWithPath: AppDefaults.string(forKey: "snapshot") ?? ".", isDirectory: true)
    }

    private func number(_ key: String, _ fallback: Double) -> Double {
        AppDefaults.object(forKey: key) == nil ? fallback : AppDefaults.double(forKey: key)
    }

    private var window: NSWindow? {
        NSApp.windows.first { $0.contentView != nil && $0.className.contains("AppKitWindow") }
            ?? NSApp.windows.first { $0.contentView != nil && !($0 is NSPanel) }
    }

    func run() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("done.json"))
        let timeout = number("timeout", 60)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(timeout))
            guard !self.finished else { return }
            self.errors.append("timed out after \(Int(timeout))s; timeout.png is where it got to")
            // What was on screen, to see where it got stuck.
            if let image = self.render() { self.write(image, to: "timeout") }
            self.finish()
        }
        Task { @MainActor in
            await self.waitUntilReady()
            let frames = Int(self.number("frames", 0))
            async let recording: Void = self.record(frames: frames)
            while !self.state.scriptFinished { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .seconds(self.number("settle", 1.5)))
            await self.settleThenShoot(self.name)
            await recording
            self.finish()
        }
    }

    private var name: String {
        AppDefaults.string(forKey: "name") ?? AppDefaults.string(forKey: "focus") ?? AppDefaults.string(forKey: "destination") ?? "window"
    }

    /// The window exists, and, signing in to a real factory, its first snapshot has landed.
    private func waitUntilReady() async {
        while window == nil { try? await Task.sleep(for: .milliseconds(100)) }
        let live = client.isSignedIn || AppDefaults.string(forKey: "onboardingURL") != nil
        if live {
            while !(client.hasSnapshot && !state.showOnboarding) { try? await Task.sleep(for: .milliseconds(100)) }
        }
        if let window { Headless.hide(window) }
    }

    /// `-frames N` at `-fps`: frame-0001.png… while the script plays, for scripts/headless.sh video.
    /// At 1x and encoded off the main actor, so the clock, not the PNG encoder, sets the pace.
    private func record(frames: Int) async {
        guard frames > 0 else { return }
        let interval = Duration.seconds(1 / max(number("fps", 10), 1))
        let clock = ContinuousClock()
        var next = clock.now
        var writes: [Task<String?, Never>] = []
        for index in 1...frames {
            guard !finished else { break }
            if let image = render(scale: 1)?.cgImage {
                let url = dir.appendingPathComponent(String(format: "frame-%04d.png", index))
                writes.append(Task.detached { Self.writePNG(image, to: url) ? url.path : nil })
            }
            next += interval
            try? await clock.sleep(until: next)
        }
        for write in writes { if let path = await write.value { files.append(path) } }
    }

    private nonisolated static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    /// Once no action is in flight (a demo's approve holds its button busy for 1.2s before it
    /// applies) and its result has had a moment to animate in, shoots `name`.
    func settleThenShoot(_ name: String) async {
        if !(await Headless.untilIdle(timeout: .seconds(30), { state.isBusy })) {
            errors.append("\(name): still waiting on an action after 30s")
        }
        try? await Task.sleep(for: .milliseconds(500))
        await shoot(name)
    }

    /// `<name>.png`, or `<name>-light.png` and `<name>-dark.png` for `-appearance both`.
    func shoot(_ name: String) async {
        let appearances: [(String, NSAppearance.Name?)] = switch AppDefaults.string(forKey: "appearance") {
        case "both": [("-light", .aqua), ("-dark", .darkAqua)]
        case "light": [("", .aqua)]
        case "dark": [("", .darkAqua)]
        default: [("", nil)]
        }
        for (suffix, appearance) in appearances {
            if let appearance {
                NSApp.appearance = NSAppearance(named: appearance)
                // Off screen, SwiftUI isn't told about the app's appearance; the window's own reaches it.
                window?.appearance = NSAppearance(named: appearance)
                window?.contentView?.needsLayout = true
                window?.contentView?.needsDisplay = true
                // A frame or two for SwiftUI to redraw in the new colors.
                try? await Task.sleep(for: .milliseconds(400))
            }
            if let image = render() { write(image, to: name + suffix) } else { errors.append("\(name)\(suffix): no window to render") }
        }
    }

    /// The window's content as a bitmap: at the screen's scale, or `scale` (1 for video frames).
    private func render(scale: CGFloat? = nil) -> NSBitmapImageRep? {
        guard let window, let view = window.contentView else { return nil }
        if window.frame.minX < (NSScreen.screens.map(\.frame.maxX).max() ?? 0) { Headless.hide(window) }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let rep: NSBitmapImageRep?
        if let scale {
            rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * scale), pixelsHigh: Int(view.bounds.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)
            rep?.size = view.bounds.size
        } else {
            rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        }
        guard let rep else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private func write(_ rep: NSBitmapImageRep, to name: String) {
        let url = dir.appendingPathComponent(name + ".png")
        do {
            guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url)
            files.append(url.path)
        } catch {
            errors.append("\(name).png: \(error.localizedDescription)")
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        let done: [String: Any] = ["files": files, "errors": errors]
        if let data = try? JSONSerialization.data(withJSONObject: done, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("done.json"))
        }
        Headless.removeSuite()
        exit(errors.isEmpty ? 0 : 1)
    }
}

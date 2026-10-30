import AppKit
import SwiftUI
import Foundation

/// The app's defaults: the real ones, or a headless run's own suite, so a run never signs the real
/// app out or moves its sidebar. Every read and write in the app goes through this, not `.standard`.
/// UserDefaults is thread-safe; it just isn't marked Sendable.
nonisolated(unsafe) let AppDefaults: UserDefaults = Headless.isOn ? Headless.defaults : .standard

/// `-snapshot <dir>` runs the app without a screen: a background app that never activates, its window
/// off screen, rendered to PNGs once the launch flags and `-actions` script have played, and then it quits.
/// `scripts/headless.sh` wraps it. Other flags: `-name` (the PNG's name; defaults to `-destination`),
/// `-appearance light|dark|both`, `-settle 1.5` (seconds before the shot), `-frames N` and `-fps 10`
/// (a frame sequence, for video), `-timeout 60`, `-height 1000`, `-instance` (the defaults suite's name),
/// `-keep YES` (leave that suite as the last run left it, to show a setting surviving a relaunch),
/// `-window sheet|settings|settings-sheet` (shoot the main window's sheet, the Settings window, or its sheet, instead).
/// `-snapshot` makes it a demo launch, so a signed-out run shows the mockup; `-mock NO` shows what a
/// fresh install does instead: the connect-to-a-factory screen.
enum Headless {
    static let isOn = isOn(arguments: ProcessInfo.processInfo.arguments)
    static let suiteName = suiteName(arguments: ProcessInfo.processInfo.arguments, pid: ProcessInfo.processInfo.processIdentifier)
    static let keepsSuite = ["yes", "true", "1"].contains(value("keep", in: ProcessInfo.processInfo.arguments)?.lowercased())
    /// Wiped at launch, so every run starts signed out with no settings but its arguments (unless `-keep YES`).
    nonisolated(unsafe) static let defaults: UserDefaults = {
        let defaults = UserDefaults(suiteName: suiteName)!
        if !keepsSuite { defaults.removePersistentDomain(forName: suiteName) }
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

    /// `view` and everything in it, to be drawn again (in a new appearance).
    @MainActor static func markForDisplay(_ view: NSView?) {
        guard let view else { return }
        view.needsDisplay = true
        view.subviews.forEach(markForDisplay)
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

    /// A key pressed in the main window (`key:esc`, `key:cmd+b`), as a key equivalent first, the way AppKit tries it:
    /// the window, then the main menu. Otherwise it's a key down. The window is never key headless, so the event goes
    /// to it directly.
    @MainActor static func press(_ key: String) {
        let (characters, code, modifiers) = keyStroke(key)
        guard let window = Snapshotter.shared?.mainWindow ?? NSApp.mainWindow,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: characters,
                                           charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
        else { return }
        if window.performKeyEquivalent(with: event) { return }
        if !modifiers.isEmpty, NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return }
        NSApp.postEvent(event, atStart: false)
    }

    /// A left click at `point` (window points, from the top left) as far as focus goes (`click:<x>:<y>`): the view
    /// under it that takes focus gets it. A clicked mouse event isn't delivered to a window that's never key.
    @MainActor static func click(at point: CGPoint) {
        guard let window = Snapshotter.shared?.mainWindow ?? NSApp.mainWindow, let content = window.contentView else { return }
        var view = content.hitTest(CGPoint(x: point.x, y: content.bounds.height - point.y))
        while let current = view, !current.acceptsFirstResponder { view = current.superview }
        if let view { window.makeFirstResponder(view) }
        print("headless: click at \(point) focused \(view.map { String(describing: type(of: $0)) } ?? "nothing")")
    }

    /// A trackpad scroll at a point in the main window (`scroll:<x>:<y>:<dx>:<dy>`, points from the top left; `:cmd` holds ⌘),
    /// queued like a real one so local event monitors see it.
    @MainActor static func scroll(at point: CGPoint, by delta: CGPoint, command: Bool) {
        guard let window = Snapshotter.shared?.mainWindow ?? NSApp.mainWindow, let content = window.contentView,
              let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                    wheel1: Int32(delta.y), wheel2: Int32(delta.x), wheel3: 0)
        else { return }
        // CG's screen points run from the top left of the main screen; the window's frame from the bottom left.
        let inWindow = CGPoint(x: point.x, y: content.frame.height - point.y)
        let onScreen = window.convertPoint(toScreen: inWindow)
        let screenHeight = NSScreen.screens.first?.frame.maxY ?? 0
        cgEvent.location = CGPoint(x: onScreen.x, y: screenHeight - onScreen.y)
        cgEvent.flags = command ? .maskCommand : []
        cgEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cgEvent.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        cgEvent.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
        guard let event = NSEvent(cgEvent: cgEvent) else { return }
        // Off screen, the event comes without a window or the point it was meant for: whoever handles it asks here.
        scrollPoint = inWindow
        print("headless: scroll at \(point) by \(delta)\(command ? " with ⌘" : "")")
        NSApp.postEvent(event, atStart: false)
    }

    /// A double-click in the main window (`doubleclick:<x>:<y>`, points from the top left).
    @MainActor static func doubleClick(at point: CGPoint) async {
        for clicks in 1...2 {
            sendMouse(.leftMouseDown, at: point, clicks: clicks)
            sendMouse(.leftMouseUp, at: point, clicks: clicks)
            try? await Task.sleep(for: .milliseconds(60))
        }
        print("headless: double-click at \(point)")
    }

    @MainActor private static func sendMouse(_ type: NSEvent.EventType, at point: CGPoint, clicks: Int) {
        guard let window = Snapshotter.shared?.mainWindow ?? NSApp.mainWindow, let content = window.contentView,
              let event = NSEvent.mouseEvent(with: type, location: CGPoint(x: point.x, y: content.frame.height - point.y), modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1)
        else { return }
        NSApp.postEvent(event, atStart: false)
    }

    /// Where the last `scroll:` was, in the main window's coordinates (from the bottom left).
    @MainActor static var scrollPoint: CGPoint?

    /// `key:` as characters, key code and modifiers: `cmd+b` → ("b", 11, .command). Modifiers are cmd, ctrl, opt
    /// (or alt) and shift, joined by `+`; the last part is the key.
    static func keyStroke(_ key: String) -> (characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags) {
        var parts = key.lowercased().split(separator: "+").map(String.init)
        let name = parts.popLast() ?? ""
        var modifiers: NSEvent.ModifierFlags = []
        for part in parts {
            switch part {
            case "cmd", "command": modifiers.insert(.command)
            case "ctrl", "control": modifiers.insert(.control)
            case "opt", "option", "alt": modifiers.insert(.option)
            case "shift": modifiers.insert(.shift)
            default: break
            }
        }
        let (characters, code): (String, UInt16) = switch name {
        case "esc": ("\u{1b}", 53)
        case "return": ("\r", 36)
        default: (name, keyCodes[name] ?? 0)
        }
        return (characters, code, modifiers)
    }

    /// ANSI key codes for the letters, so a chord reads as the key it is.
    private static let keyCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    ]

    /// The context menu a right-click at `point` (window points, from the top left) brings up, as SwiftUI builds it
    /// (`rightclick:<x>:<y>`): kept, and drawn into the shots, until an item is picked (`menupick:<title>`) or it's
    /// put away (`menupick:none`). Its items are logged.
    @MainActor static func rightClick(at point: CGPoint) {
        guard let window = Snapshotter.shared?.mainWindow ?? NSApp.mainWindow, let content = window.contentView else { return }
        let location = CGPoint(x: point.x, y: content.bounds.height - point.y)
        guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        else { return }
        var view = content.hitTest(location)
        while let current = view {
            if let menu = current.menu(for: event) {
                shownMenu = (menu, point)
                print("headless: context menu at \(point): \(menu.items.map { $0.isSeparatorItem ? "—" : $0.title })")
                return
            }
            view = current.superview
        }
        print("headless: no context menu at \(point)")
    }

    /// Picks the shown context menu's item titled `title`, as a click on it would, and puts the menu away.
    @MainActor static func pickMenuItem(_ title: String) {
        defer { shownMenu = nil }
        guard let menu = shownMenu?.menu, let index = menu.items.firstIndex(where: { $0.title == title }) else { return }
        menu.performActionForItem(at: index)
    }

    @MainActor static var shownMenu: (menu: NSMenu, at: CGPoint)?

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
        // Never Sparkle, but MAPLE_UPDATE_DEMO's fake update can still be recorded.
        Updater.shared.startDemo()
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

    var mainWindow: NSWindow? { window }

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
            // Made now, so the script's actions (`secret:add`, `connector:jira`) reach its views before the shot.
            if AppDefaults.string(forKey: "window")?.hasPrefix("settings") == true {
                self.settingsWindow.orderBack(nil)
            }
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
                // The Settings window and its sheet too, when they're what's shot.
                for w in Set([window, target, target?.sheetParent].compactMap { $0 }) {
                    w.appearance = NSAppearance(named: appearance)
                    w.contentView?.needsLayout = true
                    // AppKit's own controls (a popup, a bordered button) and the window's background
                    // only repaint when everything under the frame view is marked.
                    Headless.markForDisplay(w.contentView?.superview ?? w.contentView)
                }
                // A frame or two for SwiftUI to redraw in the new colors.
                try? await Task.sleep(for: .milliseconds(400))
            }
            if let image = render() { write(image, to: name + suffix) } else { errors.append("\(name)\(suffix): no window to render") }
        }
    }

    /// What `-window` asks for: the main window's sheet (a goal's, say), the Settings window, or the main window.
    private var target: NSWindow? {
        switch AppDefaults.string(forKey: "window") {
        case "sheet": window?.attachedSheet
        case "settings": settingsWindow
        case "settings-sheet": settingsWindow.attachedSheet
        default: window
        }
    }

    /// The Settings window's content in a window of its own: a background app's openSettings opens nothing.
    private lazy var settingsWindow: NSWindow = {
        let settings = NSWindow(contentViewController: NSHostingController(rootView: OrgSettingsView()
            .environment(state).environment(client).defaultAppStorage(AppDefaults)))
        // `-height` makes it taller, to show a long pane whole.
        let height = AppDefaults.double(forKey: "height")
        settings.setContentSize(CGSize(width: OrgSettingsView.size.width, height: max(OrgSettingsView.size.height, height)))
        settings.isExcludedFromWindowsMenu = true
        settings.setFrame(Headless.offscreenFrame(size: settings.frame.size, screens: NSScreen.screens.map(\.frame)), display: false)
        return settings
    }()

    /// The window's content as a bitmap: at the screen's scale, or `scale` (1 for video frames).
    private func render(scale: CGFloat? = nil) -> NSBitmapImageRep? {
        if let window, window.frame.minX < (NSScreen.screens.map(\.frame.maxX).max() ?? 0) { Headless.hide(window) }
        guard let target, let view = target.contentView else { return nil }
        // A sheet moves with the main window; Settings keeps its own size, just off screen.
        if target.frame.minX < (NSScreen.screens.map(\.frame.maxX).max() ?? 0) {
            target.setFrameOrigin(Headless.offscreenFrame(size: target.frame.size, screens: NSScreen.screens.map(\.frame)).origin)
        }
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
        // AppKit's controls draw in the current drawing appearance, not the window's, off screen.
        target.effectiveAppearance.performAsCurrentDrawingAppearance {
            if target !== window {
                // The Settings window's background is the frame's, which the content's bitmap leaves out.
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                NSColor.windowBackgroundColor.setFill()
                NSRect(origin: .zero, size: view.bounds.size).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        if let window, target === window, let sheet = window.attachedSheet, let content = sheet.contentView {
            // Like the window's, the sheet's own appearance is what reaches SwiftUI off screen.
            if sheet.appearance != window.appearance { sheet.appearance = window.appearance }
            (window.appearance ?? NSApp.effectiveAppearance).performAsCurrentDrawingAppearance {
                drawSheet(content, over: rep, in: view.bounds)
            }
        }
        if target === window, let (menu, point) = Headless.shownMenu {
            (window?.appearance ?? NSApp.effectiveAppearance).performAsCurrentDrawingAppearance {
                drawMenu(menu, at: point, over: rep, in: view.bounds)
            }
        }
        return rep
    }

    /// A context menu is its own window too: its items drawn as macOS shows them, its top left at the click.
    private func drawMenu(_ menu: NSMenu, at point: CGPoint, over rep: NSBitmapImageRep, in bounds: CGRect) {
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        let font = NSFont.menuFont(ofSize: 13)
        let rowHeight: CGFloat = 22, separatorHeight: CGFloat = 11, inset: CGFloat = 5
        let items = menu.items.filter { !$0.isHidden }
        let titleWidth = items.map { ($0.title as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let width = max(180, titleWidth + 60)
        let height = items.reduce(inset * 2) { $0 + ($1.isSeparatorItem ? separatorHeight : rowHeight) }
        // Bitmap coordinates have their origin at the bottom left.
        let frame = CGRect(x: point.x, y: bounds.height - point.y - height, width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let shape = NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8)
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 16
        shadow.shadowOffset = CGSize(width: 0, height: -4)
        shadow.shadowColor = .black.withAlphaComponent(0.35)
        shadow.set()
        NSColor.windowBackgroundColor.blended(withFraction: 0.08, of: .labelColor)?.setFill()
        shape.fill()
        NSShadow().set()
        NSColor.separatorColor.setStroke()
        shape.lineWidth = 0.5
        shape.stroke()
        var y = frame.maxY - inset
        for item in items {
            if item.isSeparatorItem {
                y -= separatorHeight
                NSColor.separatorColor.setFill()
                CGRect(x: frame.minX + 10, y: y + separatorHeight / 2, width: width - 20, height: 1).fill()
                continue
            }
            y -= rowHeight
            let color: NSColor = item.isEnabled ? .labelColor : .tertiaryLabelColor
            if let image = item.image {
                // A template symbol, filled with the item's text color.
                let size = image.size.width > 0 ? image.size : CGSize(width: 14, height: 14)
                let tinted = NSImage(size: size, flipped: false) { rect in
                    image.draw(in: rect)
                    color.set()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                let icon = CGRect(x: frame.minX + 12 + (16 - size.width) / 2, y: y + (rowHeight - size.height) / 2, width: size.width, height: size.height)
                tinted.draw(in: icon)
            }
            let text = NSAttributedString(string: item.title, attributes: [.font: font, .foregroundColor: color])
            text.draw(at: CGPoint(x: frame.minX + 34, y: y + (rowHeight - text.size().height) / 2))
            if item.hasSubmenu {
                NSAttributedString(string: "›", attributes: [.font: font, .foregroundColor: color])
                    .draw(at: CGPoint(x: frame.maxX - 18, y: y + (rowHeight - text.size().height) / 2))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A sheet is its own window, so the content view's bitmap lacks it: drawn on top, dimming what's
    /// behind, centered at the top as macOS shows it.
    private func drawSheet(_ sheet: NSView, over rep: NSBitmapImageRep, in bounds: CGRect) {
        sheet.layoutSubtreeIfNeeded()
        sheet.displayIfNeeded()
        guard let sheetRep = sheet.bitmapImageRepForCachingDisplay(in: sheet.bounds), let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        sheet.cacheDisplay(in: sheet.bounds, to: sheetRep)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.black.withAlphaComponent(0.18).setFill()
        bounds.fill(using: .sourceOver)
        let frame = CGRect(x: (bounds.width - sheet.bounds.width) / 2, y: bounds.height - sheet.bounds.height - 28,
                           width: sheet.bounds.width, height: sheet.bounds.height)
        let shape = NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12)
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 24
        shadow.shadowColor = .black.withAlphaComponent(0.3)
        shadow.set()
        NSColor.windowBackgroundColor.setFill()
        shape.fill()
        NSShadow().set()
        shape.addClip()
        sheetRep.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
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
        if !Headless.keepsSuite { Headless.removeSuite() }
        exit(errors.isEmpty ? 0 : 1)
    }
}

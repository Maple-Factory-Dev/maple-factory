import AppKit
import SwiftUI

/// The Dock shows the current factory's icon, on this Mac's say-so (Settings › General): switching
/// factories changes it, and signing out, a factory with no icon, or the setting off puts Maple's back.
/// FactoryClient applies it whenever its icon changes, window or not; the Settings toggle re-applies it.
enum DockIcon {
    static let settingKey = "dockShowsFactoryIcon"

    /// The Settings › General toggle, on unless it was turned off.
    static var isEnabled: Bool { AppDefaults.object(forKey: settingKey) as? Bool ?? true }

    /// What the Dock shows for `icon`: the factory's, or Maple's when there's none or the setting is off.
    @MainActor static func image(for icon: NSImage?, enabled: Bool) -> NSImage {
        guard enabled, let icon else { return MapleIcon.dockImage }
        return rendered(icon)
    }

    /// The image the Dock was last given, nil before the first.
    @MainActor private(set) static var shown: NSImage?

    /// Puts `icon` (nil: Maple's) in the Dock.
    @MainActor static func apply(_ icon: NSImage?, enabled: Bool = isEnabled) {
        let image = image(for: icon, enabled: enabled)
        trace(image, factory: enabled && icon != nil)
        // A headless run never shows in the Dock.
        guard !Headless.isOn else { return }
        shown = image
        // Nil in a test run, which has no app.
        NSApp?.applicationIconImage = image
    }

    /// `-dockTrace <dir>`: every image the Dock is given, as `dock-001.png`… with a line each in `dock.log`
    /// (the time, then factory or maple), so a headless run shows what a real one would put there.
    @MainActor private static var traced = 0

    @MainActor private static func trace(_ image: NSImage, factory: Bool) {
        guard let dir = AppDefaults.string(forKey: "dockTrace") else { return }
        traced += 1
        let folder = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = String(format: "dock-%03d.png", traced)
        if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: folder.appending(path: name))
        }
        let line = String(format: "%.3f %@ %@\n", Date().timeIntervalSince1970, name, factory ? "factory" : "maple")
        let log = folder.appending(path: "dock.log")
        if let handle = try? FileHandle(forWritingTo: log) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: log)
        }
    }

    /// Each factory icon drawn once into the macOS icon shape.
    @MainActor private static var drawn: (source: NSImage, image: NSImage)?

    @MainActor private static func rendered(_ icon: NSImage) -> NSImage {
        if let drawn, drawn.source === icon { return drawn.image }
        let image = MapleIcon.dockImage(icon)
        drawn = (icon, image)
        return image
    }
}

/// Re-applies the Dock icon when Settings › General's toggle changes.
struct DockIconFollower: ViewModifier {
    @Environment(FactoryClient.self) private var client
    @AppStorage(DockIcon.settingKey) private var enabled = true

    func body(content: Content) -> some View {
        content.onChange(of: enabled) { _, on in DockIcon.apply(client.icon, enabled: on) }
    }
}

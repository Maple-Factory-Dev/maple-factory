import AppKit
import SwiftUI

/// The Dock shows the current factory's icon, on this Mac's say-so (Settings › General): switching
/// factories changes it, and signing out, a factory with no icon, or the setting off puts Maple's back.
enum DockIcon {
    static let settingKey = "dockShowsFactoryIcon"

    /// What the Dock shows for `icon` (nil: Maple's).
    @MainActor static func apply(_ icon: NSImage?, enabled: Bool) {
        // A headless run never shows in the Dock.
        guard !Headless.isOn else { return }
        NSApp.applicationIconImage = enabled ? icon.map(rendered) ?? MapleIcon.dockImage : MapleIcon.dockImage
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

/// Keeps the Dock icon on the current factory's, for as long as the window it's on is up.
struct DockIconFollower: ViewModifier {
    @Environment(FactoryClient.self) private var client
    @AppStorage(DockIcon.settingKey) private var enabled = true

    func body(content: Content) -> some View {
        content
            .onAppear { DockIcon.apply(client.icon, enabled: enabled) }
            .onChange(of: client.icon) { _, icon in DockIcon.apply(icon, enabled: enabled) }
            .onChange(of: enabled) { _, on in DockIcon.apply(client.icon, enabled: on) }
    }
}

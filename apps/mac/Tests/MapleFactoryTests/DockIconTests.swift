import AppKit
import Foundation
import Testing
@testable import MapleFactory

/// The Dock's icon: the factory's when it has one and the setting is on, Maple's otherwise, and
/// FactoryClient puts it there itself when a switch loads a factory's cached icon.
@MainActor struct DockIconTests {
    private let icon = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
        NSColor.systemBlue.setFill()
        rect.fill()
        return true
    }

    @Test func aFactoryIconWithTheSettingOnIsTheFactorys() {
        let image = DockIcon.image(for: icon, enabled: true)
        #expect(image !== MapleIcon.dockImage)
        // Drawn into the icon shape once, not on every apply.
        #expect(DockIcon.image(for: icon, enabled: true) === image)
    }

    @Test func noIconIsMaples() {
        #expect(DockIcon.image(for: nil, enabled: true) === MapleIcon.dockImage)
    }

    @Test func theSettingOffIsMaples() {
        #expect(DockIcon.image(for: icon, enabled: false) === MapleIcon.dockImage)
        #expect(DockIcon.image(for: nil, enabled: false) === MapleIcon.dockImage)
    }

    @Test func switchingToAFactoryWithACachedIconPutsItInTheDock() throws {
        let keys = [SavedFactories.defaultsKey, "factoryURL", "factoryOrg", "devFactoryTokens", DockIcon.settingKey]
        let kept = keys.map { AppDefaults.object(forKey: $0) }
        let folder = FileManager.default.temporaryDirectory.appending(path: "DockIconTests-\(UUID().uuidString)")
        defer {
            for (key, value) in zip(keys, kept) { AppDefaults.set(value, forKey: key) }
            try? FileManager.default.removeItem(at: folder)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "icon.png")
        let tiff = try #require(icon.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: file)

        // Nothing port 9 answers: the switch only needs the saved factory and its token.
        let server = try #require(URL(string: "http://localhost:9"))
        let saved = SavedFactory(server: server, org: "acme", name: "acme", lastUsed: Date(), icon: file.path)
        for key in keys { AppDefaults.removeObject(forKey: key) }
        SavedFactories.store([saved])
        AppDefaults.set([server.absoluteString: "token"], forKey: "devFactoryTokens")

        let client = FactoryClient()
        #expect(client.icon == nil)
        #expect(client.switchTo(saved))
        let loaded = try #require(client.icon)
        #expect(DockIcon.shown === DockIcon.image(for: loaded, enabled: true))

        // Signing out of the only factory puts Maple's back.
        client.signOut()
        #expect(client.icon == nil)
        #expect(DockIcon.shown === MapleIcon.dockImage)
    }
}

import AppKit
import Foundation
import Testing
@testable import MapleFactory

/// The Dock's icon: the factory's when it has one and the setting is on, Maple's otherwise, and
/// FactoryClient puts it there itself when a switch loads a factory's cached icon.
/// Serialized: it checks the global DockIcon.shown, which only this suite reads.
@MainActor @Suite(.serialized) struct DockIconTests {
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
        // Per-test suite: a signed-in factory in the shared AppDefaults would reach every FactoryClient()
        // made by suites running alongside. (Tests write a private UserDefaults(suiteName:), never AppDefaults.)
        let suite = "DockIconTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appending(path: "DockIconTests-\(UUID().uuidString)")
        defer {
            defaults.removePersistentDomain(forName: suite)
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
        SavedFactories.store([saved], defaults)
        defaults.set([server.absoluteString: "token"], forKey: "devFactoryTokens")

        let client = FactoryClient(defaults: defaults)
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

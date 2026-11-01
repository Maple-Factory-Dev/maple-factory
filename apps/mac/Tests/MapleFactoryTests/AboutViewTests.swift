import Foundation
import Testing
@testable import MapleFactory

/// The About window: its version line, the bundled afomera.dev logos, the website, and the update status it shares with Settings.
@MainActor struct AboutViewTests {
    @Test func versionLineWithAVersionAndBuild() {
        #expect(AboutView.versionLine(version: "0.2.24", build: "57") == "Version 0.2.24 (build 57)")
    }

    @Test func versionLineDropsABuildThatSaysNothingNew() {
        #expect(AboutView.versionLine(version: "0.2.24", build: nil) == "Version 0.2.24")
        #expect(AboutView.versionLine(version: "0.2.24", build: "0.2.24") == "Version 0.2.24")
    }

    @Test func versionLineWithoutABundleVersionIsDev() {
        #expect(AboutView.versionLine(version: nil, build: "57") == "Version dev")
        #expect(AboutView.versionLine(version: "", build: nil) == "Version dev")
    }

    @Test(arguments: [false, true]) func logoLoadsInFullColourWithTheWholeLogo(dark: Bool) throws {
        let logo = try #require(AboutView.logo(dark: dark))
        #expect(!logo.isTemplate)
        // The full header logo (2051×742), not the old mountain-only crop (1492×370).
        #expect(abs(logo.size.width / logo.size.height - 2051.0 / 742.0) < 0.01)
    }

    @Test func lightLogoHasADarkMountainAndPinkLettering() throws {
        let svg = try Self.svg("afomera-logo-light")
        #expect(svg.contains("#262626"))
        #expect(!svg.lowercased().contains("#ffffff"))
        #expect(!svg.lowercased().contains("\"white\""))
        #expect(svg.contains("#ec4899"))
    }

    @Test func darkLogoHasAWhiteMountainAndPinkLettering() throws {
        let svg = try Self.svg("afomera-logo-dark")
        #expect(svg.contains("#ffffff"))
        #expect(!svg.contains("#262626"))
        #expect(svg.contains("#ec4899"))
    }

    private static func svg(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "svg"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func websiteIsMapleFactoryDev() {
        #expect(AboutView.website.absoluteString == "https://maplefactory.dev")
    }

    @Test func updateStatusReadsAsSettingsDid() {
        #expect(Updater.status(result: .some("0.3.0"), lastChecked: nil) == "0.3.0 is available")
        #expect(Updater.status(result: .some(nil), lastChecked: .now) == "Up to date")
        #expect(Updater.status(result: nil, lastChecked: nil) == "Not checked yet")
        let checked = Date.now.addingTimeInterval(-3600)
        #expect(Updater.status(result: nil, lastChecked: checked)
            == "Checked \(checked.formatted(.relative(presentation: .named)))")
        #expect(Updater.status(result: nil, lastChecked: checked).hasPrefix("Checked "))
    }
}

import Foundation
import Testing
@testable import MapleFactory

/// The About window: its version line, the bundled mountain, the website, and the update status it shares with Settings.
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

    @Test func mountainLoadsFromTheBundleAsATemplate() throws {
        #expect(Bundle.module.url(forResource: "afomera-mountain", withExtension: "svg") != nil)
        let mark = try #require(AboutView.mountain)
        #expect(mark.isTemplate)
        #expect(mark.size.width > mark.size.height)
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

import Foundation
import Testing
@testable import MapleFactory

/// A fresh install is signed out: it connects to a factory rather than showing the design mockup,
/// which only demo and screenshot launches get.
struct FirstLaunchTests {
    private let app = "/Applications/Maple Factory.app/Contents/MacOS/MapleFactory"

    @Test func freshInstallIsNotADemo() {
        #expect(!AppState.showsMock(arguments: [app]))
        // Launch Services' own flags aren't demo flags.
        #expect(!AppState.showsMock(arguments: [app, "-NSDocumentRevisionsDebugMode", "YES"]))
    }

    @Test func demoFlagsShowTheMock() {
        #expect(AppState.showsMock(arguments: [app, "-snapshot", "/tmp/out"]))
        #expect(AppState.showsMock(arguments: [app, "-actions", "shot:inbox"]))
        #expect(AppState.showsMock(arguments: [app, "-destination", "inbox"]))
        #expect(AppState.showsMock(arguments: [app, "-mock", "YES"]))
    }

    @Test func mockFlagDecides() {
        #expect(!AppState.showsMock(arguments: [app, "-snapshot", "/tmp/out", "-mock", "NO"]))
        #expect(AppState.showsMock(arguments: [app, "-mock", "true"]))
    }

    @Test func onboardingSwitchesCountOnlyWhenOn() {
        #expect(AppState.showsMock(arguments: [app, "-onboarding", "YES"]))
        #expect(AppState.showsMock(arguments: [app, "-onboardingFromWorkspace", "1"]))
        #expect(!AppState.showsMock(arguments: [app, "-onboarding", "NO"]))
        #expect(!AppState.showsMock(arguments: [app, "-onboardingFromWorkspace", "NO"]))
        #expect(!AppState.showsMock(arguments: [app, "-onboardingAuto", "false"]))
    }

    @Test func signedOutWithoutDemoOpensOnboarding() {
        #expect(AppState.launchesToOnboarding(signedIn: false, demo: false))
    }

    @Test func signedOutDemoOpensTheMock() {
        #expect(!AppState.launchesToOnboarding(signedIn: false, demo: true))
    }

    @Test func signedInOpensTheWorkspace() {
        #expect(!AppState.launchesToOnboarding(signedIn: true, demo: false))
        #expect(!AppState.launchesToOnboarding(signedIn: true, demo: true))
    }

    @Test func onboardingCantBeCancelledSignedOut() {
        #expect(!AppState.onboardingCancellable(signedIn: false, demo: false))
        #expect(AppState.onboardingCancellable(signedIn: true, demo: false))
        #expect(AppState.onboardingCancellable(signedIn: false, demo: true))
    }

    /// Signing out of the last factory has to go through AppState.signOut, or it lands on the mockup.
    @Test func everySignOutGoesThroughAppState() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MapleFactory")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var callers: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("client.signOut()") { callers.append(url.lastPathComponent) }
        }
        #expect(callers == ["AppState.swift"])
    }
}

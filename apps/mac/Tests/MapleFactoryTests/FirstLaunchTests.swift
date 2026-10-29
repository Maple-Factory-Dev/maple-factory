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
}

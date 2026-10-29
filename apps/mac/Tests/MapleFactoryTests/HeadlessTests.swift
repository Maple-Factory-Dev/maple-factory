import Foundation
import Testing
@testable import MapleFactory

/// `-snapshot` runs: their own defaults, a window nobody sees, and `shot:` in demo scripts.
struct HeadlessTests {
    @Test func onlyOnWithSnapshot() {
        #expect(Headless.isOn(arguments: ["MapleFactory", "-snapshot", "/tmp/out"]))
        #expect(!Headless.isOn(arguments: ["MapleFactory", "-destination", "inbox"]))
        // A flag with nothing after it isn't a directory to write to.
        #expect(!Headless.isOn(arguments: ["MapleFactory", "-snapshot"]))
    }

    @Test func suiteIsPerInstanceOrPid() {
        #expect(Headless.suiteName(arguments: ["-snapshot", "/x"], pid: 42) == "dev.maplefactory.headless.42")
        #expect(Headless.suiteName(arguments: ["-snapshot", "/x", "-instance", "agent"], pid: 42) == "dev.maplefactory.headless.agent")
    }

    /// The test runner isn't headless, so the app's defaults are the real ones there…
    @Test func notHeadlessUsesStandard() {
        #expect(!Headless.isOn)
        #expect(AppDefaults === UserDefaults.standard)
    }

    /// …and a headless run's suite never writes into them.
    @Test func suiteNeverTouchesStandard() {
        let name = Headless.suiteName(arguments: ["-instance", "tests"], pid: 0)
        let suite = UserDefaults(suiteName: name)!
        defer { Headless.removeSuite(name) }
        let key = "headlessTest.factoryURL"
        UserDefaults.standard.removeObject(forKey: key)
        suite.set("http://localhost:9999", forKey: key)
        #expect(suite.string(forKey: key) == "http://localhost:9999")
        #expect(UserDefaults.standard.string(forKey: key) == nil)
    }

    @Test func offscreenFrameMissesEveryScreen() {
        let screens = [CGRect(x: 0, y: 0, width: 1728, height: 1117), CGRect(x: -2560, y: 200, width: 2560, height: 1440),
                       CGRect(x: 1728, y: -400, width: 1920, height: 1080)]
        let frame = Headless.offscreenFrame(size: CGSize(width: 1600, height: 1000), screens: screens)
        #expect(frame.size == CGSize(width: 1600, height: 1000))
        for screen in screens { #expect(!frame.intersects(screen)) }
        #expect(!Headless.offscreenFrame(size: CGSize(width: 800, height: 600), screens: []).intersects(.zero))
    }

    @Test func shotIsADemoAction() {
        #expect(AppState.demoAction("shot:approved") == ["shot", "approved"])
        #expect(AppState.demoAction(" shot:after-merge ") == ["shot", "after-merge"])
        #expect(AppState.demoAction("shot") == nil)
    }
}

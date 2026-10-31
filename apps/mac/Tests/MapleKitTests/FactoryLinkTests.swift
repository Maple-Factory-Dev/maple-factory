import Foundation
import Testing
@testable import MapleKit

/// `maplefactory://` links: which open a task or a session, and which are ignored.
struct FactoryLinkTests {
    private func link(_ string: String) -> FactoryLink? { FactoryLink(url: URL(string: string)!) }

    @Test func taskLink() {
        #expect(link("maplefactory://task/MF-174") == .task("MF-174"))
    }

    @Test func sessionLink() {
        #expect(link("maplefactory://session/m-studio/s-42") == .session(machine: "m-studio", id: "s-42"))
    }

    @Test func trailingSlashIsTheSameLink() {
        #expect(link("maplefactory://task/MF-174/") == .task("MF-174"))
        #expect(link("maplefactory://session/m-studio/s-42/") == .session(machine: "m-studio", id: "s-42"))
    }

    @Test func missingIdIsIgnored() {
        #expect(link("maplefactory://task") == nil)
        #expect(link("maplefactory://task/") == nil)
        #expect(link("maplefactory://session") == nil)
    }

    @Test func sessionNeedsMachineAndId() {
        #expect(link("maplefactory://session/m-studio") == nil)
        #expect(link("maplefactory://session/m-studio/s-42/extra") == nil)
    }

    @Test func taskWithExtraComponentsIsIgnored() {
        #expect(link("maplefactory://task/MF-174/extra") == nil)
    }

    @Test func wrongHostIsIgnored() {
        #expect(link("maplefactory://goal/g-app") == nil)
        #expect(link("maplefactory:///MF-174") == nil)
    }

    @Test func wrongSchemeIsIgnored() {
        #expect(link("https://maplefactory.dev/t/MF-174") == nil)
        #expect(link("https://task/MF-174") == nil)
    }

    @Test func percentEncodedIdsAreDecoded() {
        #expect(link("maplefactory://task/MF%2D174") == .task("MF-174"))
        #expect(link("maplefactory://session/Andrea%27s%20Mac/s%2042") == .session(machine: "Andrea's Mac", id: "s 42"))
    }
}

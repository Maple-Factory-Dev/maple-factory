import Foundation
import Testing
@testable import MapleFactory

/// A screenshot or video proof keeps the runner's upload, so the Done when list can show the real thing (MF-44).
@MainActor struct LiveAdapterProofFile {
    private let key = "/attachments/0b6c1c1e-9a4f-4c1e-9d3a-6f1b2c3d4e5f/login.png"

    @Test func aScreenshotKeepsItsFile() {
        let e = LiveAdapter.evidence(.init(kind: .screenshot, summary: "The login page", file: key, by: "builder", at: 1))
        guard case let .screenshot(caption, file) = e else { Issue.record("not a screenshot: \(e)"); return }
        #expect(caption == "The login page")
        #expect(file == key)
    }

    @Test func aVideoKeepsItsFile() {
        let clip = "/attachments/0b6c1c1e-9a4f-4c1e-9d3a-6f1b2c3d4e5f/flow.mp4"
        let e = LiveAdapter.evidence(.init(kind: .video, summary: "Signing in", file: clip, by: "builder", at: 1))
        guard case let .video(caption, _, file) = e else { Issue.record("not a video: \(e)"); return }
        #expect(caption == "Signing in")
        #expect(file == clip)
    }

    @Test func noFileStaysNil() {
        guard case let .screenshot(_, file) = LiveAdapter.evidence(.init(kind: .screenshot, summary: "s", by: "builder", at: 1)) else { Issue.record("not a screenshot"); return }
        #expect(file == nil)
    }
}

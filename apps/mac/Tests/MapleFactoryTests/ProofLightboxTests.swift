import AppKit
import Testing
@testable import MapleFactory

/// The proof lightbox: opening and closing it, and how big its media gets.
@MainActor
struct ProofLightboxTests {
    @Test func showAndCloseSetAndClearIt() {
        let state = AppState()
        #expect(state.lightbox == nil)
        state.showLightbox(.image(NSImage(size: CGSize(width: 40, height: 30)), caption: "Login page", attachment: "/attachments/a/shot.png"))
        #expect(state.lightbox?.caption == "Login page")
        state.closeLightbox()
        #expect(state.lightbox == nil)

        state.showLightbox(.video(URL(filePath: "/tmp/run.mp4"), poster: nil, caption: "Run", at: 3))
        guard case let .video(_, _, _, at) = state.lightbox else { Issue.record("Not a video"); return }
        #expect(at == 3)
    }

    @Test func tinyImageStaysAtItsOwnSize() {
        #expect(ProofLightboxView.fit(CGSize(width: 320, height: 200), in: CGSize(width: 1200, height: 800)) == CGSize(width: 320, height: 200))
    }

    @Test func hugeImageFitsTheRoomKeepingItsShape() {
        // 2880×1800 into 1200×800: width-bound, so 1200×750.
        #expect(ProofLightboxView.fit(CGSize(width: 2880, height: 1800), in: CGSize(width: 1200, height: 800)) == CGSize(width: 1200, height: 750))
        // A tall one is height-bound.
        #expect(ProofLightboxView.fit(CGSize(width: 1000, height: 4000), in: CGSize(width: 1200, height: 800)) == CGSize(width: 200, height: 800))
    }

    @Test func tinyVideoGrowsToFillTheRoom() {
        #expect(ProofLightboxView.fit(CGSize(width: 320, height: 200), in: CGSize(width: 1200, height: 800), upscale: true) == CGSize(width: 1200, height: 750))
    }

    @Test func emptySizesFitToNothing() {
        #expect(ProofLightboxView.fit(.zero, in: CGSize(width: 1200, height: 800)) == .zero)
        #expect(ProofLightboxView.fit(CGSize(width: 10, height: 10), in: CGSize(width: -20, height: 300)) == .zero)
    }
}

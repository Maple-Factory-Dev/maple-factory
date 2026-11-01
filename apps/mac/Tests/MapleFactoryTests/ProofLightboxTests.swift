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

        state.showLightbox(.video(URL(filePath: "/tmp/run.mp4"), poster: nil, size: CGSize(width: 1920, height: 1080), caption: "Run", at: 3))
        guard case let .video(_, _, size, _, at) = state.lightbox else { Issue.record("Not a video"); return }
        #expect(at == 3)
        #expect(size == CGSize(width: 1920, height: 1080))
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

    @Test func videoGrowsToFillTheRoomButAtMostTwiceItsSize() {
        let up = ProofLightboxView.maxVideoUpscale
        #expect(up == 2)
        // 480×300 into 1200×800 would be 2.5×: it stops at 2×.
        #expect(ProofLightboxView.fit(CGSize(width: 480, height: 300), in: CGSize(width: 1200, height: 800), upscale: up) == CGSize(width: 960, height: 600))
        // 800×500 needs only 1.5× to fill it.
        #expect(ProofLightboxView.fit(CGSize(width: 800, height: 500), in: CGSize(width: 1200, height: 800), upscale: up) == CGSize(width: 1200, height: 750))
        // A 1920×1080 recording in a smaller room shrinks to fit.
        #expect(ProofLightboxView.fit(CGSize(width: 1920, height: 1080), in: CGSize(width: 1200, height: 800), upscale: up) == CGSize(width: 1200, height: 675))
    }

    @Test func inlineWidthIsTheLeastOfColumnCapAndMedia() {
        #expect(ProofViews.maxWidth == 720)
        // A 1920×1080 recording in a wide column: the 720pt cap, well past the old 380.
        #expect(ProofViews.inlineWidth(column: 900, media: CGSize(width: 1920, height: 1080)) == 720)
        // A narrow column wins.
        #expect(ProofViews.inlineWidth(column: 540, media: CGSize(width: 1920, height: 1080)) == 540)
        // A small capture stays at its own width.
        #expect(ProofViews.inlineWidth(column: 900, media: CGSize(width: 400, height: 300)) == 400)
        // Before the size is known, the cap.
        #expect(ProofViews.inlineWidth(column: .infinity, media: nil) == 720)
    }

    @Test func aRotatedRecordingIsPortrait() {
        // A phone's portrait clip: stored 1920×1080 and turned a quarter on playback.
        let upright = ProofViews.upright(CGSize(width: 1920, height: 1080), transform: CGAffineTransform(rotationAngle: .pi / 2))
        #expect(upright == CGSize(width: 1080, height: 1920))
        #expect(ProofViews.aspect(upright) < 1)
        #expect(ProofViews.upright(CGSize(width: 1920, height: 1080), transform: .identity) == CGSize(width: 1920, height: 1080))
        #expect(ProofViews.aspect(nil) == 1.6)
    }

    @Test func thePosterIsTwiceTheShownWidthAtMostAndNeverPastTheRecording() {
        #expect(ProofViews.posterSize(CGSize(width: 1920, height: 1080)) == CGSize(width: 1440, height: 810))
        #expect(ProofViews.posterSize(CGSize(width: 1080, height: 1920)) == CGSize(width: 1080, height: 1920))
        #expect(ProofViews.posterSize(CGSize(width: 640, height: 400)) == CGSize(width: 640, height: 400))
    }

    @Test func emptySizesFitToNothing() {
        #expect(ProofLightboxView.fit(.zero, in: CGSize(width: 1200, height: 800)) == .zero)
        #expect(ProofLightboxView.fit(CGSize(width: 10, height: 10), in: CGSize(width: -20, height: 300)) == .zero)
    }

    @Test func zoomStaysBetweenFittedAndTheCap() {
        let fitted = CGSize(width: 1200, height: 750)
        #expect(ProofLightboxView.clampZoom(0.4, fitted: fitted, pixels: CGSize(width: 2880, height: 1800)) == 1)
        #expect(ProofLightboxView.clampZoom(3, fitted: fitted, pixels: CGSize(width: 2880, height: 1800)) == 3)
        #expect(ProofLightboxView.clampZoom(20, fitted: fitted, pixels: CGSize(width: 2880, height: 1800)) == 8)
        // A screenshot with more pixels than 8× fitted can zoom to its own pixels.
        #expect(ProofLightboxView.clampZoom(20, fitted: CGSize(width: 100, height: 50), pixels: CGSize(width: 1500, height: 750)) == 15)
    }

    @Test func zoomStepsWalkTheStopsUpToTheCap() {
        #expect(ProofLightboxView.zoomStep(from: 1, up: true, cap: 8) == 1.25)
        #expect(ProofLightboxView.zoomStep(from: 2.2, up: true, cap: 8) == 2.5)
        #expect(ProofLightboxView.zoomStep(from: 2.5, up: false, cap: 8) == 2)
        #expect(ProofLightboxView.zoomStep(from: 1, up: false, cap: 8) == 1)
        #expect(ProofLightboxView.zoomStep(from: 8, up: true, cap: 8) == 8)
        #expect(ProofLightboxView.zoomStep(from: 6, up: true, cap: 7) == 7)
    }

    @Test func panStopsAtEachEdge() {
        // 3600×2250 in a 1200×800 room: 1200 of slack each side across, 725 up and down.
        let content = CGSize(width: 3600, height: 2250), room = CGSize(width: 1200, height: 800)
        #expect(ProofLightboxView.clampPan(CGSize(width: 5000, height: 0), content: content, room: room) == CGSize(width: 1200, height: 0))
        #expect(ProofLightboxView.clampPan(CGSize(width: -5000, height: 0), content: content, room: room) == CGSize(width: -1200, height: 0))
        #expect(ProofLightboxView.clampPan(CGSize(width: 0, height: 900), content: content, room: room) == CGSize(width: 0, height: 725))
        #expect(ProofLightboxView.clampPan(CGSize(width: 0, height: -900), content: content, room: room) == CGSize(width: 0, height: -725))
        #expect(ProofLightboxView.clampPan(CGSize(width: 300, height: -200), content: content, room: room) == CGSize(width: 300, height: -200))
    }

    @Test func anImageNoBiggerThanTheRoomStaysCentred() {
        let room = CGSize(width: 1200, height: 800)
        #expect(ProofLightboxView.clampPan(CGSize(width: 300, height: -40), content: CGSize(width: 1200, height: 750), room: room) == .zero)
        // Wider than the room but not taller: it pans across, but stays centred up and down.
        #expect(ProofLightboxView.clampPan(CGSize(width: 300, height: -40), content: CGSize(width: 2400, height: 500), room: room) == CGSize(width: 300, height: 0))
    }

    @Test func anchoredZoomKeepsThePointUnderTheCursor() {
        let anchor = CGPoint(x: 200, y: -120)
        let pan = CGSize(width: 40, height: 10)
        // The image point under the anchor, in fitted coordinates from the image's centre, before and after.
        func underAnchor(zoom: CGFloat, pan: CGSize) -> CGPoint {
            CGPoint(x: (anchor.x - pan.width) / zoom, y: (anchor.y - pan.height) / zoom)
        }
        let zoomed = ProofLightboxView.zoomAnchored(pan, from: 1.5, to: 4, at: anchor)
        let before = underAnchor(zoom: 1.5, pan: pan), after = underAnchor(zoom: 4, pan: zoomed)
        #expect(abs(before.x - after.x) < 0.0001 && abs(before.y - after.y) < 0.0001)
        // Zooming about the centre scales the pan with it.
        #expect(ProofLightboxView.zoomAnchored(CGSize(width: 50, height: -20), from: 2, to: 4, at: .zero) == CGSize(width: 100, height: -40))
    }
}

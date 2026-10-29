import Foundation
import Testing
@testable import MapleFactory

/// FlowLayout never grows past the width it's offered: a long answer chip spilled the
/// "Builder is asking" card under the inspector rail (MF-25).
struct FlowLayoutRows {
    @Test func wideItemsAreClampedToTheWidth() {
        let arranged = FlowLayout.arrange(
            [CGSize(width: 80, height: 26), CGSize(width: 900, height: 52), CGSize(width: 60, height: 26)],
            width: 300, spacing: 6
        )
        #expect(arranged.frames.map(\.width) == [80, 300, 60])
        #expect(arranged.frames.map(\.minY) == [0, 32, 90])
        #expect(arranged.size.width <= 300)
        #expect(arranged.size.height == 116)
    }

    @Test func shortItemsShareARow() {
        let arranged = FlowLayout.arrange(
            [CGSize(width: 100, height: 26), CGSize(width: 100, height: 26), CGSize(width: 100, height: 26)],
            width: 220, spacing: 6
        )
        #expect(arranged.frames.map(\.minX) == [0, 106, 0])
        #expect(arranged.size == CGSize(width: 206, height: 58))
    }

    @Test func reportedWidthNeverPassesTheProposal() {
        for width in [40.0, 120, 333, 720] {
            let sizes = (1...12).map { CGSize(width: Double($0) * 37, height: 26) }
            let arranged = FlowLayout.arrange(sizes, width: width, spacing: 6)
            #expect(arranged.size.width <= width)
            #expect(arranged.frames.allSatisfy { $0.maxX <= width })
        }
    }

    /// The goal legend spaces items 14pt apart but rows only 6pt (MF-40).
    @Test func rowsAreLineSpacingApart() {
        let arranged = FlowLayout.arrange(
            [CGSize(width: 90, height: 14), CGSize(width: 120, height: 14), CGSize(width: 70, height: 14)],
            width: 230, spacing: 14, lineSpacing: 6
        )
        #expect(arranged.frames.map(\.minX) == [0, 104, 0])
        #expect(arranged.frames.map(\.minY) == [0, 0, 20])
        #expect(arranged.size == CGSize(width: 224, height: 34))
        #expect(arranged.frames.allSatisfy { $0.maxX <= 230 })
    }
}

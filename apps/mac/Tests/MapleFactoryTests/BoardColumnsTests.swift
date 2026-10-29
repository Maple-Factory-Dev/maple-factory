import Testing
@testable import MapleFactory

/// The board draws an empty column as a slim rail and a column with cards in full.
struct BoardColumnsTests {
    @Test func emptyColumnIsARail() {
        #expect(BoardColumns.isRail(count: 0))
    }

    @Test func columnWithCardsIsFull() {
        #expect(!BoardColumns.isRail(count: 1))
        #expect(!BoardColumns.isRail(count: 12))
    }
}

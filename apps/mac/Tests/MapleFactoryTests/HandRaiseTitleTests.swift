import Testing
@testable import MapleFactory

/// A hand raised for a reason this build doesn't know (a newer server's) still gets a title.
struct HandRaiseTitleTests {
    @Test func anUnknownHandShowsAsNeedsAttention() {
        #expect(HandRaise.Reason.other.title == "Needs attention")
    }
}

import Testing
@testable import MapleFactory

/// The sidebar's personal goal order: placed goals first in your order, the rest in created order.
struct GoalOrderTests {
    private let created = ["a", "b", "c", "d"]

    private func apply(_ order: [String]?, to goals: [String]? = nil) -> [String] {
        GoalOrder.apply(goals ?? created, order: order) { $0 }
    }

    @Test func noOrderKeepsCreatedOrder() {
        #expect(apply(nil) == created)
        #expect(apply([]) == created)
    }

    @Test func placedGoalsComeFirstInYourOrder() {
        #expect(apply(["d", "b", "a", "c"]) == ["d", "b", "a", "c"])
    }

    @Test func unplacedGoalsFollowInCreatedOrder() {
        #expect(apply(["c"]) == ["c", "a", "b", "d"])
        // A goal created after you placed the others goes below them, and their order holds.
        #expect(apply(["d", "c", "b", "a"], to: created + ["e"]) == ["d", "c", "b", "a", "e"])
    }

    @Test func staleIdsAreIgnored() {
        #expect(apply(["gone", "c", "deleted", "a"]) == ["c", "a", "b", "d"])
    }

    @Test func goalsWithoutAnIdGoBelow() {
        let order = GoalOrder.apply(created, order: ["c", "a"]) { $0 == "b" ? nil : $0 }
        #expect(order == ["c", "a", "b", "d"])
    }

    @Test func movesUpAndDown() {
        #expect(GoalOrder.move("c", to: .up, in: created) == ["a", "c", "b", "d"])
        #expect(GoalOrder.move("b", to: .down, in: created) == ["a", "c", "b", "d"])
        #expect(GoalOrder.move("a", to: .up, in: created) == created)
        #expect(GoalOrder.move("d", to: .down, in: created) == created)
    }

    @Test func movesToTopAndBottom() {
        #expect(GoalOrder.move("d", to: .top, in: created) == ["d", "a", "b", "c"])
        #expect(GoalOrder.move("a", to: .bottom, in: created) == ["b", "c", "d", "a"])
    }

    @Test func movesToADropIndex() {
        // Dropped on a row: lands above it.
        #expect(GoalOrder.move("d", to: .to(0), in: created) == ["d", "a", "b", "c"])
        #expect(GoalOrder.move("a", to: .to(2), in: created) == ["b", "a", "c", "d"])
        #expect(GoalOrder.move("d", to: .to(1), in: created) == ["a", "d", "b", "c"])
        // Dropped below the last row.
        #expect(GoalOrder.move("a", to: .to(4), in: created) == ["b", "c", "d", "a"])
        // On itself, or the row just below it: nowhere to go.
        #expect(GoalOrder.move("b", to: .to(1), in: created) == created)
        #expect(GoalOrder.move("b", to: .to(2), in: created) == created)
        #expect(GoalOrder.move("missing", to: .top, in: created) == created)
    }

    @Test func canMoveIsFalseAtTheEnds() {
        #expect(!GoalOrder.canMove("a", .up, in: created))
        #expect(!GoalOrder.canMove("a", .top, in: created))
        #expect(GoalOrder.canMove("a", .bottom, in: created))
        #expect(!GoalOrder.canMove("d", .down, in: created))
        #expect(!GoalOrder.canMove("d", .bottom, in: created))
    }

    @Test func unfollowedGoalsKeepTheirPlace() {
        // You placed all four, then unfollowed b and moved d to the top of what's left.
        let stored = ["c", "b", "a", "d"]
        let visible = apply(stored, to: ["a", "c", "d"])
        #expect(visible == ["c", "a", "d"])
        let saved = GoalOrder.saving(GoalOrder.move("d", to: .top, in: visible), over: stored)
        #expect(saved == ["d", "c", "a", "b"])
        // Following b again: still placed, so it stays above a goal created since.
        #expect(apply(saved, to: created + ["e"]) == ["d", "c", "a", "b", "e"])
    }
}

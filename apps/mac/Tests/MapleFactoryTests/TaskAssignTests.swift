import Foundation
import Testing
@testable import MapleFactory

/// Reassigning a task's owner (the header chip, the Detail panel's Owner row, the context menu): on the
/// mockup's AppState, assign changes the owner, moves an open hand its old owner held, and logs it; the
/// people picker lists every teammate with a GitHub login, its current owner checked and first, then you,
/// then the rest A–Z, and filters by name or login ignoring case.
@MainActor
struct TaskAssignTests {
    /// You, as the seed identity: pinned here so the suite doesn't read the global `FactoryData.me`.
    private let me = Person(name: "Andrea Fomera", color: .gray, isHuman: true, github: "afomera")

    /// An open task of yours, with a hand raised to you.
    private func state() throws -> (AppState, String) {
        let state = AppState()
        let id = try #require(state.tasks.first { !$0.state.isFinished }?.id)
        state.update(id) { task in
            task.owner = me
            task.hand = HandRaise(reason: .needsInput, since: "now", assignee: me, headline: "Which way?",
                                  explanation: "", tried: [], options: [])
        }
        return (state, id)
    }

    @Test func canReassignOffline() throws {
        let (state, id) = try state()
        #expect(state.canReassign(id))
    }

    @Test func assignChangesTheOwnerMovesTheHandAndLogsIt() throws {
        let (state, id) = try state()
        let before = state.task(id).activity.count
        state.assign(id, to: "excid3")
        let task = state.task(id)
        #expect(task.owner.github == "excid3")
        #expect(task.hand?.assignee.github == "excid3")
        #expect(task.activity.count == before + 1)
        #expect(task.activity.first?.text == "Assigned it to @excid3")
        #expect(state.toast?.text == "Gave \(id) to Chris")
    }

    @Test func takingItBackSaysSo() throws {
        let (state, id) = try state()
        state.assign(id, to: "excid3")
        state.assign(id, to: "afomera")
        #expect(state.task(id).owner.github == "afomera")
        #expect(state.task(id).activity.first?.text == "Took it over")
        #expect(state.toast?.text == "You took over \(id)")
    }

    @Test func assigningTheCurrentOwnerChangesNothing() throws {
        let (state, id) = try state()
        let before = state.task(id).activity.count
        state.assign(id, to: "afomera")
        #expect(state.task(id).activity.count == before)
    }

    private var team: [Person] { [
        me,
        Person(name: "Zoe Park", color: .gray, isHuman: true, github: "zpark"),
        FactoryData.chris,
        Person(name: "Bea Lin", color: .gray, isHuman: true, github: "blin"),
        Person(name: "No Login", color: .gray, isHuman: true),
    ] }

    @Test func pickerChecksTheCurrentOwner() throws {
        let (state, id) = try state()
        var choices = AssignPopover.matches(for: state.task(id), query: "", me: me)
        #expect(Set(choices.map(\.person.github)) == Set(FactoryData.people.compactMap(\.github)))
        #expect(choices.filter(\.current).map(\.person.github) == ["afomera"])
        state.assign(id, to: "excid3")
        choices = AssignPopover.matches(for: state.task(id), query: "", me: me)
        #expect(choices.filter(\.current).map(\.person.github) == ["excid3"])
    }

    @Test func pickerListsTheOwnerThenYouThenEveryoneAToZ() throws {
        let (state, id) = try state()
        state.assign(id, to: "zpark")
        let task = state.task(id)
        #expect(AssignPopover.matches(for: task, query: "", people: team, me: me).map(\.person.github) == ["zpark", "afomera", "blin", "excid3"])
        state.assign(id, to: "afomera")
        #expect(AssignPopover.matches(for: state.task(id), query: "", people: team, me: me).map(\.person.github) == ["afomera", "blin", "excid3", "zpark"])
    }

    @Test func pickerFiltersByNameOrLoginIgnoringCase() throws {
        let (state, id) = try state()
        let task = state.task(id)
        #expect(AssignPopover.matches(for: task, query: "chr", people: team, me: me).map(\.person.github) == ["excid3"])
        #expect(AssignPopover.matches(for: task, query: "CHR", people: team, me: me).map(\.person.github) == ["excid3"])
        #expect(AssignPopover.matches(for: task, query: "EXCID", people: team, me: me).map(\.person.github) == ["excid3"])
        #expect(AssignPopover.matches(for: task, query: " park ", people: team, me: me).map(\.person.github) == ["zpark"])
    }

    @Test func pickerIsEmptyWhenNoOneMatches() throws {
        let (state, id) = try state()
        #expect(AssignPopover.matches(for: state.task(id), query: "xyzzy", people: team, me: me).isEmpty)
    }

    @Test func withoutReassigningThePickerIsOnlyYou() throws {
        let (state, id) = try state()
        state.assign(id, to: "zpark")
        #expect(AssignPopover.matches(for: state.task(id), query: "", everyone: false, people: team, me: me).map(\.person.github) == ["afomera"])
    }
}

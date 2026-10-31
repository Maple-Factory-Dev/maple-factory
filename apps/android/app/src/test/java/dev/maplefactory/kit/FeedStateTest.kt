package dev.maplefactory.kit

import dev.maplefactory.wire.ServerToClient
import dev.maplefactory.wire.TaskState
import dev.maplefactory.wire.WireJson
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The store keeps a FeedState: a snapshot, then deltas, decoded from the feed's JSON. Mirrors FeedStateTests.swift. */
class FeedStateTest {
    private fun decode(json: String): ServerToClient = WireJson.decodeFromString(ServerToClient.serializer(), json)

    private fun FeedState.on(json: String): FeedState = apply(decode(json)).state

    private fun task(id: String, state: String, extra: String = "") = """
        {"id":"$id","goal":"g1","title":"Task $id","state":"$state","owner":"andrea","brief":"",
         "createdAt":1,"updatedAt":2,"planVersion":2,"approvalsNeeded":1,"reviewsNeeded":1,
         "shareable":false,"agent":"claude"$extra}
    """

    private val snapshot = """
        {"type":"snapshot","org":"acme","protocolVersion":1,
         "me":{"login":"andrea","role":"admin"},
         "members":[{"login":"andrea","role":"admin"},{"login":"sam","role":"member"}],
         "machines":[{"id":"m1","name":"Studio","owner":"andrea","online":true,"version":"0.2.0"}],
         "goals":[{"id":"g1","name":"Maple","prefix":"MF","color":"#D24E26","summary":"","lead":"sam"}],
         "tasks":[${task("MF-1", "awaitingApproval")},${task("MF-2", "building")}],
         "policy":{"maxFiles":20,"maxLines":400,"areas":[],"planApprovals":{},"finalReviews":{},"autoMerge":{}},
         "follows":[{"goal":"g1","following":false}],
         "runnerLatest":"0.10.1"}
    """

    @Test fun snapshotFillsTheState() {
        val applied = FeedState().apply(decode(snapshot))
        assertNull(applied.notice)
        val state = applied.state
        assertTrue(state.hasSnapshot)
        assertEquals("acme", state.org)
        assertEquals("andrea", state.me?.login)
        assertEquals(listOf("MF-1", "MF-2"), state.tasks.map { it.id })
        assertEquals("MF", state.goals.first().prefix)
        assertEquals("Studio", state.machines.first().name)
        assertEquals(false, state.follows["g1"])
        assertFalse(state.following(state.goals[0]))
        assertTrue(state.runnerOutdated(state.machines[0]))
    }

    @Test fun taskDeltaReplacesOrInserts() {
        var state = FeedState().on(snapshot)

        state = state.on("""{"type":"task.updated","task":${task("MF-1", "building")}}""")
        assertEquals(2, state.tasks.size)
        assertEquals(TaskState.Building, state.task("MF-1")?.state)

        state = state.on("""{"type":"task.updated","task":${task("MF-3", "drafting")}}""")
        assertEquals(listOf("MF-3", "MF-1", "MF-2"), state.tasks.map { it.id })

        state = state.on("""{"type":"task.removed","id":"MF-2"}""")
        assertEquals(listOf("MF-3", "MF-1"), state.tasks.map { it.id })
    }

    @Test fun otherDeltas() {
        var state = FeedState().on(snapshot)
        state = state.on("""{"type":"goal.updated","goal":{"id":"g2","name":"Docs","prefix":"DOC","color":"#2F6FEB","summary":"","lead":"andrea"}}""")
        assertEquals(listOf("g1", "g2"), state.goals.map { it.id })
        assertTrue(state.following(state.goal("g2")!!))
        state = state.on("""{"type":"machine.removed","id":"m1"}""")
        assertTrue(state.machines.isEmpty())
        state = state.on("""{"type":"follows.updated","follows":[{"goal":"g1","following":true}]}""")
        assertTrue(state.following(state.goal("g1")!!))
        state = state.on("""{"type":"name.updated","name":"Acme Inc"}""")
        assertEquals("Acme Inc", state.name)
        state = state.on("""{"type":"members.updated","members":[{"login":"andrea","name":"Andrea","role":"admin"}]}""")
        assertEquals("Andrea", state.me?.name)
    }

    @Test fun inboxGroupsWhatWaitsOnYou() {
        var state = FeedState().on(snapshot)
        assertEquals(listOf(InboxEntry.Kind.Approval), state.inbox("andrea").map { it.kind })
        // An approval is yours to give, whoever owns the task.
        assertEquals(listOf("sam"), state.inbox("sam").map { it.assignee })

        // Once you've approved it, it leaves your inbox.
        state = state.on("""{"type":"task.updated","task":${task("MF-1", "awaitingApproval", ""","approvals":["andrea"]""")}}""")
        assertTrue(state.inbox("andrea").isEmpty())

        val hand = ""","hand":{"reason":"needsInput","summary":"Which database?","at":9,"assignee":"andrea"}"""
        val mention = ""","comments":[{"id":"c1","author":"sam","text":"@andrea look","at":5,"mentions":["andrea"]}]"""
        state = state.on("""{"type":"task.updated","task":${task("MF-2", "building", hand + mention)}}""")
        assertEquals(listOf(InboxEntry.Kind.Hand, InboxEntry.Kind.Mention), state.inbox("andrea").map { it.kind })
    }

    /** Like the Mac inbox: a task in review waits on you only once its automatic review passed. */
    @Test fun reviewWaitsForTheAutomaticReview() {
        var state = FeedState().on(snapshot)
        state = state.on("""{"type":"task.removed","id":"MF-1"}""")
        state = state.on("""{"type":"task.updated","task":${task("MF-2", "reviewing")}}""")
        assertTrue(state.inbox("andrea").isEmpty())

        fun review(verdict: String) =
            ""","autoReview":{"maxRounds":3,"rounds":[{"number":1,"verdict":"$verdict","found":0,"at":4}],"summary":"","ask":[],"proofs":[],"findings":[]}"""
        state = state.on("""{"type":"task.updated","task":${task("MF-2", "reviewing", review("changesRequested"))}}""")
        assertTrue(state.inbox("andrea").isEmpty())

        state = state.on("""{"type":"task.updated","task":${task("MF-2", "reviewing", review("passed"))}}""")
        val entries = state.inbox("andrea")
        assertEquals(listOf(InboxEntry.Kind.Review), entries.map { it.kind })
        assertEquals("Passed automatic review; ready for yours", entries.first().message)
        // Once you've approved the changes, it leaves your inbox.
        state = state.on("""{"type":"task.updated","task":${task("MF-2", "reviewing", review("passed") + ""","reviews":["andrea"]""")}}""")
        assertTrue(state.inbox("andrea").isEmpty())
    }

    @Test fun failingChecksWaitOnTheOwner() {
        val checks = ""","pr":{"number":4,"state":"open","branch":"b","base":"main","checks":[{"name":"test","status":"failed","required":true}]}"""
        val state = FeedState().on(snapshot).on("""{"type":"task.updated","task":${task("MF-2", "reviewing", checks)}}""")
        val failing = state.inbox("sam").filter { it.kind == InboxEntry.Kind.Failing }
        assertEquals(listOf("andrea"), failing.map { it.assignee })
    }

    @Test fun notices() {
        val state = FeedState()
        assertEquals(FeedState.Notice.Toast("Merged", "MF-1"), state.apply(decode("""{"type":"toast","text":"Merged","taskId":"MF-1"}""")).notice)
        assertEquals(FeedState.Notice.Error("Nope"), state.apply(decode("""{"type":"error","message":"Nope"}""")).notice)
    }

    @Test fun versions() {
        assertTrue(FeedState.isOlder("0.2.0", "0.10.1"))
        assertFalse(FeedState.isOlder("0.10.1", "0.10.1"))
        assertFalse(FeedState.isOlder("1.0.0-beta", "1.0"))
    }
}

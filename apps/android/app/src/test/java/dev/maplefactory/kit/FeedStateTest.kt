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

    // The snapshot window (MF-212): the snapshot leaves out tasks finished over 14 days ago.

    private val windowed = snapshot.replace(""""runnerLatest":"0.10.1"}""", """"runnerLatest":"0.10.1","tallies":[{"goal":"g1","merged":4,"cancelled":1,"closed":0,"total":7}],"olderTasks":5}""")

    @Test fun snapshotCountsWhatItLeftOut() {
        val state = FeedState().on(windowed)
        assertEquals(OlderTasks(merged = 4, finished = 5), state.older["g1"])
        assertTrue(state.hasOlder("g1"))
        assertTrue(FeedState().on(snapshot).older.isEmpty())
    }

    @Test fun olderPagesJoinTheTasksUntilNoneAreLeft() {
        var state = FeedState().on(windowed)
        val (asked, request) = state.olderRequest("g1")!!
        assertEquals(dev.maplefactory.wire.ClientMessage.TasksOlder(goal = "g1", limit = 50), request)
        assertNull(asked.olderRequest("g1")) // one at a time
        state = asked.on("""{"type":"tasks.page","goal":"g1","more":true,"tasks":[${task("MF-9", "merged")},${task("MF-8", "cancelled")}]}""")
        assertEquals(listOf("MF-1", "MF-2", "MF-9", "MF-8"), state.tasks.map { it.id })
        assertEquals(OlderTasks(merged = 3, finished = 3), state.older["g1"])
        assertEquals(dev.maplefactory.wire.ClientMessage.TasksOlder(goal = "g1", before = 2, beforeId = "MF-8", limit = 50), state.olderRequest("g1")!!.second)
        state = state.on("""{"type":"tasks.page","goal":"g1","more":false,"tasks":[]}""")
        assertFalse(state.hasOlder("g1"))
    }

    @Test fun aTaskAskedForByIdJoinsTheList() {
        val (asked, request) = FeedState().on(windowed).fetchRequest("MF-7")!!
        assertEquals(dev.maplefactory.wire.ClientMessage.TaskGet(id = "MF-7"), request)
        val state = asked.on("""{"type":"task.updated","task":${task("MF-7", "merged")}}""")
        assertEquals("MF-7", state.tasks.last().id)
        assertTrue(state.fetching.isEmpty())
        assertEquals(OlderTasks(merged = 3, finished = 4), state.older["g1"])
    }

    // Docs (MF-370)

    private fun doc(id: String, updated: Long, goal: String? = "g1", extra: String = "") =
        """{"id":"$id","title":"Doc $id","goal":${goal?.let { "\"$it\"" } ?: "null"},"createdBy":"andrea","createdAt":1,"updatedAt":$updated$extra}"""

    private fun decision(id: String, status: String, at: Long, goal: String = "g1", extra: String = "") =
        """{"id":"$id","doc":"d1","goal":"$goal","question":"Q $id","options":[{"id":"a","label":"A"},{"id":"b","label":"B","note":"cheaper"}],
            "rationale":"why","status":"$status","proposedBy":"sam","proposedAt":$at$extra}"""

    private fun thread(id: String, doc: String = "d1", extra: String = "") =
        """{"id":"$id","doc":"$doc","comments":[{"id":"c-$id","author":"sam","text":"hi","at":1}],"createdBy":"sam","createdAt":1$extra}"""

    private val withDocs = snapshot.trimEnd().removeSuffix("}") +
        ""","docs":[${doc("d1", 5)},${doc("d2", 9)},${doc("d3", 7, extra = ",\"archived\":true")},${doc("d4", 8, goal = null)}],
            "decisions":[${decision("x1", "proposed", 3)},${decision("x2", "accepted", 4, extra = ",\"decidedBy\":\"andrea\",\"decidedAt\":10")},${decision("x3", "proposed", 6, goal = "g2")}]}"""

    @Test fun snapshotCarriesDocsAndDecisions() {
        val state = FeedState().on(withDocs)
        assertEquals(4, state.docs.size)
        assertEquals(listOf("d2", "d4", "d1"), state.activeDocs.map { it.id })
        assertEquals(listOf("d2", "d1"), state.docs("g1").map { it.id })
        assertEquals(1, state.openDecisionCount("g1"))
        assertEquals(1, state.openDecisionCount("g2"))
    }

    @Test fun docDeltasUpsertAndRemove() {
        var state = FeedState().on(withDocs)
        state = state.on("""{"type":"doc.updated","doc":${doc("d5", 20)}}""")
        assertEquals("d5", state.docs.first().id)
        state = state.on("""{"type":"doc.updated","doc":${doc("d1", 30, extra = ",\"openThreads\":2")}}""")
        assertEquals(5, state.docs.size)
        assertEquals(2L, state.doc("d1")?.openThreads)
        assertEquals("d1", state.activeDocs.first().id)
        state = state.on("""{"type":"doc.removed","id":"d2"}""")
        assertNull(state.doc("d2"))
    }

    @Test fun threadsAreStoredByDoc() {
        var state = FeedState().on(withDocs)
        state = state.on("""{"type":"doc.threads","doc":"d1","threads":[${thread("t1")},${thread("t2")}]}""")
        assertEquals(listOf("t1", "t2"), state.docThreads["d1"]?.map { it.id })
        state = state.on("""{"type":"doc.thread.updated","thread":${thread("t2", extra = ",\"resolved\":true")}}""")
        assertEquals(listOf("t1"), state.openThreads("d1").map { it.id })
        state = state.on("""{"type":"doc.thread.updated","thread":${thread("t9", doc = "d2")}}""")
        assertEquals(listOf("t9"), state.docThreads["d2"]?.map { it.id })
        // doc.threads replaces what was there.
        state = state.on("""{"type":"doc.threads","doc":"d1","threads":[]}""")
        assertTrue(state.docThreads["d1"]!!.isEmpty())
    }

    @Test fun decisionUpdatedUpserts() {
        var state = FeedState().on(withDocs)
        state = state.on("""{"type":"decision.updated","decision":${decision("x1", "rejected", 3, extra = ",\"decidedBy\":\"andrea\",\"decidedAt\":12")}}""")
        assertEquals(3, state.decisions.size)
        assertEquals(dev.maplefactory.wire.DecisionStatus.Rejected, state.decisions.first { it.id == "x1" }.status)
        assertEquals(0, state.openDecisionCount("g1"))
        state = state.on("""{"type":"decision.updated","decision":${decision("x4", "proposed", 15)}}""")
        assertEquals("x4", state.decisions.last().id)
        assertEquals(1, state.openDecisionCount("g1"))
    }

    @Test fun filterDecisionsByStatusPersonAndGoal() {
        val list = FeedState().on(withDocs).decisions
        val f = FeedState.DecisionFilter.entries.associateWith { FeedState.filterDecisions(list, it).map { d -> d.id } }
        assertEquals(listOf("x3", "x1"), f[FeedState.DecisionFilter.Open])
        assertEquals(listOf("x2"), f[FeedState.DecisionFilter.Accepted])
        assertTrue(f[FeedState.DecisionFilter.Rejected]!!.isEmpty())
        assertEquals(listOf("x2", "x3", "x1"), f[FeedState.DecisionFilter.All])
        assertEquals(listOf("x2"), FeedState.filterDecisions(list, FeedState.DecisionFilter.All, person = "andrea").map { it.id })
        assertEquals(listOf("x2", "x1"), FeedState.filterDecisions(list, FeedState.DecisionFilter.All, goal = "g1").map { it.id })
    }
}

package dev.maplefactory.kit

import dev.maplefactory.wire.ClientMessage
import dev.maplefactory.wire.HandReason
import dev.maplefactory.wire.ServerToClient
import dev.maplefactory.wire.TaskState
import dev.maplefactory.wire.WireJson
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The generated Kotlin wire types against real feed JSON, and what a newer server may send. Mirrors WireTolerance.swift. */
class WireDecodeTest {
    private fun decode(json: String): ServerToClient = WireJson.decodeFromString(ServerToClient.serializer(), json)

    /** A snapshot recorded from scripts/dev-stack.sh's /client/connect feed. */
    @Test fun aRealSnapshotDecodes() {
        val text = javaClass.getResource("/snapshot.json")!!.readText()
        val snapshot = decode(text)
        assertTrue("decoded as $snapshot", snapshot is ServerToClient.Snapshot)
        val state = FeedState().apply(snapshot).state
        assertTrue(state.hasSnapshot)
        assertTrue(state.me != null)
        assertTrue(state.tasks.isNotEmpty())
        assertTrue(state.goals.isNotEmpty())
        assertTrue(state.machines.isNotEmpty())
        // Every task decodes to a state this build knows.
        assertTrue(state.tasks.none { it.state == TaskState.Unknown })
    }

    private fun taskUpdated(state: String, reason: String) = """
        {"type":"task.updated","task":{
          "id":"MF-1","goal":"g","title":"A task","state":"$state","owner":"andrea","brief":"",
          "createdAt":1,"updatedAt":2,"planVersion":1,"approvalsNeeded":0,"reviewsNeeded":0,
          "shareable":false,"agent":"claude",
          "hand":{"reason":"$reason","summary":"Something new needs you","at":3,"assignee":"andrea"}
        }}
    """

    @Test fun unknownValuesDecodeAsUnknown() {
        val message = decode(taskUpdated("somethingNewer", "somethingNew")) as ServerToClient.TaskUpdated
        assertEquals(TaskState.Unknown, message.task.state)
        assertEquals(HandReason.Unknown, message.task.hand?.reason)
        assertEquals("Something new needs you", message.task.hand?.summary)
    }

    @Test fun knownValuesRoundTrip() {
        val message = decode(taskUpdated("building", "mergeFailed"))
        val task = (message as ServerToClient.TaskUpdated).task
        assertEquals(TaskState.Building, task.state)
        assertEquals(HandReason.MergeFailed, task.hand?.reason)
        assertEquals(message, decode(WireJson.encodeToString(ServerToClient.serializer(), message)))
    }

    @Test fun unknownMessageTypesDecodeAsUnknown() {
        assertEquals(ServerToClient.Unknown("somethingNew"), decode("""{"type":"somethingNew","x":1}"""))
    }

    @Test fun clientMessagesCarryTheirType() {
        assertEquals("""{"type":"subscribe"}""", WireJson.encodeToString(ClientMessage.serializer(), ClientMessage.Subscribe))
        assertEquals(
            """{"type":"task.approvePlan","id":"MF-1"}""",
            WireJson.encodeToString(ClientMessage.serializer(), ClientMessage.TaskApprovePlan(id = "MF-1")),
        )
        assertEquals(
            """{"type":"task.resolveHand","id":"MF-1","note":"Go"}""",
            WireJson.encodeToString(ClientMessage.serializer(), ClientMessage.TaskResolveHand(id = "MF-1", note = "Go")),
        )
    }
}

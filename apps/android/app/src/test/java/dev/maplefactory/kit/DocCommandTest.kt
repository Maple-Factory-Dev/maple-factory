package dev.maplefactory.kit

import dev.maplefactory.FactoryStore
import dev.maplefactory.wire.ClientMessage
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The docs editor's `command` events: only doc and decision messages get through to the socket. */
class DocCommandTest {
    @Test fun allowsTheEditorsCommands() {
        assertTrue(FactoryStore.docCommand("""{"type":"doc.resolve","doc":"d1","thread":"t1"}""") is ClientMessage.DocResolve)
        assertTrue(FactoryStore.docCommand("""{"type":"doc.reopen","doc":"d1","thread":"t1"}""") is ClientMessage.DocReopen)
        assertTrue(FactoryStore.docCommand("""{"type":"decision.reject","id":"x"}""") is ClientMessage.DecisionReject)
    }

    @Test fun dropsAnythingElse() {
        assertNull(FactoryStore.docCommand("""{"type":"task.merge","id":"MF-1"}"""))
        assertNull(FactoryStore.docCommand("""{"type":"admins.grant","login":"evil"}"""))
        assertNull(FactoryStore.docCommand("""{"type":"secrets.set","name":"A","value":"b"}"""))
        assertNull(FactoryStore.docCommand("""{"doc":"d1"}"""))
        assertNull(FactoryStore.docCommand("not json"))
        assertNull(FactoryStore.docCommand("""["doc.resolve"]"""))
    }
}

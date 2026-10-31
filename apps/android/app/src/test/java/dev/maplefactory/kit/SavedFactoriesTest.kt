package dev.maplefactory.kit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The factories this device remembers: one entry per host and port, and which one opens after signing out of another. Mirrors SavedFactoriesTests.swift. */
class SavedFactoriesTest {
    private fun factory(url: String, org: String = "acme", at: Long = 0) = SavedFactory(url, org, org, at)

    @Test fun keyIsHostAndPort() {
        assertEquals("localhost:8787", factory("http://localhost:8787").id)
        assertEquals("factory.acme.dev", factory("https://factory.acme.dev/").id)
        assertEquals("10.0.2.2:8788", factory("http://10.0.2.2:8788").id)
    }

    @Test fun upsertAddsANewFactory() {
        val list = SavedFactories.upsert(factory("https://b.dev"), listOf(factory("https://a.dev")))
        assertEquals(listOf("a.dev", "b.dev"), list.map { it.id })
    }

    @Test fun upsertReplacesTheSameHostAndPortInPlace() {
        val list = listOf(factory("https://a.dev"), factory("http://localhost:8787", org = "old"), factory("https://b.dev"))
        val updated = SavedFactories.upsert(factory("https://localhost:8787/", org = "new", at = 5), list)
        assertEquals(listOf("a.dev", "localhost:8787", "b.dev"), updated.map { it.id })
        assertEquals("new", updated[1].org)
    }

    @Test fun aDifferentPortIsADifferentFactory() {
        val list = SavedFactories.upsert(factory("http://localhost:8788"), listOf(factory("http://localhost:8787")))
        assertEquals(2, list.size)
    }

    @Test fun removeDropsOnlyThatFactory() {
        val list = listOf(factory("https://a.dev"), factory("https://b.dev"))
        assertEquals(listOf("b.dev"), SavedFactories.remove("https://a.dev", list).map { it.id })
        assertEquals(list, SavedFactories.remove("https://c.dev", list))
    }

    @Test fun fallbackIsTheMostRecentlyUsed() {
        val list = listOf(factory("https://a.dev", at = 10), factory("https://b.dev", at = 30), factory("https://c.dev", at = 20))
        assertEquals("b.dev", SavedFactories.fallback(list)?.id)
        assertNull(SavedFactories.fallback(emptyList()))
    }

    @Test fun listRoundTrips() {
        val list = listOf(factory("https://a.dev", at = 1), factory("http://localhost:8787", org = "local", at = 2).copy(icon = "/icon/abc"))
        assertEquals(list, SavedFactories.decode(SavedFactories.encode(list)))
    }

    @Test fun aListSavedBeforeIconsStillLoads() {
        val list = SavedFactories.decode("""[{"server":"https://a.dev","org":"acme","name":"acme","lastUsed":0}]""")
        assertEquals(1, list.size)
        assertNull(list[0].icon)
    }
}

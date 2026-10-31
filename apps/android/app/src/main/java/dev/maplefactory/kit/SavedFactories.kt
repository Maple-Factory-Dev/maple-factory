package dev.maplefactory.kit

import android.content.SharedPreferences
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import java.net.URI

/** A factory signed into on this device. Its token is in the [TokenStore] under [id]. */
@Serializable
data class SavedFactory(
    val server: String,
    val org: String,
    /** The org's name, or the host when it has none. */
    val name: String,
    /** Milliseconds since 1970. */
    val lastUsed: Long,
    /** The factory's icon as last seen (a path on its server); null shows the letter tile. */
    val icon: String? = null,
) {
    val id: String get() = key(server)
    val host: String get() = id

    companion object {
        /** One entry per host and port: http and https to the same place are the same factory. */
        fun key(server: String): String {
            val uri = runCatching { URI(server) }.getOrNull() ?: return server
            return (uri.host ?: "") + if (uri.port >= 0) ":${uri.port}" else ""
        }
    }
}

/** The saved-factory list's rules, kept pure so they can be tested; stored in preferences under `factories`. */
object SavedFactories {
    const val KEY = "factories"
    private val serializer = ListSerializer(SavedFactory.serializer())

    fun load(prefs: SharedPreferences): List<SavedFactory>? =
        prefs.getString(KEY, null)?.let { runCatching { json.decodeFromString(serializer, it) }.getOrNull() }

    fun store(list: List<SavedFactory>, prefs: SharedPreferences) {
        prefs.edit().putString(KEY, json.encodeToString(serializer, list)).apply()
    }

    fun encode(list: List<SavedFactory>): String = json.encodeToString(serializer, list)
    fun decode(text: String): List<SavedFactory> = json.decodeFromString(serializer, text)

    /** Adds the factory, or replaces the entry for the same host and port where it stands. */
    fun upsert(factory: SavedFactory, list: List<SavedFactory>): List<SavedFactory> {
        val index = list.indexOfFirst { it.id == factory.id }
        return if (index >= 0) list.toMutableList().also { it[index] = factory } else list + factory
    }

    fun remove(server: String, list: List<SavedFactory>): List<SavedFactory> =
        list.filter { it.id != SavedFactory.key(server) }

    /** The factory to open after signing out of one: the most recently used of those left. */
    fun fallback(list: List<SavedFactory>): SavedFactory? = list.maxByOrNull { it.lastUsed }

    private val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true; explicitNulls = false }
}

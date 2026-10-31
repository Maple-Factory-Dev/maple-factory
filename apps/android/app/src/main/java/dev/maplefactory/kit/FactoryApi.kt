package dev.maplefactory.kit

import dev.maplefactory.wire.Member
import dev.maplefactory.wire.WireJson
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import java.net.ConnectException
import java.net.SocketTimeoutException
import java.net.URI
import java.net.UnknownHostException
import java.util.concurrent.TimeUnit

/**
 * A factory's HTTP API, before and after signing in: the health probe, GitHub's device-flow sign-in,
 * and JSON loads with the member's token. MapleKit's FactoryAPI, for Android.
 */
class FactoryApi(val server: String, val token: String) {
    /** A request to [path] on the factory, with this member's token. */
    fun request(path: String): Request.Builder =
        Request.Builder().url(join(server, path)).header("Authorization", "Bearer $token")

    /** [path]'s body, with this member's token; null unless it answers 200. */
    suspend fun bytes(path: String): ByteArray? = withContext(Dispatchers.IO) {
        runCatching { client.newCall(request(path).build()).execute().use { if (it.code == 200) it.body.bytes() else null } }.getOrNull()
    }

    @Serializable
    data class Health(
        val ok: Boolean,
        @SerialName("protocol") val protocolVersion: Int,
        val org: String? = null,
        /** "github", "dev" (a local server signs you in as its DEV_LOGIN) or "unconfigured". */
        val signIn: String,
        val devLogin: String? = null,
    )

    @Serializable
    data class SignInResult(val token: String, val member: Member, val org: String, val server: String = "")

    @Serializable
    data class DeviceCode(val deviceCode: String, val userCode: String, val verificationUri: String, val interval: Int, val expiresIn: Int)

    class ClientError(message: String) : Exception(message)

    companion object {
        val client: OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(8, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .pingInterval(20, TimeUnit.SECONDS)
            .build()

        private val jsonType = "application/json".toMediaType()

        fun join(server: String, path: String) = server.trimEnd('/') + "/" + path.trimStart('/')

        /** "localhost:8787" → http://localhost:8787; anything else is https unless it says otherwise. 10.0.2.2 is the emulator's Mac. */
        fun serverUrl(typed: String): String? {
            var text = typed.trim().trimEnd('/')
            if (text.isEmpty()) return null
            if ("://" !in text) {
                val local = text.startsWith("localhost") || text.startsWith("127.0.0.1") || text.startsWith("10.0.2.2") ||
                    text.endsWith(".local") || ".local:" in text
                text = (if (local) "http://" else "https://") + text
            }
            val uri = runCatching { URI(text) }.getOrNull() ?: return null
            return if (uri.host.isNullOrEmpty()) null else text
        }

        fun websocketUrl(server: String, path: String): String {
            val url = join(server, path)
            return if (url.startsWith("https://")) "wss://" + url.removePrefix("https://") else "ws://" + url.removePrefix("http://")
        }

        suspend fun probe(server: String): Health = load(Request.Builder().url(join(server, "/healthz")).build())

        suspend fun startDeviceFlow(server: String): DeviceCode =
            load(Request.Builder().url(join(server, "/auth/device/start")).post(ByteArray(0).toRequestBody()).build())

        /** Null while GitHub is still waiting on the person. [deviceLabel] names this device in the member's sign-ins. */
        suspend fun pollDeviceFlow(server: String, code: String, deviceLabel: String): SignInResult? = withContext(Dispatchers.IO) {
            val body = buildJsonObject { put("deviceCode", code); put("label", deviceLabel) }.toString().toRequestBody(jsonType)
            client.newCall(Request.Builder().url(join(server, "/auth/device/poll")).post(body).build()).execute().use { response ->
                val text = response.body.string()
                when (response.code) {
                    202 -> null
                    200 -> WireJson.decodeFromString(SignInResult.serializer(), text).copy(server = server)
                    else -> throw ClientError(text.ifBlank { "Sign-in failed (${response.code})." })
                }
            }
        }

        /** A local dev server's sign-in (`/dev/token`); [login] signs in as that member instead (`-devAs`). */
        suspend fun devSignIn(server: String, login: String?): SignInResult {
            val url = join(server, "/dev/token") + (login?.takeIf { it.isNotBlank() }?.let { "?as=$it" } ?: "")
            val result: SignInResult = load(Request.Builder().url(url).post(ByteArray(0).toRequestBody()).build())
            return result.copy(server = server)
        }

        /** The JSON [request] answers with; an error status throws the server's text. */
        suspend inline fun <reified T> load(request: Request): T = withContext(Dispatchers.IO) {
            client.newCall(request).execute().use { response ->
                val text = response.body.string()
                if (response.code !in 200..299) {
                    val trimmed = text.trim()
                    throw ClientError(if (trimmed.isEmpty() || trimmed.startsWith("<")) "The server answered ${response.code}." else trimmed)
                }
                try {
                    WireJson.decodeFromString<T>(if (response.code == 204) "{}" else text)
                } catch (_: SerializationException) {
                    throw ClientError("That doesn't look like a Maple factory.")
                } catch (_: IllegalArgumentException) {
                    throw ClientError("That doesn't look like a Maple factory.")
                }
            }
        }

        const val TOO_NEW = "This factory is newer than this app — update Maple Factory."

        fun describe(error: Throwable, status: Int? = null): String = when {
            status == 401 -> "Your sign-in expired."
            error is SerializationException -> TOO_NEW
            error is ConnectException || error is UnknownHostException -> "Can't reach the factory."
            error is SocketTimeoutException -> "The factory took too long to answer."
            error is ClientError -> error.message ?: "Something went wrong."
            error is IOException -> error.message?.takeIf { it.isNotBlank() } ?: "The connection dropped."
            else -> error.message ?: error.toString()
        }
    }
}

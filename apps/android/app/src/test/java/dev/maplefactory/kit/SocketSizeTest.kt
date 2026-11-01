package dev.maplefactory.kit

import dev.maplefactory.wire.ServerToClient
import dev.maplefactory.wire.WireJson
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.DataOutputStream
import java.net.ServerSocket
import java.security.MessageDigest
import java.util.Base64
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * Big snapshots through the app's real OkHttpClient. URLSession's 1 MiB default failed on these on iPhone
 * ("Message too long", MF-212); this proves FactoryApi.client reads frames far past that whole (MF-213).
 *
 * The server end is a bare socket that writes the snapshot as one text frame, the way the factory server does.
 * (OkHttp's own WebSocket, as in mockwebserver3, can't be the sender: send() refuses anything over its 16 MiB queue.)
 */
class SocketSizeTest {
    private lateinit var server: ServerSocket

    @Before fun start() {
        server = ServerSocket(0)
    }

    @After fun stop() {
        server.close()
    }

    /** Accepts one websocket upgrade, sends [frame] as a single unmasked text frame, then answers pings until the client leaves. */
    private fun serveOnce(frame: String) = Thread {
        server.accept().use { socket ->
            val input = socket.getInputStream()
            val head = StringBuilder()
            while (!head.endsWith("\r\n\r\n")) head.append(input.read().toChar())
            val key = head.lines().first { it.startsWith("Sec-WebSocket-Key:", ignoreCase = true) }.substringAfter(':').trim()
            val accept = Base64.getEncoder().encodeToString(
                MessageDigest.getInstance("SHA-1").digest((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").toByteArray()),
            )
            val out = DataOutputStream(socket.getOutputStream().buffered())
            out.writeBytes("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: $accept\r\n\r\n")
            val payload = frame.toByteArray()
            out.writeByte(0x81) // FIN + text
            out.writeByte(127)
            out.writeLong(payload.size.toLong())
            out.write(payload)
            out.flush()
            // Read the client's frames (masked) until it closes; answer pings so the 20s ping can't fail the test.
            while (true) {
                val b0 = input.read().takeIf { it >= 0 } ?: break
                val b1 = input.read()
                var len = (b1 and 0x7f).toLong()
                if (len == 126L) len = ((input.read() shl 8) or input.read()).toLong()
                else if (len == 127L) len = (0 until 8).fold(0L) { acc, _ -> (acc shl 8) or input.read().toLong() }
                val mask = ByteArray(4).also { input.readNBytes(it, 0, 4) }
                val body = input.readNBytes(len.toInt()).mapIndexed { i, b -> (b.toInt() xor mask[i % 4].toInt()).toByte() }.toByteArray()
                when (b0 and 0x0f) {
                    0x9 -> { out.writeByte(0x8a); out.writeByte(body.size); out.write(body); out.flush() }
                    0x8 -> { out.writeByte(0x88); out.writeByte(0); out.flush(); break }
                }
            }
        }
    }.apply { isDaemon = true; start() }

    /** The recorded snapshot with its tasks copied (fresh ids) until the JSON is at least [bytes] long. */
    private fun bigSnapshot(bytes: Int): Pair<String, Int> {
        val recorded = WireJson.parseToJsonElement(javaClass.getResource("/snapshot.json")!!.readText()).jsonObject
        val tasks = recorded.getValue("tasks").jsonArray.map { it.jsonObject }
        val each = tasks.sumOf { it.toString().length } / tasks.size
        val count = bytes / each + 1
        val copies = (0 until count).map { n ->
            val task = tasks[n % tasks.size]
            JsonObject(task + ("id" to JsonPrimitive("BIG-$n")))
        }
        val text = JsonObject(recorded + ("tasks" to JsonArray(copies as List<JsonElement>))).toString()
        assertTrue("built ${text.length} bytes, wanted $bytes", text.length >= bytes)
        return text to count
    }

    private fun sendsWhole(bytes: Int) {
        val (frame, count) = bigSnapshot(bytes)
        val serving = serveOnce(frame)

        val received = AtomicReference<String>()
        val failure = AtomicReference<Throwable>()
        val done = CountDownLatch(1)
        val request = Request.Builder().url("http://127.0.0.1:${server.localPort}/client/connect").build()
        val socket = FactoryApi.client.newWebSocket(request, object : WebSocketListener() {
            override fun onMessage(webSocket: WebSocket, text: String) {
                received.set(text); done.countDown()
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                failure.set(t); done.countDown()
            }
        })
        assertTrue("no message within 60s", done.await(60, TimeUnit.SECONDS))
        socket.close(1000, null)
        serving.join(10_000)

        assertNull("onFailure fired", failure.get())
        val text = received.get()
        assertEquals(frame, text)

        val message = WireJson.decodeFromString(ServerToClient.serializer(), text)
        assertTrue("decoded as ${message::class}", message is ServerToClient.Snapshot)
        val state = FeedState().apply(message).state
        assertTrue(state.hasSnapshot)
        assertEquals(count, state.tasks.size)
        println("SocketSizeTest: ${text.length} bytes (${"%.1f".format(text.length / 1048576.0)} MiB), $count tasks arrived whole and applied")
    }

    @Test fun anEightMiBSnapshotArrivesWhole() = sendsWhole(8 shl 20)

    @Test fun aFortyMiBSnapshotArrivesWhole() = sendsWhole(40 shl 20)
}

package dev.maplefactory

import android.app.Application
import android.content.Context
import android.os.Build
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import dev.maplefactory.kit.DiffFile
import dev.maplefactory.kit.FactoryApi
import dev.maplefactory.kit.FeedState
import dev.maplefactory.kit.SavedFactories
import dev.maplefactory.kit.SavedFactory
import dev.maplefactory.kit.TokenStore
import dev.maplefactory.wire.ChangeRequest
import dev.maplefactory.wire.ChangeStatus
import dev.maplefactory.wire.ClientMessage
import dev.maplefactory.wire.Comment
import dev.maplefactory.wire.ServerToClient
import dev.maplefactory.wire.Task
import dev.maplefactory.wire.TaskEvent
import dev.maplefactory.wire.TaskState
import dev.maplefactory.wire.WireJson
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerializationException
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.util.UUID

/**
 * The Android app's factories: the ones saved on this device, which one is open, and its feed. Opens
 * the same `/client/connect` socket as the Mac and iPhone apps, applies what it says to a FeedState,
 * and sends the actions a phone can take. Switching factories tears down one feed and opens the next.
 */
class FactoryStore(app: Application) : AndroidViewModel(app) {
    sealed class Status {
        data object SignedOut : Status()
        data object Connecting : Status()
        data object Live : Status()
        data object Demo : Status()
        data class Reconnecting(val attempt: Int, val reason: String) : Status()
        data object TooNew : Status()
    }

    enum class Tab { Inbox, Goals, Machines, Settings }

    /** Where you were in a factory, so switching back opens the same tab and goal. */
    data class Place(val tab: Tab = Tab.Inbox, val goal: String? = null)

    var status by mutableStateOf<Status>(Status.SignedOut)
        private set
    var feed by mutableStateOf(FeedState())
        private set
    var server by mutableStateOf<String?>(null)
        private set
    var saved by mutableStateOf<List<SavedFactory>>(emptyList())
        private set
    /** The toast or error to show, newest only. */
    var notice by mutableStateOf<FeedState.Notice?>(null)
    /** Each task's diff once loaded, keyed by the change it was loaded for. */
    val diffs = mutableStateMapOf<String, Pair<String, List<DiffFile>>>()
    /** Each factory's inbox count for you, as last seen, by factory key: the rail's badges. */
    val unread = mutableStateMapOf<String, Int>()
    /** A task to open once the factory's feed has it: a link, or `-task`. */
    var pendingTask by mutableStateOf<String?>(null)
    /** Bumped whenever another factory opens, so the screens reset to its place. */
    var opened by mutableStateOf(0)
        private set

    private var token: String? = null
    private var socket: WebSocket? = null
    private var generation = 0
    private var attempt = 0
    private val prefs = app.getSharedPreferences("maple", Context.MODE_PRIVATE)
    private val tokens: TokenStore by lazy { TokenStore.open(app) }
    /** The demo's two factories, so the switcher has something to switch between. */
    private var demoFactory = 0

    init {
        saved = SavedFactories.load(prefs) ?: emptyList()
        prefs.getString("unread", null)?.let { text ->
            runCatching { WireJson.decodeFromString<Map<String, Int>>(text) }.getOrNull()?.let { unread.putAll(it) }
        }
    }

    val isSignedIn: Boolean get() = status != Status.SignedOut
    val me: String get() = feed.me?.login ?: ""
    val factoryName: String get() = feed.name ?: feed.org.takeIf { it.isNotEmpty() && it != "local" } ?: server?.let { SavedFactory.key(it) } ?: "Factory"
    val currentKey: String? get() = server?.let { SavedFactory.key(it) }

    /** The factories the rail lists: the saved ones, or the demo's. */
    val factories: List<SavedFactory> get() = if (status == Status.Demo) DemoData.factories else saved

    // Places

    fun place(key: String?): Place {
        key ?: return Place()
        val tab = prefs.getString("place.$key.tab", null)?.let { name -> Tab.entries.firstOrNull { it.name == name } } ?: Tab.Inbox
        return Place(tab, prefs.getString("place.$key.goal", null))
    }

    fun remember(tab: Tab, goal: String?) {
        val key = currentKey ?: return
        prefs.edit().putString("place.$key.tab", tab.name).putString("place.$key.goal", goal).apply()
    }

    // Signing in

    /** Opens the most recently used saved factory, if its token is still here. */
    fun restore() {
        val factory = SavedFactories.fallback(saved) ?: return
        val token = tokens.read(factory.server) ?: return
        open(factory.server, token)
    }

    fun signedIn(result: FactoryApi.SignInResult) {
        tokens.write(result.server, result.token)
        val name = if (result.org.isEmpty() || result.org == "local") SavedFactory.key(result.server) else result.org
        val existing = saved.firstOrNull { it.id == SavedFactory.key(result.server) }
        saved = SavedFactories.upsert(SavedFactory(result.server, result.org, existing?.name ?: name, System.currentTimeMillis(), existing?.icon), saved)
        SavedFactories.store(saved, prefs)
        open(result.server, result.token)
    }

    /** Switches to another saved factory, without signing in again. */
    fun switchTo(factory: SavedFactory) {
        if (status == Status.Demo) {
            val index = DemoData.factories.indexOfFirst { it.id == factory.id }
            if (index >= 0 && index != demoFactory) startDemo(index)
            return
        }
        if (factory.id == currentKey) return
        val token = tokens.read(factory.server) ?: return
        saved = SavedFactories.upsert(factory.copy(lastUsed = System.currentTimeMillis()), saved)
        SavedFactories.store(saved, prefs)
        open(factory.server, token)
    }

    /** Signs out of [factory] (the open one if null): drops it and its token, and opens the most recently used one left. */
    fun signOut(factory: SavedFactory? = null) {
        val target = factory?.server ?: server ?: return
        val wasOpen = SavedFactory.key(target) == currentKey
        tokens.delete(target)
        saved = SavedFactories.remove(target, saved)
        SavedFactories.store(saved, prefs)
        unread.remove(SavedFactory.key(target))
        storeUnread()
        if (!wasOpen) return
        close()
        SavedFactories.fallback(saved)?.let { switchTo(it) }
    }

    /** Leaves the demo, or the factory, for the sign-in screen. */
    fun close() {
        disconnect()
        server = null
        token = null
        feed = FeedState()
        diffs.clear()
        status = Status.SignedOut
    }

    private fun open(server: String, token: String) {
        close()
        this.server = server
        this.token = token
        attempt = 0
        opened++
        connect()
    }

    val deviceLabel: String get() = "${Build.MANUFACTURER} ${Build.MODEL}".trim()

    // Feed

    private fun connect() {
        val server = server ?: return
        val token = token ?: return
        disconnect()
        val gen = generation
        if (status != Status.Live && attempt == 0) status = Status.Connecting
        val request = Request.Builder().url(FactoryApi.websocketUrl(server, "/client/connect"))
            .header("Authorization", "Bearer $token")
            // Teammates see a phone badge for someone who's only on a phone.
            .header("x-maple-client", "mobile")
            .build()
        socket = FactoryApi.client.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                webSocket.send(encode(ClientMessage.Subscribe))
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                val message = try {
                    WireJson.decodeFromString(ServerToClient.serializer(), text)
                } catch (error: SerializationException) {
                    Log.w("MapleFactory", "Can't read the factory's message", error)
                    onMain(gen) { disconnect(); status = Status.TooNew }
                    return
                } catch (error: IllegalArgumentException) {
                    Log.w("MapleFactory", "Can't read the factory's message", error)
                    onMain(gen) { disconnect(); status = Status.TooNew }
                    return
                }
                onMain(gen) { apply(message) }
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                onMain(gen) {
                    if (response?.code == 401) {
                        signOut()
                        notice = FeedState.Notice.Error("Your sign-in expired.")
                    } else {
                        retry(FactoryApi.describe(t, response?.code))
                    }
                }
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                onMain(gen) { retry("The connection closed.") }
            }
        })
    }

    private fun onMain(gen: Int, block: () -> Unit) {
        viewModelScope.launch(Dispatchers.Main) { if (gen == generation) block() }
    }

    /** Pull to refresh: a fresh socket, so a fresh snapshot. */
    fun refresh() {
        if (status == Status.Demo || server == null) return
        attempt = 0
        connect()
    }

    /** Closes the socket; anything its listener still says is for an older generation and is dropped. */
    private fun disconnect() {
        socket?.close(1001, null)
        socket = null
        generation++
    }

    /** Tries again after 2, 4, 8… seconds, at most 30. */
    private fun retry(reason: String) {
        attempt++
        status = Status.Reconnecting(attempt, reason)
        val delayMs = minOf(1L shl minOf(attempt, 5), 30L) * 1000
        val gen = generation
        viewModelScope.launch {
            delay(delayMs)
            if (gen == generation) connect()
        }
    }

    /** One message from the feed. */
    fun apply(message: ServerToClient) {
        if (message is ServerToClient.Snapshot) {
            attempt = 0
            status = Status.Live
        }
        val applied = feed.apply(message)
        feed = applied.state
        applied.notice?.let { notice = it }
        if (message is ServerToClient.Snapshot || message is ServerToClient.IconUpdated || message is ServerToClient.NameUpdated) rememberLook()
        countUnread()
    }

    /** Keeps the saved entry's name and icon as the factory has them, for the rail. */
    private fun rememberLook() {
        val key = currentKey ?: return
        val factory = saved.firstOrNull { it.id == key } ?: return
        val name = feed.name ?: feed.org.takeIf { it.isNotEmpty() && it != "local" } ?: factory.name
        if (factory.name == name && factory.icon == feed.icon && factory.org == feed.org) return
        saved = SavedFactories.upsert(factory.copy(name = name, icon = feed.icon, org = feed.org), saved)
        SavedFactories.store(saved, prefs)
    }

    private fun countUnread() {
        val key = currentKey ?: return
        val count = feed.inbox(me).count { it.assignee == me }
        if (unread[key] == count) return
        unread[key] = count
        storeUnread()
    }

    private fun storeUnread() {
        prefs.edit().putString("unread", WireJson.encodeToString(unread.toMap())).apply()
    }

    private fun encode(message: ClientMessage) = WireJson.encodeToString(ClientMessage.serializer(), message)

    /** The next page of the goal's finished tasks older than the snapshot's 14 days. */
    fun loadOlder(goal: String) {
        val (next, request) = feed.olderRequest(goal) ?: return
        feed = next
        send(request)
    }

    /** A task opened by ID that isn't loaded (the snapshot leaves out ones finished over 14 days ago). */
    fun fetchTask(id: String) {
        if (status != Status.Live) return
        val (next, request) = feed.fetchRequest(id) ?: return
        feed = next
        send(request)
    }

    fun send(message: ClientMessage) {
        if (status == Status.Demo) return demoSend(message)
        socket?.send(encode(message))
    }

    // Actions

    fun approvePlan(id: String) = send(ClientMessage.TaskApprovePlan(id = id))
    fun approveChanges(id: String) = send(ClientMessage.TaskApproveChanges(id = id))
    fun merge(id: String) = send(ClientMessage.TaskMerge(id = id))
    fun holdMerge(id: String) = send(ClientMessage.TaskHoldMerge(id = id))
    fun answer(id: String, text: String) = send(ClientMessage.TaskAnswer(id = id, text = text))
    fun resolveHand(id: String, option: String?, note: String) = send(ClientMessage.TaskResolveHand(id = id, option = option, note = note))
    fun comment(id: String, text: String) = send(ClientMessage.TaskComment(id = id, text = text))
    fun steer(id: String, text: String) = send(ClientMessage.TaskSteer(id = id, text = text))
    fun retryTask(id: String) = send(ClientMessage.TaskRetry(id = id))
    fun follow(goal: String, following: Boolean) = send(ClientMessage.GoalFollow(id = goal, following = following))

    /** Tells the factory which task you're looking at, so others see you there. */
    fun viewing(id: String?) = send(ClientMessage.Presence(viewing = id))

    // HTTP

    /** The open factory's API with your token, for diffs, attachments and its icon. */
    fun api(): FactoryApi? {
        val server = server ?: return null
        val token = token ?: return null
        return FactoryApi(server, token)
    }

    /** A saved factory's API, for its icon in the rail. */
    fun api(factory: SavedFactory): FactoryApi? =
        if (status == Status.Demo) null else tokens.read(factory.server)?.let { FactoryApi(factory.server, it) }

    /** Fetches a task's diff unless the one held is for the same change ([key]). */
    fun loadDiff(id: String, key: String) {
        if (status == Status.Demo) {
            diffs[id] = key to DemoData.diff()
            return
        }
        if (diffs[id]?.first == key) return
        val api = api() ?: return
        viewModelScope.launch {
            val bytes = api.bytes("/api/tasks/$id/diff") ?: return@launch
            val files = withContext(Dispatchers.Default) { DiffFile.parse(bytes.decodeToString()) }
            diffs[id] = key to files
        }
    }

    // Demo

    /** Sample goals, tasks and machines, so the app renders fully with no server. */
    fun startDemo(index: Int = 0) {
        close()
        demoFactory = index
        server = DemoData.factories[index].server
        feed = DemoData.feed(index)
        status = Status.Demo
        opened++
        countUnread()
    }

    /** The demo answers actions itself, the way a factory would. */
    private fun demoSend(message: ClientMessage) {
        val now = System.currentTimeMillis()
        fun update(id: String, change: (Task) -> Task) {
            val task = feed.task(id) ?: return
            apply(ServerToClient.TaskUpdated(change(task).copy(updatedAt = now)))
        }
        when (message) {
            is ClientMessage.TaskApprovePlan -> {
                update(message.id) {
                    val approvals = it.approvals + me
                    it.copy(approvals = approvals, state = if (approvals.size >= it.approvalsNeeded) TaskState.Building else it.state)
                }
                notice = FeedState.Notice.Toast("Plan approved", message.id)
            }
            is ClientMessage.TaskApproveChanges -> {
                update(message.id) { it.copy(reviews = it.reviews + me) }
                notice = FeedState.Notice.Toast("Changes approved", message.id)
            }
            is ClientMessage.TaskMerge -> {
                update(message.id) { it.copy(state = TaskState.Merged, mergeAt = null) }
                notice = FeedState.Notice.Toast("Merged", message.id)
            }
            is ClientMessage.TaskHoldMerge -> update(message.id) { it.copy(mergeAt = null) }
            is ClientMessage.TaskAnswer -> update(message.id) { it.copy(question = null, events = it.events + TaskEvent(me, "answered: ${message.text}", now)) }
            is ClientMessage.TaskResolveHand -> update(message.id) {
                it.copy(hand = null, events = it.events + TaskEvent(me, "resolved the hand: ${message.option ?: message.note}", now))
            }
            is ClientMessage.TaskComment -> update(message.id) { it.copy(comments = it.comments + Comment(UUID.randomUUID().toString(), me, message.text, now)) }
            is ClientMessage.TaskSteer -> update(message.id) {
                it.copy(changes = it.changes + ChangeRequest(UUID.randomUUID().toString(), me, message.text, now, status = ChangeStatus.Queued))
            }
            is ClientMessage.GoalFollow -> feed = feed.copy(follows = feed.follows + (message.id to message.following))
            else -> Unit
        }
    }

    override fun onCleared() {
        disconnect()
    }
}

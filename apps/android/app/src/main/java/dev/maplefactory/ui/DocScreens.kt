package dev.maplefactory.ui

import android.annotation.SuppressLint
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Gavel
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.PrimaryTabRow
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import dev.maplefactory.DemoData
import dev.maplefactory.FactoryStore
import dev.maplefactory.wire.Decision
import dev.maplefactory.wire.DecisionStatus
import dev.maplefactory.wire.Doc
import dev.maplefactory.wire.DocThread
import dev.maplefactory.wire.Member
import dev.maplefactory.wire.WireJson
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/** A doc's three tabs on a phone (MF-370). */
enum class DocTab(val title: String) { Doc("Doc"), Comments("Comments"), Decisions("Decisions") }

/** On a goal's page: its docs, with how many threads and decisions are open across them. */
@Composable
fun GoalDocsRow(store: FactoryStore, goal: String, onClick: () -> Unit) {
    val docs = store.feed.docs(goal)
    val threads = docs.sumOf { it.openThreads ?: 0 }.toInt()
    val decisions = store.feed.openDecisionCount(goal)
    ListRow(onClick) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Icon(Icons.Outlined.Description, null, Modifier.size(20.dp), tint = secondaryText)
            Text("Docs", fontWeight = FontWeight.Medium)
            Text("${docs.size}", color = secondaryText)
            Spacer(Modifier.weight(1f))
            CountBadge(threads, Icons.Outlined.ChatBubbleOutline, Maple.accent.color)
            CountBadge(decisions, Icons.Outlined.Gavel, Maple.warning.color)
        }
    }
}

@Composable
private fun CountBadge(count: Int, icon: androidx.compose.ui.graphics.vector.ImageVector, color: Color) {
    if (count <= 0) return
    Row(
        Modifier.clip(RoundedCornerShape(50)).background(color.copy(alpha = 0.14f)).padding(horizontal = 8.dp, vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Icon(icon, null, Modifier.size(13.dp), tint = color)
        Text("$count", color = color, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
    }
}

/** A goal's docs, last edited first. */
@Composable
fun DocsListScreen(store: FactoryStore, goal: String, open: (String) -> Unit) {
    val docs = store.feed.docs(goal)
    if (docs.isEmpty()) {
        if (store.feed.hasSnapshot) EmptyState("No docs yet", Icons.Outlined.Description, "Make one in the Mac app.") else Loading()
        return
    }
    Refreshable(store) {
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(vertical = 8.dp)) {
            items(docs, key = { it.id }) { doc -> DocRow(store, doc) { open(doc.id) } }
        }
    }
}

@Composable
private fun DocRow(store: FactoryStore, doc: Doc, onClick: () -> Unit) {
    val decisions = store.feed.decisions(doc.id).count { it.status == DecisionStatus.Proposed }.takeIf { it > 0 } ?: (doc.openDecisions ?: 0).toInt()
    ListRow(onClick) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Box(Modifier.size(36.dp).clip(RoundedCornerShape(8.dp)).background(MaterialTheme.colorScheme.surfaceContainerHigh), contentAlignment = Alignment.Center) {
                val icon = doc.icon?.takeIf { it.codePoints().anyMatch { c -> c > 0x2000 } }
                if (icon != null) Text(icon, fontSize = 18.sp) else Icon(Icons.Outlined.Description, null, Modifier.size(20.dp), tint = secondaryText)
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(doc.title, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text("Edited ${When.ago(doc.updatedAt).let { if (it == "now") "just now" else "$it ago" }}", style = MaterialTheme.typography.bodySmall, color = secondaryText)
            }
            CountBadge((doc.openThreads ?: 0).toInt(), Icons.Outlined.ChatBubbleOutline, Maple.accent.color)
            CountBadge(decisions, Icons.Outlined.Gavel, Maple.warning.color)
        }
    }
}

/** One doc: the shared editor in a WebView, then its open comment threads and its decisions, natively. */
@Composable
fun DocScreen(store: FactoryStore, id: String, tab: DocTab, onTab: (DocTab) -> Unit, openTask: (String) -> Unit) {
    val doc = store.feed.doc(id)
    if (doc == null) {
        if (store.feed.hasSnapshot) EmptyState("Doc not found", Icons.Outlined.Description, "It may have been removed.") else Loading()
        return
    }
    LaunchedEffect(id, store.status) { store.openDoc(id) }
    val threads = store.feed.openThreads(id)
    val decisions = store.feed.decisions(id)
    Column(Modifier.fillMaxSize()) {
        PrimaryTabRow(selectedTabIndex = tab.ordinal, containerColor = MaterialTheme.colorScheme.background) {
            for (t in DocTab.entries) {
                val count = when (t) {
                    DocTab.Doc -> 0
                    DocTab.Comments -> threads.size
                    DocTab.Decisions -> decisions.count { it.status == DecisionStatus.Proposed }
                }
                Tab(selected = t == tab, onClick = { onTab(t) }, text = { Text(if (count > 0) "${t.title} · $count" else t.title) })
            }
        }
        when (tab) {
            DocTab.Doc -> DocWebView(store, doc, threads, decisions, openTask)
            DocTab.Comments -> CommentsTab(store, doc, threads)
            DocTab.Decisions -> DecisionsTab(store, decisions)
        }
    }
}

// Doc tab: the embed

/** The bundled embed (assets/docs) is served from this origin, so its ES module imports load. */
private const val ASSET_HOST = "appassets.androidplatform.net"

@SuppressLint("SetJavaScriptEnabled")
@Composable
private fun DocWebView(store: FactoryStore, doc: Doc, threads: List<DocThread>, decisions: List<Decision>, openTask: (String) -> Unit) {
    val dark = isSystemInDarkTheme()
    val demo = store.status == FactoryStore.Status.Demo
    val theme = if (dark) "dark" else "light"
    // The demo's threads have placeholder anchors, so the offline embed gets none to draw.
    val threadsJson = if (demo) "[]" else WireJson.encodeToString(ListSerializer(DocThread.serializer()), threads)
    val decisionsJson = WireJson.encodeToString(ListSerializer(Decision.serializer()), decisions)
    val currentThreads by rememberUpdatedState(threadsJson)
    val currentDecisions by rememberUpdatedState(decisionsJson)
    val currentOpenTask by rememberUpdatedState(openTask)
    var web by remember { mutableStateOf<WebView?>(null) }
    var ready by remember { mutableStateOf(false) }

    fun person(member: Member?, login: String) = buildJsonObject {
        put("login", login)
        member?.name?.let { put("name", it) }
        member?.avatarUrl?.let { put("avatar", it) }
    }

    fun loadArgs(): String = buildJsonObject {
        put("docId", doc.id)
        put("me", person(store.feed.me, store.me.ifEmpty { "me" }))
        put("members", buildJsonArray { for (m in store.feed.members) add(person(m, m.login)) })
        put("threads", WireJson.parseToJsonElement(currentThreads))
        put("decisions", WireJson.parseToJsonElement(currentDecisions))
        if (demo) put("demo", buildJsonObject { put("markdown", if (doc.id == DemoData.DOC_ID) DemoData.DOC_MARKDOWN else "# ${doc.title}\n") })
        else store.docToken?.let { put("token", it) }
    }.toString()

    LaunchedEffect(threadsJson, ready) { if (ready) web?.evaluateJavascript("window.mapleDocs?.updateThreads($threadsJson)", null) }
    LaunchedEffect(decisionsJson, ready) { if (ready) web?.evaluateJavascript("window.mapleDocs?.updateDecisions($decisionsJson)", null) }
    DisposableEffect(doc.id) {
        onDispose { web?.evaluateJavascript("window.mapleDocs?.destroy()", null) }
    }

    val main = remember { Handler(Looper.getMainLooper()) }
    AndroidView(
        modifier = Modifier.fillMaxSize(),
        factory = { context ->
            WebView(context).apply {
                settings.javaScriptEnabled = true
                settings.domStorageEnabled = true
                setBackgroundColor(android.graphics.Color.TRANSPARENT)
                webViewClient = object : WebViewClient() {
                    override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
                        val url = request.url
                        if (url.host != ASSET_HOST) return null
                        val name = url.path?.removePrefix("/docs/")?.takeIf { it.isNotEmpty() && !it.contains("..") } ?: return null
                        val mime = when {
                            name.endsWith(".js") -> "text/javascript"
                            name.endsWith(".css") -> "text/css"
                            else -> "text/html"
                        }
                        return runCatching { WebResourceResponse(mime, "utf-8", view.context.assets.open("docs/$name")) }.getOrNull()
                    }
                }
                // The embed's post() calls MapleAndroid.postMessage(json) on a binder thread.
                addJavascriptInterface(object {
                    @JavascriptInterface
                    fun postMessage(json: String) {
                        main.post {
                            val msg = runCatching { WireJson.parseToJsonElement(json).jsonObject }.getOrNull() ?: return@post
                            when ((msg["type"] as? JsonPrimitive)?.content) {
                                "ready" -> {
                                    ready = true
                                    evaluateJavascript("mapleDocs.load(${loadArgs()})", null)
                                }
                                "command" -> (msg["command"] as? JsonObject)?.let { store.sendDocCommand(it.toString()) }
                                "openTask" -> msg["id"]?.jsonPrimitive?.content?.let { currentOpenTask(it) }
                                "error" -> store.notice = dev.maplefactory.kit.FeedState.Notice.Error(msg["message"]?.jsonPrimitive?.content ?: "The doc couldn't be opened.")
                            }
                        }
                    }
                }, "MapleAndroid")
                val url = if (demo) "https://$ASSET_HOST/docs/embed.html?theme=$theme"
                else Uri.parse(store.server ?: "").buildUpon().appendEncodedPath("app/docs/embed").appendQueryParameter("theme", theme).build().toString()
                loadUrl(url)
                web = this
            }
        },
    )
}

// Comments tab

@Composable
private fun CommentsTab(store: FactoryStore, doc: Doc, threads: List<DocThread>) {
    if (threads.isEmpty()) {
        EmptyState("No open comments", Icons.Outlined.ChatBubbleOutline, "Select text in the doc to comment on it.")
        return
    }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        items(threads, key = { it.id }) { ThreadCard(store, doc, it) }
    }
}

@Composable
private fun ThreadCard(store: FactoryStore, doc: Doc, thread: DocThread) {
    var reply by remember(thread.id) { mutableStateOf("") }
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(MaterialTheme.colorScheme.surfaceContainerLow).padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        thread.anchor?.quote?.takeIf { it.isNotBlank() }?.let { quote ->
            Row {
                Box(Modifier.width(3.dp).size(width = 3.dp, height = 20.dp).background(Maple.accent.color))
                Text(quote, Modifier.padding(start = 8.dp), color = secondaryText, fontStyle = FontStyle.Italic, maxLines = 3, overflow = TextOverflow.Ellipsis)
            }
        }
        for (comment in thread.comments) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Avatar(store, comment.author, 24.dp)
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(store.feed.member(comment.author)?.name ?: comment.author, fontWeight = FontWeight.SemiBold, style = MaterialTheme.typography.bodyMedium)
                        comment.agent?.let { AgentBadge(it) }
                        Text(When.ago(comment.at), style = MaterialTheme.typography.bodySmall, color = tertiaryText)
                    }
                    Text(comment.text, style = MaterialTheme.typography.bodyMedium)
                }
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(reply, { reply = it }, Modifier.weight(1f), placeholder = { Text("Reply") }, singleLine = true)
            IconButton(onClick = {
                store.docReply(doc.id, thread.id, reply.trim())
                reply = ""
            }, enabled = reply.isNotBlank()) { Icon(Icons.AutoMirrored.Filled.Send, "Send") }
        }
        Row {
            Spacer(Modifier.weight(1f))
            OutlinedButton(onClick = { store.docResolve(doc.id, thread.id) }) {
                Icon(Icons.Filled.Check, null, Modifier.size(16.dp))
                Text("Resolve", Modifier.padding(start = 6.dp))
            }
        }
    }
}

@Composable
private fun AgentBadge(agent: String) {
    Text(
        agent,
        Modifier.clip(RoundedCornerShape(5.dp)).background(Maple.accent.color.copy(alpha = 0.14f)).padding(horizontal = 6.dp, vertical = 1.dp),
        color = Maple.accent.color, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, maxLines = 1,
    )
}

// Decisions tab

@Composable
private fun DecisionsTab(store: FactoryStore, decisions: List<Decision>) {
    if (decisions.isEmpty()) {
        EmptyState("No decisions", Icons.Outlined.Gavel, "Propose one from the doc on the Mac.")
        return
    }
    val sorted = dev.maplefactory.kit.FeedState.filterDecisions(decisions, dev.maplefactory.kit.FeedState.DecisionFilter.All)
        .sortedBy { if (it.status == DecisionStatus.Proposed) 0 else 1 }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        items(sorted, key = { it.id }) { DecisionCard(store, it) }
    }
}

@Composable
private fun DecisionCard(store: FactoryStore, decision: Decision) {
    var accepting by remember { mutableStateOf(false) }
    var rejecting by remember { mutableStateOf(false) }
    val (statusText, statusColor) = when (decision.status) {
        DecisionStatus.Proposed -> "Proposed" to Maple.warning.color
        DecisionStatus.Accepted -> "Accepted" to Maple.approve.color
        DecisionStatus.Rejected -> "Rejected" to MaterialTheme.colorScheme.error
        DecisionStatus.Superseded -> "Superseded" to secondaryText
        DecisionStatus.Unknown -> "Unknown" to secondaryText
    }
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(MaterialTheme.colorScheme.surfaceContainerLow).padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(statusText, Modifier.clip(RoundedCornerShape(5.dp)).background(statusColor.copy(alpha = 0.14f)).padding(horizontal = 6.dp, vertical = 1.dp),
                color = statusColor, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
            decision.agent?.let { AgentBadge(it) }
            Spacer(Modifier.weight(1f))
            Text("${decision.proposedBy} · ${When.ago(decision.proposedAt)}", style = MaterialTheme.typography.bodySmall, color = tertiaryText)
        }
        Text(decision.question, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        for (option in decision.options) {
            val chosen = option.id == decision.chosen
            Row(
                Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp))
                    .background(if (chosen) statusColor.copy(alpha = 0.10f) else MaterialTheme.colorScheme.surfaceContainerHigh).padding(10.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Icon(if (chosen) Icons.Filled.Check else Icons.Outlined.Description, null, Modifier.size(16.dp).padding(top = 2.dp),
                    tint = if (chosen) statusColor else Color.Transparent)
                Column {
                    Text(option.label, fontWeight = if (chosen) FontWeight.SemiBold else FontWeight.Normal)
                    option.note?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = secondaryText) }
                }
            }
        }
        if (decision.rationale.isNotBlank()) {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text("Rationale", style = MaterialTheme.typography.labelMedium, color = secondaryText)
                Text(decision.rationale, style = MaterialTheme.typography.bodyMedium)
            }
        }
        decision.decidedBy?.let { by ->
            Text("$statusText by $by${decision.decidedAt?.let { " · ${When.ago(it)} ago" } ?: ""}${decision.why?.let { ": $it" } ?: ""}",
                style = MaterialTheme.typography.bodySmall, color = secondaryText)
        }
        if (decision.status == DecisionStatus.Proposed) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Spacer(Modifier.weight(1f))
                OutlinedButton(onClick = { rejecting = true }) {
                    Icon(Icons.Filled.Close, null, Modifier.size(16.dp))
                    Text("Reject", Modifier.padding(start = 6.dp))
                }
                Button(onClick = { accepting = true }) {
                    Icon(Icons.Filled.Check, null, Modifier.size(16.dp))
                    Text("Accept", Modifier.padding(start = 6.dp))
                }
            }
        }
    }
    if (accepting) AcceptDialog(decision, onDismiss = { accepting = false }) { chosen, why ->
        accepting = false
        store.acceptDecision(decision.id, chosen, why)
    }
    if (rejecting) WhyDialog("Reject decision?", "Reject", onDismiss = { rejecting = false }) { why ->
        rejecting = false
        store.rejectDecision(decision.id, why)
    }
}

@Composable
private fun AcceptDialog(decision: Decision, onDismiss: () -> Unit, onAccept: (String?, String?) -> Unit) {
    var chosen by remember { mutableStateOf(decision.chosen ?: decision.options.firstOrNull()?.id) }
    var why by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Accept decision") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                for (option in decision.options) {
                    Row(
                        Modifier.fillMaxWidth().selectable(selected = chosen == option.id, onClick = { chosen = option.id }),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        RadioButton(selected = chosen == option.id, onClick = { chosen = option.id })
                        Text(option.label)
                    }
                }
                OutlinedTextField(why, { why = it }, Modifier.fillMaxWidth().padding(top = 8.dp), placeholder = { Text("Why (optional)") })
            }
        },
        confirmButton = { TextButton(onClick = { onAccept(chosen, why.trim().ifEmpty { null }) }) { Text("Accept") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
private fun WhyDialog(title: String, action: String, onDismiss: () -> Unit, onConfirm: (String?) -> Unit) {
    var why by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { OutlinedTextField(why, { why = it }, Modifier.fillMaxWidth(), placeholder = { Text("Why (optional)") }) },
        confirmButton = { TextButton(onClick = { onConfirm(why.trim().ifEmpty { null }) }) { Text(action) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

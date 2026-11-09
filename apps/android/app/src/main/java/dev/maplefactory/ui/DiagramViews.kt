package dev.maplefactory.ui

import android.annotation.SuppressLint
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import dev.maplefactory.wire.Diagram
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

// MF-358: the planner's Mermaid diagrams. Each renders in the shared viewer page (assets/mermaid, synced from
// the repo's assets/mermaid by scripts/sync-mermaid.mjs) in a WebView that blocks every network load: a fitted
// card in the task, and a full-screen Dialog that pinches, pans and searches.

/** The bundled viewer page. Mode, theme and source go in through its `mapleDiagram.render`. */
const val DIAGRAM_PAGE = "file:///android_asset/mermaid/diagram.html"

/** The script that hands `source` to the loaded viewer page. */
fun diagramRenderScript(source: String, viewer: Boolean, dark: Boolean): String {
    val input = buildJsonObject {
        put("source", source)
        put("mode", if (viewer) "viewer" else "inline")
        put("theme", if (dark) "dark" else "light")
    }.toString().replace("</", "<\\/")
    return "window.mapleDiagram && window.mapleDiagram.render($input);"
}

/** Only the bundled page (and what it bundles) loads; anything else gets an empty answer and links go nowhere. */
fun isBundledDiagramUrl(url: String): Boolean = url.startsWith("file:///android_asset/mermaid/") && !url.contains("..")

@SuppressLint("SetJavaScriptEnabled")
@Composable
private fun DiagramWebView(diagram: Diagram, viewer: Boolean, modifier: Modifier) {
    val dark = isSystemInDarkTheme()
    val script = diagramRenderScript(diagram.source, viewer, dark)
    AndroidView(
        factory = { context ->
            WebView(context).apply {
                settings.javaScriptEnabled = true
                settings.blockNetworkLoads = true
                settings.allowFileAccess = false
                settings.allowContentAccess = false
                settings.setSupportZoom(false)
                settings.builtInZoomControls = false
                setBackgroundColor(android.graphics.Color.TRANSPARENT)
                isClickable = viewer
                isFocusable = viewer
                if (!viewer) setOnTouchListener { _, _ -> false }
                webViewClient = object : WebViewClient() {
                    override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest) = true
                    override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? =
                        if (isBundledDiagramUrl(request.url.toString())) null else WebResourceResponse("text/plain", "utf-8", null)
                    override fun onPageFinished(view: WebView, url: String?) {
                        (view.tag as? String)?.let { view.evaluateJavascript(it, null) }
                    }
                }
                tag = script
                loadUrl(DIAGRAM_PAGE)
            }
        },
        update = { view ->
            if (view.tag != script) {
                view.tag = script
                view.evaluateJavascript(script, null)
            }
        },
        modifier = modifier,
    )
}

/** A diagram in the task: fitted, with its notes; tapping it opens the full-screen viewer. */
@Composable
fun DiagramCardContent(diagram: Diagram) {
    var open by remember { mutableStateOf(false) }
    Box(Modifier.fillMaxWidth().height(260.dp).clip(RoundedCornerShape(10.dp))) {
        DiagramWebView(diagram, viewer = false, modifier = Modifier.fillMaxSize())
        // Over the web view, so a tap anywhere on the card opens it instead of reaching the page.
        Box(Modifier.fillMaxSize().clickable { open = true })
    }
    for (note in diagram.notes) Text("• $note", style = MaterialTheme.typography.bodySmall, color = secondaryText)
    TextButton(onClick = { open = true }) { Text("Open") }
    if (open) DiagramViewerDialog(diagram) { open = false }
}

/** Full screen: pinch to zoom, drag to pan, and the page's search box steps through the matches. */
@Composable
fun DiagramViewerDialog(diagram: Diagram, onClose: () -> Unit) {
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.surface) {
            Column(Modifier.fillMaxSize().statusBarsPadding()) {
                Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(diagram.title, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                    TextButton(onClick = onClose) { Text("Done") }
                }
                DiagramWebView(diagram, viewer = true, modifier = Modifier.fillMaxSize())
            }
        }
    }
}

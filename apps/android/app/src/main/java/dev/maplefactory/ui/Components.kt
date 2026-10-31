package dev.maplefactory.ui

import android.graphics.BitmapFactory
import android.util.LruCache
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Error
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.PlatformTextStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.LineHeightStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.maplefactory.FactoryStore
import dev.maplefactory.kit.FactoryApi
import dev.maplefactory.kit.FeedState
import dev.maplefactory.wire.TaskState
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import okhttp3.Request

/** Images fetched once and kept: avatars, factory icons and proof screenshots. */
object Images {
    private val cache = LruCache<String, ImageBitmap>(64)

    fun cached(url: String): ImageBitmap? = cache.get(url)

    /** [url]'s image; [request] adds the factory's token for its own files. */
    suspend fun load(url: String, request: Request.Builder = Request.Builder().url(url)): ImageBitmap? {
        cache.get(url)?.let { return it }
        return withContext(Dispatchers.IO) {
            runCatching {
                FactoryApi.client.newCall(request.build()).execute().use { response ->
                    if (!response.isSuccessful) return@use null
                    val bytes = response.body.bytes()
                    BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap()
                }
            }.getOrNull()?.also { cache.put(url, it) }
        }
    }
}

/** An image from [url] (or the factory's [request] for it), with [placeholder] until it loads. */
@Composable
fun RemoteImage(url: String, modifier: Modifier = Modifier, request: Request.Builder? = null, contentScale: ContentScale = ContentScale.Crop, placeholder: @Composable () -> Unit) {
    var image by remember(url) { mutableStateOf(Images.cached(url)) }
    LaunchedEffect(url) { if (image == null) image = Images.load(url, request ?: Request.Builder().url(url)) }
    val loaded = image
    if (loaded != null) Image(loaded, contentDescription = null, modifier = modifier, contentScale = contentScale) else placeholder()
}

/** A letter centered in a tile: no font padding, one line exactly as tall as the type. */
fun tileLetter(size: Float) = TextStyle(
    fontSize = size.sp,
    lineHeight = size.sp,
    platformStyle = PlatformTextStyle(includeFontPadding = false),
    lineHeightStyle = LineHeightStyle(LineHeightStyle.Alignment.Center, LineHeightStyle.Trim.Both),
)

/** A member's GitHub avatar, or their initial. */
@Composable
fun Avatar(login: String, url: String?, size: Dp = 22.dp) {
    val modifier = Modifier.size(size).clip(CircleShape)
    val initial = @Composable {
        Box(modifier.background(Brush.verticalGradient(listOf(Maple.accent.color.copy(alpha = 0.85f), Maple.accent.color))), contentAlignment = Alignment.Center) {
            Text(login.take(1).uppercase(), color = Color.White, fontWeight = FontWeight.SemiBold, style = tileLetter(size.value * 0.5f))
        }
    }
    if (url.isNullOrBlank()) initial() else RemoteImage(url, modifier, placeholder = initial)
}

@Composable
fun Avatar(store: FactoryStore, login: String, size: Dp = 22.dp) = Avatar(login, store.feed.member(login)?.avatarUrl, size)

/** A task's state as a small colored pill. */
@Composable
fun StatePill(state: TaskState) {
    val color = Maple.state(state)
    Row(
        Modifier.clip(CircleShape).background(color.copy(alpha = 0.14f)).padding(horizontal = 8.dp, vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Icon(state.icon, null, Modifier.size(12.dp), tint = color)
        Text(state.title, style = MaterialTheme.typography.labelMedium, color = color)
    }
}

/** A titled card, like the iPhone app's. */
@Composable
fun Card(title: String, icon: ImageVector, modifier: Modifier = Modifier, tint: Color = MaterialTheme.colorScheme.onSurface, content: @Composable ColumnScope.() -> Unit) {
    Column(
        modifier.fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(MaterialTheme.colorScheme.surfaceContainerLow)
            .border(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f), RoundedCornerShape(14.dp))
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(icon, null, Modifier.size(18.dp), tint = tint)
            Text(title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
        }
        content()
    }
}

val secondaryText: Color @Composable get() = MaterialTheme.colorScheme.onSurfaceVariant
val tertiaryText: Color @Composable get() = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f)

object When {
    /** "now", "5m", "3h", "2d" since [ms]. */
    fun ago(ms: Long, now: Long = System.currentTimeMillis()): String {
        val seconds = maxOf(0L, (now - ms) / 1000)
        return when {
            seconds < 60 -> "now"
            seconds < 3600 -> "${seconds / 60}m"
            seconds < 86400 -> "${seconds / 3600}h"
            else -> "${seconds / 86400}d"
        }
    }
}

/** The connection's state, under the title while it isn't live. */
@Composable
fun ConnectionBar(store: FactoryStore) {
    val (text, color) = when (val status = store.status) {
        FactoryStore.Status.Connecting -> "Connecting…" to secondaryText
        is FactoryStore.Status.Reconnecting -> "${status.reason} Reconnecting (${status.attempt})…" to Maple.warning.color
        FactoryStore.Status.TooNew -> FactoryApi.TOO_NEW to Maple.danger.color
        FactoryStore.Status.Demo -> "Demo factory: sample data, nothing is sent" to Maple.accent.color
        else -> return
    }
    Text(text, style = MaterialTheme.typography.bodySmall, color = color, modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp))
}

/** The feed's latest toast or error, for a few seconds. */
@Composable
fun NoticeBanner(store: FactoryStore, modifier: Modifier = Modifier) {
    val notice = store.notice ?: return
    val (text, icon, color) = when (notice) {
        is FeedState.Notice.Toast -> Triple(notice.text, Icons.Filled.CheckCircle, Maple.approve.color)
        is FeedState.Notice.Error -> Triple(notice.text, Icons.Filled.Error, Maple.danger.color)
    }
    LaunchedEffect(notice) {
        delay(3000)
        if (store.notice == notice) store.notice = null
    }
    Surface(modifier.padding(top = 4.dp), shape = CircleShape, color = color, shadowElevation = 6.dp) {
        Row(Modifier.padding(horizontal = 16.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(icon, null, tint = Color.White, modifier = Modifier.size(18.dp))
            Text(text, color = Color.White, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium)
        }
    }
}

/** A section's header in a list: icon, title, count. */
@Composable
fun SectionHeader(title: String, icon: ImageVector? = null, color: Color = secondaryText) {
    Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 18.dp, bottom = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        if (icon != null) Icon(icon, null, Modifier.size(16.dp), tint = color)
        Text(title, style = MaterialTheme.typography.labelLarge, color = color, fontWeight = FontWeight.SemiBold)
    }
}

/** An empty state: an icon, a title and a line. */
@Composable
fun EmptyState(title: String, icon: ImageVector, detail: String? = null, modifier: Modifier = Modifier) {
    Column(modifier.fillMaxWidth().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Icon(icon, null, Modifier.size(40.dp), tint = tertiaryText)
        Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        if (detail != null) Text(detail, style = MaterialTheme.typography.bodyMedium, color = secondaryText)
    }
}

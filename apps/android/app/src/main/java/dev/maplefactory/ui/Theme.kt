package dev.maplefactory.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AlternateEmail
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Construction
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.Inbox
import androidx.compose.material.icons.filled.PanTool
import androidx.compose.material.icons.filled.QuestionAnswer
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.PanTool
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import dev.maplefactory.kit.InboxEntry
import dev.maplefactory.wire.TaskState

/** A color that resolves per appearance, like Theme.swift's `Color(light:dark:)`. */
class Tone(private val light: Long, private val dark: Long) {
    val color: Color
        @Composable @ReadOnlyComposable get() = rgb(if (isSystemInDarkTheme()) dark else light)
}

/** An opaque color from 0xRRGGBB. */
fun rgb(hex: Long): Color = Color(0xFF000000 or hex)

/** A goal's "#RRGGBB". */
fun goalColor(hex: String?): Color = rgb(hex?.trimStart('#')?.toLongOrNull(16) ?: 0x8A909A)

/** The Mac app's palette, as the iPhone app has it. */
object Maple {
    val accent = Tone(0xD24E26, 0xFF7A48)
    val approve = Tone(0x1F883D, 0x2EA043)
    val warning = Tone(0xB7791F, 0xE2A93B)
    val mention = Tone(0xD9488F, 0xF07AB4)
    val danger = Tone(0xC8474B, 0xD9696C)

    private val drafting = Tone(0x8A909A, 0x8B919B)
    private val planning = Tone(0x7C5CE0, 0xA48BFA)
    private val awaitingApproval = Tone(0xC27C0E, 0xE9B04A)
    private val backlog = Tone(0x5B6B86, 0x93A3BF)
    private val building = Tone(0x2F6FEB, 0x6B9BF5)
    private val reviewing = Tone(0x0E8FA3, 0x4CC4D6)
    private val merged = Tone(0x14A866, 0x3DD68C)
    private val closed = Tone(0x6B7079, 0xA4AAB4)

    @Composable @ReadOnlyComposable
    fun state(state: TaskState): Color = when (state) {
        TaskState.Drafting -> drafting
        TaskState.Planning -> planning
        TaskState.AwaitingApproval -> awaitingApproval
        TaskState.Backlog -> backlog
        TaskState.Building -> building
        TaskState.Reviewing -> reviewing
        TaskState.Merged -> merged
        TaskState.Closed -> closed
        TaskState.Cancelled, TaskState.Unknown -> danger
    }.color
}

val TaskState.title: String
    get() = when (this) {
        TaskState.Drafting -> "Drafting"
        TaskState.Planning -> "Planning"
        TaskState.AwaitingApproval -> "Awaiting approval"
        TaskState.Backlog -> "Backlog"
        TaskState.Building -> "Building"
        TaskState.Reviewing -> "Reviewing"
        TaskState.Merged -> "Merged"
        TaskState.Cancelled -> "Cancelled"
        TaskState.Closed -> "Closed"
        TaskState.Unknown -> "Unknown"
    }

val TaskState.icon: ImageVector
    get() = when (this) {
        TaskState.Drafting -> Icons.Filled.Edit
        TaskState.Planning -> Icons.Outlined.AutoAwesome
        TaskState.AwaitingApproval -> Icons.Outlined.PanTool
        TaskState.Backlog -> Icons.Filled.Inbox
        TaskState.Building -> Icons.Filled.Construction
        TaskState.Reviewing -> Icons.Outlined.Visibility
        TaskState.Merged, TaskState.Closed -> Icons.Filled.CheckCircle
        TaskState.Cancelled, TaskState.Unknown -> Icons.Filled.Cancel
    }

val InboxEntry.Kind.icon: ImageVector
    get() = when (this) {
        InboxEntry.Kind.Approval -> Icons.Filled.PanTool
        InboxEntry.Kind.Hand -> Icons.Filled.Warning
        InboxEntry.Kind.Question -> Icons.Filled.QuestionAnswer
        InboxEntry.Kind.Review -> Icons.Filled.Visibility
        InboxEntry.Kind.Failing -> Icons.Filled.Error
        InboxEntry.Kind.Mention -> Icons.Filled.AlternateEmail
    }

val InboxEntry.Kind.color: Color
    @Composable @ReadOnlyComposable get() = when (this) {
        InboxEntry.Kind.Approval -> Maple.state(TaskState.AwaitingApproval)
        InboxEntry.Kind.Hand -> Maple.warning.color
        InboxEntry.Kind.Question -> Maple.state(TaskState.Planning)
        InboxEntry.Kind.Review -> Maple.state(TaskState.Reviewing)
        InboxEntry.Kind.Failing -> Maple.danger.color
        InboxEntry.Kind.Mention -> Maple.mention.color
    }

private val light = lightColorScheme(
    primary = rgb(0xD24E26),
    onPrimary = rgb(0xFFFFFF),
    primaryContainer = rgb(0xFBE3DA),
    onPrimaryContainer = rgb(0x5A1D08),
    secondary = rgb(0x6B5E57),
    secondaryContainer = rgb(0xFBE3DA),
    onSecondaryContainer = rgb(0x5A1D08),
    background = rgb(0xF7F5F2),
    surface = rgb(0xF7F5F2),
    surfaceContainerLowest = rgb(0xFFFFFF),
    surfaceContainerLow = rgb(0xFFFFFF),
    surfaceContainer = rgb(0xF1EEEA),
    surfaceContainerHigh = rgb(0xEBE7E2),
    error = rgb(0xC8474B),
)

private val dark = darkColorScheme(
    primary = rgb(0xFF7A48),
    onPrimary = rgb(0x2B0C00),
    primaryContainer = rgb(0x5A2412),
    onPrimaryContainer = rgb(0xFFDBCD),
    secondary = rgb(0xB8ABA4),
    secondaryContainer = rgb(0x5A2412),
    onSecondaryContainer = rgb(0xFFDBCD),
    background = rgb(0x141312),
    surface = rgb(0x141312),
    surfaceContainerLowest = rgb(0x0F0E0D),
    surfaceContainerLow = rgb(0x1D1B1A),
    surfaceContainer = rgb(0x221F1E),
    surfaceContainerHigh = rgb(0x2B2827),
    error = rgb(0xD9696C),
)

@Composable
fun MapleTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = if (isSystemInDarkTheme()) dark else light, content = content)
}

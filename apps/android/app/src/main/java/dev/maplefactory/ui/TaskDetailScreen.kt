package dev.maplefactory.ui

import android.annotation.SuppressLint
import android.content.Intent
import android.net.Uri
import android.webkit.WebView
import android.widget.MediaController
import android.widget.VideoView
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.CallMerge
import androidx.compose.material.icons.automirrored.filled.Comment
import androidx.compose.material.icons.automirrored.filled.FormatListBulleted
import androidx.compose.material.icons.automirrored.filled.Undo
import androidx.compose.material.icons.filled.BugReport
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Checklist
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.HourglassEmpty
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.PanTool
import androidx.compose.material.icons.filled.PauseCircle
import androidx.compose.material.icons.filled.QuestionAnswer
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.outlined.CallSplit
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material.icons.outlined.Navigation
import androidx.compose.material.icons.outlined.RateReview
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SecondaryTabRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import dev.maplefactory.FactoryStore
import dev.maplefactory.kit.DiffFile
import dev.maplefactory.kit.DiffLine
import dev.maplefactory.kit.FactoryApi
import dev.maplefactory.wire.CheckStatus
import dev.maplefactory.wire.CheckVerdict
import dev.maplefactory.wire.DoneItem
import dev.maplefactory.wire.Evidence
import dev.maplefactory.wire.FindingStatus
import dev.maplefactory.wire.Hand
import dev.maplefactory.wire.HandReason
import dev.maplefactory.wire.Mockup
import dev.maplefactory.wire.PlanStep
import dev.maplefactory.wire.ProofKind
import dev.maplefactory.wire.ProofStatus
import dev.maplefactory.wire.Question
import dev.maplefactory.wire.ReviewVerdict
import dev.maplefactory.wire.Severity
import dev.maplefactory.wire.StepProgress
import dev.maplefactory.wire.Task
import dev.maplefactory.wire.TaskState

private enum class Section(val title: String) { Overview("Overview"), Review("Review"), Diff("Diff"), Timeline("Timeline") }

/** A text box to send: request changes, answer, steer, comment. */
private data class Compose(val title: String, val placeholder: String, val send: String, val action: (String) -> Unit)

/**
 * One task: what it's for, its plan, mockups, review, checks, proofs, diff and timeline, with a bar
 * of whatever its stage lets you do: approve the plan, request changes, approve changes, merge or
 * hold, answer, steer and comment.
 */
@Composable
fun TaskDetailScreen(store: FactoryStore, id: String) {
    val task = store.feed.task(id)
    var section by rememberSaveable(id) { mutableStateOf(Section.Overview) }
    var compose by remember { mutableStateOf<Compose?>(null) }

    DisposableEffect(id) {
        store.viewing(id)
        onDispose { store.viewing(null) }
    }

    if (task == null) {
        // One the snapshot left out (finished over 14 days ago) is asked for, and shows when it comes.
        LaunchedEffect(id, store.feed.hasSnapshot) { store.fetchTask(id) }
        if (store.feed.hasSnapshot && id !in store.feed.fetching) EmptyState("Task not found", Icons.Filled.Cancel) else Loading()
        return
    }

    Column(Modifier.fillMaxSize()) {
        Column(
            Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Header(store, task)
            SecondaryTabRow(selectedTabIndex = section.ordinal, containerColor = Color.Transparent) {
                for (each in Section.entries) Tab(selected = section == each, onClick = { section = each }, text = { Text(each.title) })
            }
            when (section) {
                Section.Overview -> Overview(store, task)
                Section.Review -> ReviewSection(task)
                Section.Diff -> DiffSection(store, task)
                Section.Timeline -> TimelineSection(store, task)
            }
        }
        ActionBar(store, task) { compose = it }
    }

    compose?.let { ComposeSheet(it) { compose = null } }
}

@Composable
private fun Header(store: FactoryStore, task: Task) {
    val goal = store.feed.goal(task.goal)
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            goal?.let { Text(it.name, style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold, color = goalColor(it.color)) }
            StatePill(task.state)
        }
        Text(task.title, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Avatar(store, task.owner, 20.dp)
            Text(task.owner, style = MaterialTheme.typography.bodyMedium)
            Text(
                "· ${task.agent}${task.model?.let { " $it" } ?: ""} · updated ${When.ago(task.updatedAt)}",
                style = MaterialTheme.typography.bodyMedium, color = secondaryText,
            )
        }
        task.waiting?.let { Label(it, Icons.Filled.HourglassEmpty, secondaryText) }
    }
}

@Composable
private fun Label(text: String, icon: ImageVector, color: Color, style: androidx.compose.ui.text.TextStyle = MaterialTheme.typography.bodySmall) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Icon(icon, null, Modifier.size(16.dp), tint = color)
        Text(text, style = style, color = color)
    }
}

/** **bold**, *italic* and `code`, as the iPhone app's Text renders a brief or comment. */
fun inlineMarkdown(text: String): AnnotatedString = buildAnnotatedString {
    val pattern = Regex("""\*\*(.+?)\*\*|`([^`]+)`|\*(.+?)\*""")
    var at = 0
    for (match in pattern.findAll(text)) {
        append(text.substring(at, match.range.first))
        val (bold, code, italic) = match.destructured
        when {
            bold.isNotEmpty() -> withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append(bold) }
            code.isNotEmpty() -> withStyle(SpanStyle(fontFamily = FontFamily.Monospace, background = Color(0x22888888))) { append(code) }
            else -> withStyle(SpanStyle(fontStyle = FontStyle.Italic)) { append(italic) }
        }
        at = match.range.last + 1
    }
    append(text.substring(at))
}

// Overview

@Composable
private fun Overview(store: FactoryStore, task: Task) {
    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        task.hand?.let { HandCard(store, task, it) }
        task.question?.let { QuestionCard(store, task, it) }
        if (task.brief.isNotEmpty()) Card("Brief", Icons.Filled.Description) { Text(inlineMarkdown(task.brief), style = MaterialTheme.typography.bodyMedium) }
        if (task.plan.isNotEmpty()) {
            Card("Plan v${task.planVersion}", Icons.AutoMirrored.Filled.FormatListBulleted) {
                task.planSummary?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = secondaryText) }
                task.plan.forEachIndexed { index, step -> PlanStepRow(index + 1, step) }
                if (task.approvalsNeeded > 0) {
                    val who = if (task.approvals.isEmpty()) "" else ": " + task.approvals.joinToString(", ")
                    Label("${task.approvals.size} of ${task.approvalsNeeded} approvals$who", Icons.Filled.Verified, secondaryText)
                }
            }
        }
        if (task.doneWhen.isNotEmpty()) {
            Card("Done when", Icons.Filled.Checklist) { for (item in task.doneWhen) DoneItemRow(store, item) }
        }
        task.risk?.let { risk ->
            Card("Risk: ${risk.level.raw}", Icons.Filled.Shield) {
                for (reason in risk.reasons) Text("• $reason", style = MaterialTheme.typography.bodyMedium)
                task.footprint?.let {
                    Text("${it.files} files, ~${it.lines} lines${if (it.estimated) " (estimated)" else ""}", style = MaterialTheme.typography.bodySmall, color = secondaryText)
                }
            }
        }
        for (mockup in task.mockups) Card("Mockup: ${mockup.title}", Icons.Filled.Image) { MockupView(store, mockup) }
    }
}

@Composable
private fun PlanStepRow(number: Int, step: PlanStep) {
    val color = when (step.progress) {
        StepProgress.Done -> Maple.approve.color
        StepProgress.Active -> Maple.state(TaskState.Building)
        else -> secondaryText
    }
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Box(Modifier.size(22.dp).clip(CircleShape).background(color.copy(alpha = 0.15f)), contentAlignment = Alignment.Center) {
            if (step.progress == StepProgress.Done) Icon(Icons.Filled.Check, null, Modifier.size(12.dp), tint = color)
            else Text("$number", style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.Bold, color = color)
        }
        Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(step.text, style = MaterialTheme.typography.bodyMedium)
            Text(step.file, style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace, color = secondaryText)
            step.from?.let { Text("Was: $it", style = MaterialTheme.typography.bodySmall, textDecoration = TextDecoration.LineThrough, color = tertiaryText) }
            if (step.added) Text("New in this version", style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.SemiBold, color = Maple.approve.color)
        }
    }
}

@Composable
private fun DoneItemRow(store: FactoryStore, item: DoneItem) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            val (icon, color) = when (item.status) {
                ProofStatus.Proven -> Icons.Filled.CheckCircle to Maple.approve.color
                ProofStatus.Failed -> Icons.Filled.Cancel to Maple.danger.color
                else -> Icons.Outlined.Circle to secondaryText
            }
            Icon(icon, null, Modifier.size(18.dp), tint = color)
            Text(item.text, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
            Text(item.proof.raw, style = MaterialTheme.typography.labelSmall, color = secondaryText)
        }
        item.evidence?.let { EvidenceView(store, it) }
    }
}

/** Terminal lines on a dark panel: a proof's output or a terminal mockup. */
@Composable
private fun Terminal(lines: List<Pair<String, Color>>, command: String? = null) {
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp)).background(Color(0xFF1F1F1F)).horizontalScroll(rememberScrollState()).padding(10.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        command?.let { Text("$ $it", fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.Bold, color = Color.White) }
        for ((text, color) in lines) Text(text, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.labelSmall, color = color, softWrap = false)
    }
}

/** What proves a Done when item: terminal output, test counts, or an image or video. */
@Composable
private fun EvidenceView(store: FactoryStore, evidence: Evidence) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(evidence.summary, style = MaterialTheme.typography.bodySmall, color = secondaryText)
        evidence.passed?.let { passed ->
            val failed = evidence.failed ?: 0
            Text(
                "$passed passed${evidence.failed?.let { ", $it failed" } ?: ""}",
                style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold,
                color = if (failed > 0) Maple.danger.color else Maple.approve.color,
            )
        }
        if (evidence.command != null || evidence.output.isNotEmpty()) {
            Terminal(evidence.output.takeLast(12).map { it to Color.White.copy(alpha = 0.9f) }, evidence.command)
        }
        val file = evidence.file
        val api = store.api()
        if (file != null && api != null) {
            if (evidence.kind == ProofKind.Video) {
                AndroidView(
                    factory = { context ->
                        VideoView(context).apply {
                            setMediaController(MediaController(context).also { it.setAnchorView(this) })
                            setVideoURI(Uri.parse(FactoryApi.join(api.server, file)), mapOf("Authorization" to "Bearer ${api.token}"))
                        }
                    },
                    modifier = Modifier.fillMaxWidth().height(220.dp).clip(RoundedCornerShape(8.dp)),
                )
            } else {
                RemoteImage(
                    FactoryApi.join(api.server, file), Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp)),
                    request = api.request(file), contentScale = ContentScale.FillWidth,
                ) { Loading() }
            }
        }
    }
}

@Composable
private fun HandCard(store: FactoryStore, task: Task, hand: Hand) {
    Card("Raised hand: ${hand.reason.raw}", Icons.Filled.Warning, tint = Maple.warning.color) {
        Text(hand.summary, style = MaterialTheme.typography.bodyMedium)
        Text("For ${hand.assignee} · ${When.ago(hand.at)} ago", style = MaterialTheme.typography.bodySmall, color = secondaryText)
        for (option in hand.options) {
            OutlinedButton(
                onClick = { store.resolveHand(task.id, option.title, "") },
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(10.dp),
                colors = ButtonDefaults.outlinedButtonColors(contentColor = if (option.recommended) Maple.approve.color else MaterialTheme.colorScheme.onSurface),
            ) {
                Column(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                    Text(option.title + if (option.recommended) " (recommended)" else "", fontWeight = FontWeight.Medium)
                    Text(option.detail, style = MaterialTheme.typography.bodySmall, color = secondaryText)
                }
            }
        }
    }
}

@Composable
private fun QuestionCard(store: FactoryStore, task: Task, question: Question) {
    Card("The ${question.role.raw} asks", Icons.Filled.QuestionAnswer, tint = Maple.state(TaskState.Planning)) {
        Text(question.text, style = MaterialTheme.typography.bodyMedium)
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            for (option in question.options) OutlinedButton(onClick = { store.answer(task.id, option) }) { Text(option) }
        }
    }
}

/** A planner's mockup: a screen (HTML) in a web view with JavaScript off, or terminal lines. */
@SuppressLint("SetJavaScriptEnabled")
@Composable
private fun MockupView(store: FactoryStore, mockup: Mockup) {
    if (mockup.kind == "terminal") {
        val danger = Maple.danger.color
        Terminal(mockup.lines.map { it.text to when (it.style) { "error" -> danger; "dim" -> Color.Gray; else -> Color.White } })
    } else {
        val html = mockup.html
        val api = store.api()
        AndroidView(
            factory = { context ->
                WebView(context).apply {
                    settings.javaScriptEnabled = false
                    settings.allowFileAccess = false
                    setBackgroundColor(android.graphics.Color.TRANSPARENT)
                }
            },
            update = { view ->
                if (html != null) {
                    view.loadDataWithBaseURL(null, html, "text/html", "utf-8", null)
                } else if (mockup.url != null && api != null) {
                    view.loadUrl(FactoryApi.join(api.server, mockup.url!!), mapOf("Authorization" to "Bearer ${api.token}"))
                }
            },
            modifier = Modifier.fillMaxWidth().height(320.dp).clip(RoundedCornerShape(10.dp)),
        )
    }
    for (note in mockup.notes) Text("• $note", style = MaterialTheme.typography.bodySmall, color = secondaryText)
}

// Review

@Composable
private fun ReviewSection(task: Task) {
    val context = LocalContext.current
    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        val review = task.autoReview
        if (review == null) {
            EmptyState("No review yet", Icons.Outlined.Visibility, "The review agent reads the change once it's pushed.")
        } else {
            Card("Automatic review", Icons.Outlined.RateReview) {
                review.rounds.lastOrNull()?.let { round ->
                    val passed = round.verdict == ReviewVerdict.Passed
                    Label(
                        "Round ${round.number} of ${review.maxRounds}: ${round.verdict.raw}",
                        if (passed) Icons.Filled.Verified else Icons.Filled.Refresh,
                        if (passed) Maple.approve.color else Maple.warning.color,
                        MaterialTheme.typography.bodyMedium,
                    )
                }
                if (review.summary.isNotEmpty()) Text(review.summary, style = MaterialTheme.typography.bodyMedium)
                for (check in review.ask + review.proofs) {
                    val met = check.verdict == CheckVerdict.Met
                    Label(check.text, if (met) Icons.Filled.Check else Icons.Filled.Warning, if (met) Maple.approve.color else Maple.warning.color)
                }
            }
            if (review.findings.isNotEmpty()) {
                Card("Findings", Icons.Filled.BugReport) {
                    review.findings.forEachIndexed { index, finding ->
                        if (index > 0) HorizontalDivider()
                        Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                Text(
                                    finding.severity.raw, style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.Bold,
                                    color = if (finding.severity == Severity.Blocker) Maple.danger.color else Maple.warning.color,
                                )
                                Text(finding.kind.raw, style = MaterialTheme.typography.labelSmall, color = secondaryText)
                                Spacer(Modifier.weight(1f))
                                val fixed = finding.status == FindingStatus.Fixed
                                Text(
                                    if (fixed) "Fixed in round ${finding.fixedIn ?: 0}" else finding.status.raw,
                                    style = MaterialTheme.typography.labelSmall, color = if (fixed) Maple.approve.color else secondaryText,
                                )
                            }
                            Text(
                                finding.text, style = MaterialTheme.typography.bodyMedium,
                                textDecoration = if (finding.status == FindingStatus.Fixed) TextDecoration.LineThrough else null,
                            )
                            finding.file?.let { Text(it, style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace, color = secondaryText) }
                        }
                    }
                }
            }
        }
        task.pr?.let { pr ->
            Card("Pull request #${pr.number}", Icons.Outlined.CallSplit) {
                Text("${pr.branch} → ${pr.base} · ${pr.state.raw}", style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace, color = secondaryText)
                for (check in pr.checks) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        val (icon, color) = when (check.status) {
                            CheckStatus.Passed -> Icons.Filled.CheckCircle to Maple.approve.color
                            CheckStatus.Failed -> Icons.Filled.Cancel to Maple.danger.color
                            else -> Icons.Filled.Schedule to secondaryText
                        }
                        Icon(icon, null, Modifier.size(18.dp), tint = color)
                        Text(check.name, Modifier.weight(1f))
                        Text(check.duration ?: "", style = MaterialTheme.typography.bodySmall, color = secondaryText)
                    }
                }
                pr.url?.let { url ->
                    TextButton(onClick = { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }) { Text("Open on GitHub") }
                }
            }
        }
    }
}

// Diff

@Composable
private fun DiffSection(store: FactoryStore, task: Task) {
    val key = "${task.pr?.head ?: ""}-${task.diff?.added ?: 0}-${task.diff?.removed ?: 0}"
    LaunchedEffect(task.id, key) { store.loadDiff(task.id, key) }
    val files = store.diffs[task.id]?.second
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        when {
            files != null && files.isEmpty() -> EmptyState("No changes yet", Icons.Filled.Description)
            files != null -> for (file in files) DiffFileView(file)
            task.diff == null && task.pr == null -> EmptyState("No changes yet", Icons.Filled.Description, "The diff appears once the builder starts writing.")
            else -> Loading()
        }
    }
}

@Composable
private fun DiffFileView(file: DiffFile) {
    var open by remember(file.path) { mutableStateOf(true) }
    val added = Maple.approve.color
    val removed = Maple.danger.color
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).background(MaterialTheme.colorScheme.surfaceContainerLow),
    ) {
        Row(Modifier.fillMaxWidth().clickable { open = !open }.padding(10.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Icon(if (open) Icons.Filled.ExpandMore else Icons.Filled.KeyboardArrowRight, null, Modifier.size(16.dp))
            Text(file.path, Modifier.weight(1f), style = MaterialTheme.typography.labelMedium, fontFamily = FontFamily.Monospace, maxLines = 1, overflow = TextOverflow.StartEllipsis)
            Text("+${file.added}", style = MaterialTheme.typography.labelMedium, fontFamily = FontFamily.Monospace, color = added)
            Text("−${file.removed}", style = MaterialTheme.typography.labelMedium, fontFamily = FontFamily.Monospace, color = removed)
        }
        if (open) {
            Column(Modifier.horizontalScroll(rememberScrollState()).padding(bottom = 6.dp)) {
                for (hunk in file.hunks) {
                    Text(hunk.header, style = MaterialTheme.typography.labelSmall, fontFamily = FontFamily.Monospace, color = secondaryText, modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp))
                    for (line in hunk.lines) {
                        val background = when (line.kind) {
                            DiffLine.Kind.Added -> added.copy(alpha = 0.12f)
                            DiffLine.Kind.Removed -> removed.copy(alpha = 0.12f)
                            DiffLine.Kind.Context -> Color.Transparent
                        }
                        Row(Modifier.widthIn(min = 360.dp).background(background).padding(horizontal = 8.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            Text("${line.new ?: line.old ?: ""}", Modifier.width(30.dp), style = MaterialTheme.typography.labelSmall, fontFamily = FontFamily.Monospace, color = tertiaryText, textAlign = androidx.compose.ui.text.style.TextAlign.End)
                            Text(when (line.kind) { DiffLine.Kind.Added -> "+"; DiffLine.Kind.Removed -> "−"; else -> " " }, style = MaterialTheme.typography.labelSmall, fontFamily = FontFamily.Monospace)
                            Text(line.text, style = MaterialTheme.typography.labelSmall, fontFamily = FontFamily.Monospace, softWrap = false)
                        }
                    }
                }
            }
        }
    }
}

// Timeline

private sealed class Item(val at: Long) {
    class Event(val who: String, val text: String, at: Long) : Item(at)
    class Comment(val author: String, val text: String, at: Long) : Item(at)
    class Change(val author: String, val text: String, val status: String, at: Long) : Item(at)
}

@Composable
private fun TimelineSection(store: FactoryStore, task: Task) {
    val items = (task.events.map { Item.Event(it.who, it.text, it.at) } +
        task.comments.map { Item.Comment(it.author, it.text, it.at) } +
        task.changes.map { Item.Change(it.author, it.text, it.status.raw, it.at) }).sortedByDescending { it.at }
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (items.isEmpty()) EmptyState("Nothing yet", Icons.Filled.Schedule)
        for (item in items) {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                when (item) {
                    is Item.Event -> {
                        Box(Modifier.width(22.dp).padding(top = 7.dp), contentAlignment = Alignment.TopCenter) {
                            Box(Modifier.size(6.dp).clip(CircleShape).background(secondaryText))
                        }
                        Text(
                            buildAnnotatedString { withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append(item.who) }; append(" "); append(item.text) },
                            style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f),
                        )
                    }
                    is Item.Comment -> {
                        Avatar(store, item.author, 22.dp)
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text(item.author, style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold)
                            Text(inlineMarkdown(item.text), style = MaterialTheme.typography.bodyMedium)
                        }
                    }
                    is Item.Change -> {
                        Icon(Icons.AutoMirrored.Filled.Undo, null, Modifier.size(22.dp), tint = Maple.warning.color)
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text("${item.author} asked for changes · ${item.status}", style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold)
                            Text(item.text, style = MaterialTheme.typography.bodyMedium)
                        }
                    }
                }
                Text(When.ago(item.at), style = MaterialTheme.typography.labelMedium, color = tertiaryText)
            }
        }
    }
}

// Actions

@Composable
private fun ActionBar(store: FactoryStore, task: Task, compose: (Compose) -> Unit) {
    val me = store.me
    Surface(color = MaterialTheme.colorScheme.surfaceContainer, tonalElevation = 2.dp) {
        Row(
            Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (task.state == TaskState.AwaitingApproval && me !in task.approvals) {
                Action("Approve plan", Icons.Filled.Check, prominent = true) { store.approvePlan(task.id) }
                Action("Request changes", Icons.AutoMirrored.Filled.Undo) {
                    compose(Compose("Request changes to the plan", "What should the planner change?", "Send") { store.steer(task.id, it) })
                }
            }
            task.question?.let { question ->
                Action("Answer", Icons.Filled.QuestionAnswer, prominent = task.state != TaskState.AwaitingApproval) {
                    compose(Compose("Answer the agent", question.text, "Answer") { store.answer(task.id, it) })
                }
            }
            task.hand?.let { hand ->
                Action("Reply to hand", Icons.Filled.PanTool) {
                    compose(Compose("Help the agent", hand.summary, "Send") { store.resolveHand(task.id, null, it) })
                }
            }
            if (task.state == TaskState.Reviewing) {
                val approved = task.reviews.size >= task.reviewsNeeded
                if (me !in task.reviews) Action("Approve changes", Icons.Filled.Verified, prominent = true) { store.approveChanges(task.id) }
                if (task.mergeAt != null) Action("Hold merge", Icons.Filled.PauseCircle) { store.holdMerge(task.id) }
                if (approved) Action("Merge", Icons.AutoMirrored.Filled.CallMerge, prominent = me in task.reviews) { store.merge(task.id) }
                Action("Request changes", Icons.AutoMirrored.Filled.Undo) {
                    compose(Compose("Request changes", "What should the builder change?", "Request") { store.steer(task.id, it) })
                }
            }
            if (task.state == TaskState.Building || task.state == TaskState.Planning) {
                Action("Steer", Icons.Outlined.Navigation) {
                    val who = if (task.state == TaskState.Planning) "planner" else "builder"
                    compose(Compose("Steer the agent", "Redirect the $who…", "Send") { store.steer(task.id, it) })
                }
            }
            if (task.pr?.checks.orEmpty().any { it.status == CheckStatus.Failed } || task.hand?.reason == HandReason.SessionEnded) {
                Action("Retry", Icons.Filled.Refresh) { store.retryTask(task.id) }
            }
            Action("Comment", Icons.AutoMirrored.Filled.Comment) {
                compose(Compose("Comment on ${task.id}", "Write a comment; @mention people", "Comment") { store.comment(task.id, it) })
            }
        }
    }
}

@Composable
private fun Action(title: String, icon: ImageVector, prominent: Boolean = false, perform: () -> Unit) {
    if (prominent) {
        Button(onClick = perform, colors = ButtonDefaults.buttonColors(containerColor = Maple.approve.color, contentColor = Color.White)) {
            Icon(icon, null, Modifier.size(18.dp))
            Spacer(Modifier.size(6.dp))
            Text(title, fontWeight = FontWeight.SemiBold)
        }
    } else {
        OutlinedButton(onClick = perform) {
            Icon(icon, null, Modifier.size(18.dp))
            Spacer(Modifier.size(6.dp))
            Text(title)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ComposeSheet(compose: Compose, dismiss: () -> Unit) {
    var text by remember { mutableStateOf("") }
    val focus = remember { FocusRequester() }
    ModalBottomSheet(onDismissRequest = dismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = dismiss) { Text("Cancel") }
                Text(compose.title, Modifier.weight(1f), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                TextButton(onClick = { compose.action(text.trim()); dismiss() }, enabled = text.isNotBlank()) { Text(compose.send, fontWeight = FontWeight.SemiBold) }
            }
            OutlinedTextField(
                value = text,
                onValueChange = { text = it },
                placeholder = { Text(compose.placeholder) },
                minLines = 5,
                maxLines = 12,
                modifier = Modifier.fillMaxWidth().heightIn(min = 140.dp).focusRequester(focus),
            )
        }
    }
    LaunchedEffect(Unit) { focus.requestFocus() }
}

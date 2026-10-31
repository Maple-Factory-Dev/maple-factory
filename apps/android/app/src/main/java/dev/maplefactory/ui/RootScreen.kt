package dev.maplefactory.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowCircleDown
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Flag
import androidx.compose.material.icons.filled.Inbox
import androidx.compose.material.icons.filled.QuestionAnswer
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.outlined.Cancel
import androidx.compose.material.icons.outlined.Computer
import androidx.compose.material.icons.outlined.Flag
import androidx.compose.material.icons.outlined.Inbox
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DrawerValue
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalDrawerSheet
import androidx.compose.material3.ModalNavigationDrawer
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.rememberDrawerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.maplefactory.BuildConfig
import dev.maplefactory.FactoryStore
import dev.maplefactory.FactoryStore.Tab
import dev.maplefactory.LaunchArgs
import dev.maplefactory.kit.InboxEntry
import dev.maplefactory.kit.SavedFactory
import dev.maplefactory.wire.AgentState
import dev.maplefactory.wire.Goal
import dev.maplefactory.wire.Machine
import dev.maplefactory.wire.Task
import dev.maplefactory.wire.TaskState
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** A screen pushed onto a tab. */
sealed class Route {
    data class GoalPage(val id: String) : Route()
    data class TaskPage(val id: String) : Route()
}

/**
 * Signed in: Inbox, Goals, Machines and Settings, under a top bar whose factory avatar opens the
 * rail of saved factories. Each tab keeps its own stack of goal and task pages. `-tab`, `-goal`
 * and `-task` open a screen directly, for screenshots.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RootScreen(store: FactoryStore, args: LaunchArgs, onAddFactory: () -> Unit) {
    var tab by remember { mutableStateOf(Tab.Inbox) }
    val stacks = remember { mutableStateMapOf<Tab, List<Route>>() }
    var argsUsed by remember { mutableStateOf(false) }
    val drawer = rememberDrawerState(DrawerValue.Closed)
    val scope = rememberCoroutineScope()
    val stack = stacks[tab].orEmpty()

    fun push(route: Route) {
        stacks[tab] = stacks[tab].orEmpty() + route
    }

    // Each factory opens where you left it; the first one launched can be pointed somewhere by its flags.
    LaunchedEffect(store.opened) {
        stacks.clear()
        if (!argsUsed && (args.tab != null || args.goal != null || args.task != null)) {
            argsUsed = true
            tab = Tab.entries.firstOrNull { it.name.equals(args.tab, ignoreCase = true) } ?: Tab.Inbox
            if (tab == Tab.Goals) args.goal?.let { stacks[Tab.Goals] = listOf(Route.GoalPage(it)) }
            args.task?.let { store.pendingTask = it }
        } else {
            val place = store.place(store.currentKey)
            tab = place.tab
            place.goal?.let { stacks[Tab.Goals] = listOf(Route.GoalPage(it)) }
        }
    }

    // A task link, or -task, once the feed has the task: on the Goals tab under its goal, else in the inbox.
    LaunchedEffect(store.pendingTask, store.feed.hasSnapshot) {
        val id = store.pendingTask ?: return@LaunchedEffect
        val task = store.feed.task(id) ?: return@LaunchedEffect
        store.pendingTask = null
        if (tab == Tab.Goals) {
            stacks[Tab.Goals] = listOf(Route.GoalPage(task.goal), Route.TaskPage(id))
        } else {
            if (tab != Tab.Inbox) tab = Tab.Inbox
            stacks[Tab.Inbox] = listOf(Route.TaskPage(id))
        }
    }

    LaunchedEffect(tab, stacks[Tab.Goals]) {
        store.remember(tab, stacks[Tab.Goals].orEmpty().filterIsInstance<Route.GoalPage>().firstOrNull()?.id)
    }

    BackHandler(enabled = drawer.isOpen) { scope.launch { drawer.close() } }
    BackHandler(enabled = !drawer.isOpen && stack.isNotEmpty()) { stacks[tab] = stack.dropLast(1) }

    ModalNavigationDrawer(
        drawerState = drawer,
        drawerContent = {
            FactoryRail(store, onPick = { factory ->
                scope.launch { drawer.close() }
                store.switchTo(factory)
            }, onAdd = {
                scope.launch { drawer.close() }
                onAddFactory()
            })
        },
    ) {
        Scaffold(
            topBar = {
                val route = stack.lastOrNull()
                TopAppBar(
                    title = {
                        Text(
                            when (route) {
                                is Route.TaskPage -> route.id
                                is Route.GoalPage -> store.feed.goal(route.id)?.name ?: "Goal"
                                null -> when (tab) {
                                    Tab.Inbox -> "Inbox"
                                    Tab.Goals -> "Goals"
                                    Tab.Machines -> "Machines"
                                    Tab.Settings -> "Settings"
                                }
                            },
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            fontWeight = FontWeight.SemiBold,
                        )
                    },
                    navigationIcon = {
                        if (route != null) {
                            IconButton(onClick = { stacks[tab] = stack.dropLast(1) }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
                        } else {
                            val current = store.factories.firstOrNull { it.id == store.currentKey }
                            val others = store.factories.filter { it.id != store.currentKey }.sumOf { store.unread[it.id] ?: 0 }
                            IconButton(onClick = { scope.launch { drawer.open() } }) {
                                BadgedBox(badge = { if (others > 0) Badge() }) {
                                    FactoryTile(store, current, store.factoryName, size = 32.dp)
                                }
                            }
                        }
                    },
                    colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
                )
            },
            bottomBar = {
                NavigationBar {
                    val inbox = store.feed.inbox(store.me).count { it.assignee == store.me }
                    TabItem(Tab.Inbox, tab, "Inbox", Icons.Filled.Inbox, Icons.Outlined.Inbox, inbox) { tab = it }
                    TabItem(Tab.Goals, tab, "Goals", Icons.Filled.Flag, Icons.Outlined.Flag) { tab = it }
                    TabItem(Tab.Machines, tab, "Machines", Icons.Filled.Computer, Icons.Outlined.Computer) { tab = it }
                    TabItem(Tab.Settings, tab, "Settings", Icons.Filled.Settings, Icons.Outlined.Settings) { tab = it }
                }
            },
            containerColor = MaterialTheme.colorScheme.background,
        ) { padding ->
            Box(Modifier.padding(padding).fillMaxSize()) {
                when (val route = stack.lastOrNull()) {
                    is Route.TaskPage -> TaskDetailScreen(store, route.id)
                    is Route.GoalPage -> GoalScreen(store, route.id) { push(Route.TaskPage(it)) }
                    null -> when (tab) {
                        Tab.Inbox -> InboxScreen(store) { push(Route.TaskPage(it)) }
                        Tab.Goals -> GoalsScreen(store) { push(Route.GoalPage(it)) }
                        Tab.Machines -> MachinesScreen(store) { push(Route.TaskPage(it)) }
                        Tab.Settings -> SettingsScreen(store, onAddFactory)
                    }
                }
                NoticeBanner(store, Modifier.align(Alignment.TopCenter))
            }
        }
    }
}

@Composable
private fun androidx.compose.foundation.layout.RowScope.TabItem(
    tab: Tab, selected: Tab, label: String, on: androidx.compose.ui.graphics.vector.ImageVector,
    off: androidx.compose.ui.graphics.vector.ImageVector, badge: Int = 0, select: (Tab) -> Unit,
) {
    NavigationBarItem(
        selected = tab == selected,
        onClick = { select(tab) },
        icon = {
            BadgedBox(badge = { if (badge > 0) Badge { Text("$badge") } }) {
                Icon(if (tab == selected) on else off, label)
            }
        },
        label = { Text(label) },
    )
}

// Factory rail

/** A factory's icon, or a tile with its first letter in a color of its own. */
@Composable
fun FactoryTile(store: FactoryStore, factory: SavedFactory?, name: String, size: Dp = 44.dp) {
    val shape = RoundedCornerShape(size * 0.24f)
    val tiles = listOf(0xFFD24E26, 0xFF7C5CE0, 0xFF2F6FEB, 0xFF0E8FA3, 0xFF14A866, 0xFFC27C0E, 0xFFD9488F)
    val color = Color(tiles[Math.floorMod(name.lowercase().hashCode(), tiles.size)])
    val letter = @Composable {
        Box(Modifier.size(size).clip(shape).background(color), contentAlignment = Alignment.Center) {
            Text(name.take(1).uppercase(), color = Color.White, fontWeight = FontWeight.Bold, style = tileLetter(size.value * 0.45f))
        }
    }
    val icon = factory?.icon
    val api = factory?.let { store.api(it) }
    if (icon != null && api != null) {
        RemoteImage(dev.maplefactory.kit.FactoryApi.join(factory.server, icon), Modifier.size(size).clip(shape), request = api.request(icon), placeholder = letter)
    } else {
        letter()
    }
}

/** The rail of saved factories, like Slack's workspace switcher: switch, see what waits in each, add another. */
@Composable
fun FactoryRail(store: FactoryStore, onPick: (SavedFactory) -> Unit, onAdd: () -> Unit) {
    ModalDrawerSheet(Modifier.width(300.dp)) {
        Text("Factories", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, modifier = Modifier.padding(start = 20.dp, top = 24.dp, bottom = 12.dp))
        for (factory in store.factories) {
            val current = factory.id == store.currentKey
            val count = store.unread[factory.id] ?: 0
            Row(
                Modifier.fillMaxWidth().height(64.dp).clickable { onPick(factory) }
                    .background(if (current) MaterialTheme.colorScheme.primary.copy(alpha = 0.08f) else Color.Transparent),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                // The open factory's marker, as Slack draws it.
                Box(Modifier.width(4.dp).fillMaxHeight(0.6f).clip(RoundedCornerShape(topEnd = 3.dp, bottomEnd = 3.dp))
                    .background(if (current) MaterialTheme.colorScheme.primary else Color.Transparent))
                Spacer(Modifier.width(12.dp))
                Box(
                    if (current) Modifier.border(2.dp, MaterialTheme.colorScheme.primary, RoundedCornerShape(14.dp)).padding(3.dp) else Modifier.padding(3.dp),
                ) {
                    BadgedBox(badge = { if (count > 0) Badge { Text("$count") } }) {
                        FactoryTile(store, factory, factory.name)
                    }
                }
                Column(Modifier.weight(1f).padding(start = 12.dp, end = 12.dp)) {
                    Text(factory.name, fontWeight = if (current) FontWeight.SemiBold else FontWeight.Normal, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(factory.host, style = MaterialTheme.typography.bodySmall, color = secondaryText, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                if (current) Icon(Icons.Filled.CheckCircle, "Open", tint = MaterialTheme.colorScheme.primary, modifier = Modifier.padding(end = 16.dp).size(20.dp))
            }
        }
        HorizontalDivider(Modifier.padding(vertical = 8.dp))
        Row(
            Modifier.fillMaxWidth().height(60.dp).clickable(onClick = onAdd).padding(start = 19.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                Modifier.size(44.dp).clip(RoundedCornerShape(11.dp)).background(MaterialTheme.colorScheme.surfaceContainerHigh),
                contentAlignment = Alignment.Center,
            ) { Icon(Icons.Filled.Add, null) }
            Text("Add a factory", modifier = Modifier.padding(start = 12.dp))
        }
    }
}

// Shared list bits

/** Pull to refresh over [content]: a fresh socket, so a fresh snapshot. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun Refreshable(store: FactoryStore, content: @Composable () -> Unit) {
    var refreshing by remember { mutableStateOf(false) }
    LaunchedEffect(refreshing) {
        if (!refreshing) return@LaunchedEffect
        store.refresh()
        for (i in 0 until 30) {
            delay(100)
            if (i > 3 && store.status !is FactoryStore.Status.Connecting) break
        }
        refreshing = false
    }
    PullToRefreshBox(isRefreshing = refreshing, onRefresh = { refreshing = true }, modifier = Modifier.fillMaxSize()) { content() }
}

@Composable
private fun SearchField(value: String, placeholder: String, onChange: (String) -> Unit) {
    OutlinedTextField(
        value = value,
        onValueChange = onChange,
        placeholder = { Text(placeholder) },
        leadingIcon = { Icon(Icons.Filled.Search, null) },
        singleLine = true,
        shape = RoundedCornerShape(12.dp),
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
    )
}

/** A row in a list: the surface it sits on, tappable. */
@Composable
fun ListRow(onClick: (() -> Unit)? = null, content: @Composable () -> Unit) {
    Box(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 3.dp).clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surfaceContainerLow)
            .let { if (onClick != null) it.clickable(onClick = onClick) else it }
            .padding(horizontal = 14.dp, vertical = 12.dp),
    ) { content() }
}

// Inbox

@Composable
fun InboxScreen(store: FactoryStore, open: (String) -> Unit) {
    var mineOnly by remember { mutableStateOf(true) }
    var search by remember { mutableStateOf("") }
    val all = store.feed.inbox(store.me).filter { entry ->
        (!mineOnly || entry.assignee == store.me) && (search.isEmpty() || listOf(entry.task, entry.message, store.feed.task(entry.task)?.title ?: "").any { it.contains(search, ignoreCase = true) })
    }
    Refreshable(store) {
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 24.dp)) {
            item { ConnectionBar(store) }
            item {
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp)) {
                    SegmentedButton(mineOnly, { mineOnly = true }, SegmentedButtonDefaults.itemShape(0, 2)) { Text("For you") }
                    SegmentedButton(!mineOnly, { mineOnly = false }, SegmentedButtonDefaults.itemShape(1, 2)) { Text("Team") }
                }
            }
            item { SearchField(search, "Tasks, people, messages") { search = it } }
            if (!store.feed.hasSnapshot) item { Loading() }
            if (all.isEmpty() && store.feed.hasSnapshot) {
                item {
                    EmptyState(
                        "Nothing waiting on you", Icons.Filled.CheckCircle,
                        if (mineOnly) "Plans, reviews and questions for you land here." else "Nothing is waiting on the team.",
                    )
                }
            }
            for (kind in InboxEntry.Kind.entries) {
                val entries = all.filter { it.kind == kind }
                if (entries.isEmpty()) continue
                item(key = "h-$kind") { SectionHeader("${kind.title} · ${entries.size}", kind.icon, kind.color) }
                items(entries, key = { it.id }) { entry -> InboxRow(store, entry) { open(entry.task) } }
            }
        }
    }
}

@Composable
fun Loading() {
    Box(Modifier.fillMaxWidth().padding(48.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
}

@Composable
private fun InboxRow(store: FactoryStore, entry: InboxEntry, onClick: () -> Unit) {
    val task = store.feed.task(entry.task)
    val goal = task?.let { store.feed.goal(it.goal) }
    ListRow(onClick) {
        Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Box(Modifier.size(7.dp).clip(CircleShape).background(goalColor(goal?.color)))
                Text(entry.task, style = MaterialTheme.typography.labelMedium, fontFamily = FontFamily.Monospace, color = secondaryText)
                Spacer(Modifier.weight(1f))
                Text(When.ago(entry.at), style = MaterialTheme.typography.labelMedium, color = tertiaryText)
            }
            Text(task?.title ?: entry.task, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Medium, maxLines = 2, overflow = TextOverflow.Ellipsis)
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Avatar(store, entry.assignee, 16.dp)
                Text(entry.message, style = MaterialTheme.typography.bodyMedium, color = secondaryText, maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

// Goals

@Composable
fun GoalsScreen(store: FactoryStore, open: (String) -> Unit) {
    var search by remember { mutableStateOf("") }
    val goals = store.feed.activeGoals.filter { search.isEmpty() || it.name.contains(search, true) || it.prefix.contains(search, true) }
    val following = goals.filter { store.feed.following(it) }
    val others = goals.filter { !store.feed.following(it) }
    Refreshable(store) {
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 24.dp)) {
            item { ConnectionBar(store) }
            item { SearchField(search, "Goals") { search = it } }
            if (!store.feed.hasSnapshot) item { Loading() }
            if (store.feed.hasSnapshot && goals.isEmpty()) item { EmptyState("No goals yet", Icons.Outlined.Flag, "Make one in the Mac app.") }
            if (following.isNotEmpty()) {
                item { SectionHeader("Following") }
                items(following, key = { it.id }) { GoalRow(store, it) { open(it.id) } }
            }
            if (others.isNotEmpty()) {
                item { SectionHeader("Other goals") }
                items(others, key = { it.id }) { GoalRow(store, it) { open(it.id) } }
            }
        }
    }
}

@Composable
private fun GoalRow(store: FactoryStore, goal: Goal, onClick: () -> Unit) {
    val tasks = store.feed.tasks(goal.id)
    val open = tasks.count { it.state != TaskState.Merged && it.state != TaskState.Cancelled }
    ListRow(onClick) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Box(Modifier.width(48.dp).height(30.dp).clip(RoundedCornerShape(7.dp)).background(goalColor(goal.color)), contentAlignment = Alignment.Center) {
                Text(goal.prefix, color = Color.White, fontWeight = FontWeight.Bold, fontFamily = FontFamily.Monospace, fontSize = 12.sp, maxLines = 1)
            }
            Column(Modifier.weight(1f)) {
                Text(goal.name, fontWeight = FontWeight.Medium)
                Text("$open open · ${tasks.size - open} done", style = MaterialTheme.typography.bodySmall, color = secondaryText)
            }
            Avatar(store, goal.lead, 22.dp)
        }
    }
}

private val stages = listOf(
    TaskState.AwaitingApproval, TaskState.Planning, TaskState.Building, TaskState.Reviewing,
    TaskState.Drafting, TaskState.Backlog, TaskState.Merged, TaskState.Cancelled,
)

@Composable
fun GoalScreen(store: FactoryStore, id: String, open: (String) -> Unit) {
    val goal = store.feed.goal(id)
    if (goal == null) {
        if (store.feed.hasSnapshot) EmptyState("Goal not found", Icons.Outlined.Cancel) else Loading()
        return
    }
    val tasks = store.feed.tasks(id)
    Refreshable(store) {
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 24.dp)) {
            item {
                Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp).clip(RoundedCornerShape(12.dp)).background(MaterialTheme.colorScheme.surfaceContainerLow).padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    if (goal.summary.isNotEmpty()) Text(goal.summary, color = secondaryText)
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Lead", Modifier.weight(1f))
                        Avatar(store, goal.lead, 18.dp)
                        Text(goal.lead, Modifier.padding(start = 6.dp), color = secondaryText)
                    }
                    goal.repo?.let { repo ->
                        Row { Text("Repo", Modifier.weight(1f)); Text(repo, color = secondaryText) }
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Follow", Modifier.weight(1f))
                        Switch(checked = store.feed.following(goal), onCheckedChange = { store.follow(goal.id, it) })
                    }
                }
            }
            for (stage in stages) {
                val staged = tasks.filter { it.state == stage }
                if (staged.isEmpty()) continue
                item(key = "h-$stage") { SectionHeader("${stage.title} · ${staged.size}", stage.icon, Maple.state(stage)) }
                items(staged, key = { it.id }) { TaskRow(store, it) { open(it.id) } }
            }
        }
    }
}

@Composable
private fun TaskRow(store: FactoryStore, task: Task, onClick: () -> Unit) {
    ListRow(onClick) {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(task.id, style = MaterialTheme.typography.labelMedium, fontFamily = FontFamily.Monospace, color = secondaryText)
                if (task.hand != null) Icon(Icons.Filled.Warning, "Raised hand", Modifier.size(14.dp), tint = Maple.warning.color)
                if (task.question != null) Icon(Icons.Filled.QuestionAnswer, "Question", Modifier.size(14.dp), tint = Maple.state(TaskState.Planning))
                Spacer(Modifier.weight(1f))
                Avatar(store, task.owner, 18.dp)
            }
            Text(task.title, maxLines = 2, overflow = TextOverflow.Ellipsis)
            task.waiting?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = secondaryText) }
        }
    }
}

// Machines

@Composable
fun MachinesScreen(store: FactoryStore, open: (String) -> Unit) {
    val machines = store.feed.machines.sortedWith(compareBy({ !it.online }, { it.name }))
    Refreshable(store) {
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            item { ConnectionBar(store) }
            if (!store.feed.hasSnapshot) item { Loading() }
            if (store.feed.hasSnapshot && machines.isEmpty()) {
                item { EmptyState("No machines yet", Icons.Outlined.Computer, "Enroll a Mac from the Mac app's Machines page.") }
            }
            items(machines, key = { it.id }) { MachineCard(store, it, open) }
        }
    }
}

@Composable
private fun MachineCard(store: FactoryStore, machine: Machine, open: (String) -> Unit) {
    val online = if (machine.online) Maple.approve.color else secondaryText
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp).clip(RoundedCornerShape(12.dp)).background(MaterialTheme.colorScheme.surfaceContainerLow).padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Icon(Icons.Filled.Computer, null, tint = online)
            Column(Modifier.weight(1f)) {
                Text(machine.name, fontWeight = FontWeight.Medium)
                Text(listOfNotNull(machine.owner, machine.os, machine.version?.let { "runner $it" }).joinToString(" · "), style = MaterialTheme.typography.bodySmall, color = secondaryText)
            }
            Text(
                if (machine.online) "Online" else machine.lastSeen?.let { "Seen ${When.ago(it)} ago" } ?: "Offline",
                style = MaterialTheme.typography.labelMedium, color = online,
            )
        }
        if (store.feed.runnerOutdated(machine)) {
            store.feed.runnerLatest?.let { latest ->
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.ArrowCircleDown, null, Modifier.size(16.dp), tint = Maple.warning.color)
                    Text("Runner $latest is out", style = MaterialTheme.typography.bodySmall, color = Maple.warning.color)
                }
            }
        }
        machine.health?.let { health ->
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Meter("CPU", health.cpu, Modifier.weight(1f))
                Meter("Memory", health.memUsed.toDouble() / maxOf(health.memTotal, 1), Modifier.weight(1f))
                Meter("Disk", health.diskUsed.toDouble() / maxOf(health.diskTotal, 1), Modifier.weight(1f))
            }
            if (health.agents.isNotEmpty()) {
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    for (agent in health.agents) {
                        val color = if (agent.loggedIn) Maple.approve.color else Maple.danger.color
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                            Icon(if (agent.loggedIn) Icons.Filled.CheckCircle else Icons.Outlined.Cancel, null, Modifier.size(14.dp), tint = color)
                            Text("${agent.name} ${agent.version ?: ""}", style = MaterialTheme.typography.bodySmall, color = color)
                        }
                    }
                }
            }
        }
        for (live in machine.sessions) {
            val taskId = live.session.taskId
            Column(
                Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp)).background(MaterialTheme.colorScheme.surfaceContainer)
                    .let { if (taskId != null) it.clickable { open(taskId) } else it }.padding(10.dp),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(taskId ?: live.session.agent, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodyMedium)
                    Text(live.session.agent, style = MaterialTheme.typography.bodySmall, color = secondaryText)
                    Spacer(Modifier.weight(1f))
                    live.activity?.state?.let { state ->
                        Text(state.raw, style = MaterialTheme.typography.bodySmall, color = if (state == AgentState.Waiting) Maple.warning.color else secondaryText)
                    }
                }
                live.activity?.message?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = secondaryText) }
            }
        }
    }
}

@Composable
private fun Meter(title: String, value: Double, modifier: Modifier) {
    val clamped = value.coerceIn(0.0, 1.0).toFloat()
    Column(modifier, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row {
            Text(title, style = MaterialTheme.typography.labelSmall, color = secondaryText, modifier = Modifier.weight(1f))
            Text("${(value * 100).toInt()}%", style = MaterialTheme.typography.labelSmall)
        }
        LinearProgressIndicator(
            progress = { clamped },
            modifier = Modifier.fillMaxWidth().height(6.dp).clip(CircleShape),
            color = if (value > 0.85) Maple.danger.color else Maple.accent.color,
            drawStopIndicator = {},
        )
    }
}

// Settings

@Composable
fun SettingsScreen(store: FactoryStore, onAddFactory: () -> Unit) {
    var confirm by remember { mutableStateOf<SavedFactory?>(null) }
    val demo = store.status == FactoryStore.Status.Demo
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 24.dp)) {
        item { SectionHeader("Factory") }
        item {
            Group {
                Field("Name", store.factoryName)
                store.server?.let { Field("Address", SavedFactory.key(it)) }
                store.feed.serverVersion?.let { Field("Server", it) }
                Field("Members", "${store.feed.members.size}")
            }
        }
        store.feed.me?.let { me ->
            item { SectionHeader("Account") }
            item {
                Group {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Avatar(me.login, me.avatarUrl, 40.dp)
                        Column {
                            Text(me.name ?: me.login, style = MaterialTheme.typography.titleMedium)
                            Text("@${me.login} · ${me.role}", style = MaterialTheme.typography.bodySmall, color = secondaryText)
                        }
                    }
                }
            }
        }
        item { SectionHeader("Factories") }
        items(store.factories, key = { it.id }) { factory ->
            val current = factory.id == store.currentKey
            ListRow(if (current) null else ({ store.switchTo(factory) })) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    FactoryTile(store, factory, factory.name, 36.dp)
                    Column(Modifier.weight(1f)) {
                        Text(factory.name, fontWeight = if (current) FontWeight.SemiBold else FontWeight.Normal)
                        Text(if (current) "${factory.host} · open" else factory.host, style = MaterialTheme.typography.bodySmall, color = secondaryText)
                    }
                    if (!demo) TextButton(onClick = { confirm = factory }) { Text("Sign out", color = Maple.danger.color) }
                }
            }
        }
        item {
            ListRow(onAddFactory) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Icon(Icons.Filled.Add, null)
                    Text("Add a factory")
                }
            }
        }
        if (demo) {
            item { Spacer(Modifier.height(12.dp)) }
            item { ListRow({ store.close() }) { Text("Leave the demo", color = MaterialTheme.colorScheme.primary) } }
        }
        item { SectionHeader("About") }
        item { Group { Field("App", BuildConfig.VERSION_NAME) } }
    }
    confirm?.let { factory ->
        AlertDialog(
            onDismissRequest = { confirm = null },
            title = { Text("Sign out of ${factory.name}?") },
            text = { Text("This device forgets ${factory.host} and its sign-in." + if (factory.id == store.currentKey && store.saved.size > 1) " The next factory opens." else "") },
            confirmButton = { TextButton(onClick = { confirm = null; store.signOut(factory) }) { Text("Sign out", color = Maple.danger.color) } },
            dismissButton = { TextButton(onClick = { confirm = null }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun Group(content: @Composable () -> Unit) {
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp).clip(RoundedCornerShape(12.dp)).background(MaterialTheme.colorScheme.surfaceContainerLow).padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) { content() }
}

@Composable
private fun Field(label: String, value: String) {
    Row {
        Text(label, Modifier.weight(1f))
        Text(value, color = secondaryText, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

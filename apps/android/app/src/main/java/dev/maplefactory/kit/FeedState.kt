package dev.maplefactory.kit

import dev.maplefactory.wire.CheckStatus
import dev.maplefactory.wire.Goal
import dev.maplefactory.wire.IntakeRequest
import dev.maplefactory.wire.Machine
import dev.maplefactory.wire.Member
import dev.maplefactory.wire.Presence
import dev.maplefactory.wire.ReviewVerdict
import dev.maplefactory.wire.ServerToClient
import dev.maplefactory.wire.Task
import dev.maplefactory.wire.TaskState

/**
 * A factory as its `/client/connect` feed describes it: the snapshot, then each delta applied in
 * turn. Immutable, so the store can hold one in Compose state and tests can feed it messages directly.
 * MapleKit's FeedState, for Android.
 */
data class FeedState(
    val org: String = "",
    /** The factory's display name, when it has one. */
    val name: String? = null,
    /** The factory's icon, a path on its server (`/icon/<id>`). */
    val icon: String? = null,
    val me: Member? = null,
    val members: List<Member> = emptyList(),
    val machines: List<Machine> = emptyList(),
    val goals: List<Goal> = emptyList(),
    /** Newest first, as the server sends them. */
    val tasks: List<Task> = emptyList(),
    val intake: List<IntakeRequest> = emptyList(),
    /** Goals you follow (true) or unfollowed (false); a goal missing here follows the defaults. */
    val follows: Map<String, Boolean> = emptyMap(),
    val online: List<Presence> = emptyList(),
    val runnerLatest: String? = null,
    val serverVersion: String? = null,
    val hasSnapshot: Boolean = false,
) {
    /** What a message says that isn't state: a toast or an error to show. */
    sealed class Notice {
        data class Toast(val text: String, val taskId: String?) : Notice()
        data class Error(val text: String) : Notice()
    }

    /** The state after one message from the feed, and the toast or error it carries. */
    data class Applied(val state: FeedState, val notice: Notice? = null)

    fun apply(message: ServerToClient): Applied = when (message) {
        is ServerToClient.Snapshot -> Applied(
            copy(
                org = message.org,
                name = message.name,
                icon = message.icon,
                me = message.me,
                members = message.members,
                machines = message.machines,
                goals = message.goals,
                tasks = message.tasks,
                intake = message.intake,
                follows = message.follows.associate { it.goal to it.following },
                online = message.online,
                runnerLatest = message.runnerLatest,
                serverVersion = message.serverVersion,
                hasSnapshot = true,
            ),
        )
        is ServerToClient.TaskUpdated -> Applied(copy(tasks = upsert(message.task, tasks, front = true) { it.id }))
        is ServerToClient.TaskRemoved -> Applied(copy(tasks = tasks.filter { it.id != message.id }))
        is ServerToClient.GoalUpdated -> Applied(copy(goals = upsert(message.goal, goals, front = false) { it.id }))
        is ServerToClient.MachineUpdated -> Applied(copy(machines = upsert(message.machine, machines, front = false) { it.id }))
        is ServerToClient.MachineRemoved -> Applied(copy(machines = machines.filter { it.id != message.id }))
        is ServerToClient.IntakeUpdated -> Applied(copy(intake = upsert(message.request, intake, front = true) { it.id }))
        is ServerToClient.FollowsUpdated -> Applied(copy(follows = message.follows.associate { it.goal to it.following }))
        is ServerToClient.MembersUpdated -> Applied(
            copy(members = message.members, me = me?.let { mine -> message.members.firstOrNull { it.login == mine.login } ?: mine }),
        )
        is ServerToClient.Presence -> Applied(copy(online = message.online))
        is ServerToClient.NameUpdated -> Applied(copy(name = message.name))
        is ServerToClient.IconUpdated -> Applied(copy(icon = message.icon))
        is ServerToClient.RunnerReleased -> Applied(copy(runnerLatest = message.runnerLatest))
        is ServerToClient.Toast -> Applied(this, Notice.Toast(message.text, message.taskId))
        is ServerToClient.Error -> Applied(this, Notice.Error(message.message))
        else -> Applied(this)
    }

    // Reading

    fun task(id: String): Task? = tasks.firstOrNull { it.id == id }
    fun goal(id: String): Goal? = goals.firstOrNull { it.id == id }
    fun member(login: String): Member? = members.firstOrNull { it.login == login }

    /** Goals still in play, in the order the factory keeps them. */
    val activeGoals: List<Goal> get() = goals.filter { it.archived != true }

    fun tasks(goal: String): List<Task> = tasks.filter { it.goal == goal }

    /** Whether you follow the goal: you said so, or you lead it, own a task in it, or are on its team. */
    fun following(goal: Goal): Boolean {
        follows[goal.id]?.let { return it }
        val me = me ?: return true
        if (goal.lead == me.login) return true
        if (goal.team != null && goal.team in me.teams) return true
        return tasks.any { it.goal == goal.id && it.owner == me.login }
    }

    // Inbox

    /**
     * What needs people, grouped like the Mac inbox: plans to approve, raised hands, agents'
     * questions, changes ready for review, failing checks and @mentions of [login].
     */
    fun inbox(login: String): List<InboxEntry> {
        val entries = mutableListOf<InboxEntry>()
        for (task in tasks) {
            if (task.state == TaskState.Merged || task.state == TaskState.Cancelled) continue
            if (task.state == TaskState.AwaitingApproval && login !in task.approvals) {
                entries += InboxEntry(InboxEntry.Kind.Approval, task.id, login, "Plan v${task.planVersion} is ready for your approval", task.updatedAt)
            }
            task.hand?.let { entries += InboxEntry(InboxEntry.Kind.Hand, task.id, it.assignee, it.summary, it.at) }
            task.question?.let { entries += InboxEntry(InboxEntry.Kind.Question, task.id, task.owner, it.text, it.at) }
            if (task.state == TaskState.Reviewing && login !in task.reviews && task.autoReview?.rounds?.lastOrNull()?.verdict == ReviewVerdict.Passed) {
                entries += InboxEntry(InboxEntry.Kind.Review, task.id, task.owner, "Passed automatic review; ready for yours", task.updatedAt)
            }
            if (task.pr?.checks.orEmpty().any { it.status == CheckStatus.Failed }) {
                entries += InboxEntry(InboxEntry.Kind.Failing, task.id, task.owner, "Checks are failing", task.updatedAt)
            }
            for (comment in task.comments) {
                if (comment.author != login && login in comment.mentions.orEmpty()) {
                    entries += InboxEntry(InboxEntry.Kind.Mention, task.id, login, "${comment.author}: ${comment.text}", comment.at, comment.id)
                }
            }
        }
        return entries.sortedByDescending { it.at }
    }

    /** Whether the machine's runner is older than the latest release. */
    fun runnerOutdated(machine: Machine): Boolean {
        val version = machine.version ?: return false
        val latest = runnerLatest ?: return false
        return isOlder(version, latest)
    }

    companion object {
        private fun <T> upsert(item: T, list: List<T>, front: Boolean, id: (T) -> String): List<T> {
            val index = list.indexOfFirst { id(it) == id(item) }
            return when {
                index >= 0 -> list.toMutableList().also { it[index] = item }
                front -> listOf(item) + list
                else -> list + item
            }
        }

        /** Whether [a] is an older version than [b] ("0.2.0" < "0.10.1"); anything after a "-" is ignored. */
        fun isOlder(a: String, b: String): Boolean {
            fun parts(v: String) = v.substringBefore('-').split('.').map { it.toIntOrNull() ?: 0 }
            val x = parts(a)
            val y = parts(b)
            for (i in 0 until maxOf(x.size, y.size)) {
                val p = x.getOrElse(i) { 0 }
                val q = y.getOrElse(i) { 0 }
                if (p != q) return p < q
            }
            return false
        }
    }
}

/** One thing in the inbox: a task waiting on someone, and why. */
data class InboxEntry(
    val kind: Kind,
    val task: String,
    /** Whose it is to act on. */
    val assignee: String,
    val message: String,
    val at: Long,
    /** For a mention, the comment it's about, so each one in a task is its own row. */
    val comment: String? = null,
) {
    enum class Kind(val title: String) {
        Approval("Plans awaiting approval"),
        Hand("Raised hands"),
        Question("Questions from agents"),
        Review("Ready for review"),
        Failing("Failing checks"),
        Mention("Mentions"),
    }

    val id: String get() = "${kind.name.lowercase()}-${comment ?: task}"
}

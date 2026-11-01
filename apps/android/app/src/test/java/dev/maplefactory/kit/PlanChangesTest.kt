package dev.maplefactory.kit

import dev.maplefactory.wire.PlanStep
import dev.maplefactory.wire.Task
import dev.maplefactory.wire.TaskState
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PlanChangesTest {
    private fun task(version: Long, state: TaskState, changed: Boolean = true) = Task(
        id = "MF-1", goal = "g", title = "Plan", state = state, owner = "me", brief = "",
        createdAt = 0, updatedAt = 0, planVersion = version, approvalsNeeded = 1, reviewsNeeded = 1,
        shareable = false, agent = "claude",
        plan = listOf(
            PlanStep(text = "Keep", file = "a.kt", added = false),
            PlanStep(text = "Revised", file = "b.kt", added = false, from = if (changed) "Old" else null),
            PlanStep(text = "Extra", file = "c.kt", added = changed),
        ),
    )

    @Test fun firstVersionIsNeverFresh() = assertFalse(task(1, TaskState.AwaitingApproval).planChangesFresh)

    @Test fun revisionAwaitingApprovalIsFresh() {
        assertTrue(task(2, TaskState.AwaitingApproval).planChangesFresh)
        assertTrue(task(3, TaskState.AwaitingApproval).planChangesFresh)
    }

    @Test fun approvedRevisionIsNotFresh() {
        for (state in listOf(TaskState.Building, TaskState.Reviewing, TaskState.Merged, TaskState.Backlog)) {
            assertFalse(state.raw, task(3, state).planChangesFresh)
        }
    }

    @Test fun revisionWithNoChangedStepsIsNotFresh() =
        assertFalse(task(3, TaskState.AwaitingApproval, changed = false).planChangesFresh)
}

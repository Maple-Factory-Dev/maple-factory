package dev.maplefactory.kit

import dev.maplefactory.wire.PlanStep
import dev.maplefactory.wire.Task
import dev.maplefactory.wire.TaskState

/** The step differs from the plan version before it: new, or reworded. */
val PlanStep.changed: Boolean get() = added || from != null

/**
 * Whether the plan's step changes are news: only while a revised plan (v2+) waits on approval.
 * Once it's approved they're history, so the plain current steps show by default.
 */
val Task.planChangesFresh: Boolean
    get() = planVersion > 1 && state == TaskState.AwaitingApproval && plan.any { it.changed }

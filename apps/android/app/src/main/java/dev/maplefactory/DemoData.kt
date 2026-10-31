package dev.maplefactory

import dev.maplefactory.kit.DiffFile
import dev.maplefactory.kit.FeedState
import dev.maplefactory.kit.SavedFactory
import dev.maplefactory.wire.Activity
import dev.maplefactory.wire.AgentInstall
import dev.maplefactory.wire.AgentState
import dev.maplefactory.wire.AutoReview
import dev.maplefactory.wire.CICheck
import dev.maplefactory.wire.CheckStatus
import dev.maplefactory.wire.CheckVerdict
import dev.maplefactory.wire.Comment
import dev.maplefactory.wire.Diff
import dev.maplefactory.wire.DoneItem
import dev.maplefactory.wire.Evidence
import dev.maplefactory.wire.Finding
import dev.maplefactory.wire.FindingKind
import dev.maplefactory.wire.FindingStatus
import dev.maplefactory.wire.Footprint
import dev.maplefactory.wire.Goal
import dev.maplefactory.wire.Hand
import dev.maplefactory.wire.HandOption
import dev.maplefactory.wire.HandReason
import dev.maplefactory.wire.Health
import dev.maplefactory.wire.LiveSession
import dev.maplefactory.wire.Machine
import dev.maplefactory.wire.Member
import dev.maplefactory.wire.Mockup
import dev.maplefactory.wire.MockupStatus
import dev.maplefactory.wire.PRState
import dev.maplefactory.wire.PlanStep
import dev.maplefactory.wire.ProofKind
import dev.maplefactory.wire.ProofStatus
import dev.maplefactory.wire.PullRequest
import dev.maplefactory.wire.Question
import dev.maplefactory.wire.ReviewCheck
import dev.maplefactory.wire.ReviewRound
import dev.maplefactory.wire.ReviewVerdict
import dev.maplefactory.wire.Risk
import dev.maplefactory.wire.RiskLevel
import dev.maplefactory.wire.Role
import dev.maplefactory.wire.SessionInfo
import dev.maplefactory.wire.Severity
import dev.maplefactory.wire.StepProgress
import dev.maplefactory.wire.Task
import dev.maplefactory.wire.TaskEvent
import dev.maplefactory.wire.TaskState
import dev.maplefactory.wire.Worker

/**
 * Sample goals, tasks and machines for the demo (`-demo YES`, or Try the demo when signed out), so
 * every screen renders with no server: the iPhone app's DemoData, plus a second factory so the
 * switcher has somewhere to go.
 */
object DemoData {
    private val now: Long get() = System.currentTimeMillis()
    private fun ago(minutes: Double): Long = now - (minutes * 60_000).toLong()

    const val ME = "andrea"

    val factories = listOf(
        SavedFactory("https://maple.acme.dev", "acme", "Acme", 2),
        SavedFactory("https://factory.northwind.io", "northwind", "Northwind", 1),
    )

    fun feed(index: Int): FeedState = if (index == 0) acme() else northwind()

    private val andrea = Member(login = ME, name = "Andrea", role = "admin", teams = listOf("mobile"))

    private fun acme() = FeedState(
        org = "acme",
        name = "Acme",
        me = andrea,
        members = listOf(
            andrea,
            Member(login = "sam", name = "Sam Rivera", role = "member", teams = listOf("mobile")),
            Member(login = "kit", name = "Kit Okafor", role = "member", teams = listOf("platform")),
        ),
        goals = listOf(
            Goal(id = "g-app", name = "Mobile app", prefix = "APP", color = "#D24E26", summary = "Ship the phone apps: inbox, review and approvals on the go.", lead = ME, repo = "acme/app", repos = listOf("acme/app"), team = "mobile"),
            Goal(id = "g-api", name = "Public API", prefix = "API", color = "#2F6FEB", summary = "A versioned REST API with tokens and rate limits.", lead = "kit", repo = "acme/api", repos = listOf("acme/api")),
            Goal(id = "g-web", name = "Billing", prefix = "BIL", color = "#14A866", summary = "Usage-based plans and invoices.", lead = "sam", repo = "acme/web", repos = listOf("acme/web")),
        ),
        tasks = acmeTasks(),
        machines = acmeMachines(),
        runnerLatest = "0.65.0",
        serverVersion = "0.51.0",
        hasSnapshot = true,
    )

    private fun northwind() = FeedState(
        org = "northwind",
        name = "Northwind",
        me = andrea.copy(teams = emptyList()),
        members = listOf(andrea.copy(teams = emptyList()), Member(login = "jo", name = "Jo Park", role = "admin")),
        goals = listOf(
            Goal(id = "g-shop", name = "Storefront", prefix = "SHOP", color = "#7C5CE0", summary = "The new checkout.", lead = "jo", repo = "northwind/shop"),
        ),
        tasks = listOf(
            task("SHOP-3", "g-shop", "Apple Pay and Google Pay at checkout", TaskState.AwaitingApproval, owner = "jo", updated = 12.0) {
                it.copy(
                    brief = "Offer wallet payments on the checkout page.",
                    planSummary = "Add the Payment Request API with Stripe's wallet element.",
                    plan = listOf(
                        PlanStep(text = "Mount Stripe's Express Checkout element above the card form", file = "web/checkout/Wallets.tsx", added = false),
                        PlanStep(text = "Confirm the payment intent server-side", file = "api/payments.ts", added = false),
                    ),
                )
            },
            task("SHOP-2", "g-shop", "Cart survives a sign-in", TaskState.Building, owner = "jo", updated = 40.0),
            task("SHOP-1", "g-shop", "Product search with typo tolerance", TaskState.Merged, owner = "jo", updated = 60.0 * 30),
        ),
        machines = listOf(Machine(id = "m-nw", name = "Northwind CI Mac", owner = "jo", online = true, version = "0.65.0", os = "macOS 27.0")),
        runnerLatest = "0.65.0",
        serverVersion = "0.51.0",
        hasSnapshot = true,
    )

    private fun task(
        id: String, goal: String, title: String, state: TaskState, owner: String = ME, updated: Double,
        configure: (Task) -> Task = { it },
    ): Task = configure(
        Task(
            id = id, goal = goal, title = title, state = state, owner = owner, brief = "", createdAt = ago(updated + 600), updatedAt = ago(updated),
            planVersion = 1, approvalsNeeded = 1, reviewsNeeded = 1, shareable = false, agent = "claude", model = "opus",
        ),
    )

    private fun acmeTasks(): List<Task> = listOf(
        task("APP-14", "g-app", "Push notifications when a plan needs your approval", TaskState.AwaitingApproval, owner = "sam", updated = 4.0) {
            it.copy(
                brief = "When a plan is ready, the people who need to approve it should get a push notification on their phone, with Approve right there in the notification.",
                planVersion = 2,
                planSummary = "Register for push on sign-in, store each member's device tokens on the server, and send a notification with an Approve action when a task enters awaitingApproval.",
                plan = listOf(
                    PlanStep(text = "Register for remote notifications on sign-in and send the device token to POST /api/devices", file = "apps/ios/Sources/Notifications.swift", added = false),
                    PlanStep(text = "Store device tokens per member in D1, removed on sign-out", file = "server/src/devices.ts", added = false),
                    PlanStep(text = "Send a push with an APPROVE category when a task's plan awaits a member's approval", file = "server/src/push.ts", added = true),
                    PlanStep(text = "Handle the Approve action by sending task.approvePlan, without opening the app", file = "apps/ios/Sources/Notifications.swift", added = false, from = "Open the task when the notification is tapped"),
                ),
                doneWhen = listOf(
                    DoneItem(text = "A plan awaiting approval sends a push to each approver's phone", proof = ProofKind.Screenshot, status = ProofStatus.Pending),
                    DoneItem(text = "Approve from the notification moves the task to building", proof = ProofKind.Video, status = ProofStatus.Pending),
                    DoneItem(text = "Server tests cover token storage and removal", proof = ProofKind.Tests, status = ProofStatus.Pending),
                ),
                risk = Risk(level = RiskLevel.Medium, reasons = listOf("Touches sign-in", "New server table"), areas = listOf("auth")),
                footprint = Footprint(files = 6, lines = 240, estimated = true),
                mockups = listOf(
                    Mockup(id = "m1", title = "The notification", kind = "screen", html = MOCKUP_HTML, status = MockupStatus.Proposed, version = 1),
                ),
                autoReview = AutoReview(
                    maxRounds = 3, rounds = listOf(ReviewRound(number = 1, verdict = ReviewVerdict.ChangesRequested, found = 1, at = ago(20.0))),
                    summary = "The plan covers the ask; one gap in how tokens are cleaned up.",
                    ask = listOf(ReviewCheck(text = "Approve from the notification", verdict = CheckVerdict.Met)),
                    proofs = listOf(ReviewCheck(text = "A video of approving from the lock screen", verdict = CheckVerdict.Partial)),
                    findings = listOf(
                        Finding(id = "p1", kind = FindingKind.Scope, severity = Severity.Major, text = "Tokens for a signed-out device stay on the server until the next push fails; remove them on sign-out.", file = "server/src/devices.ts", raisedIn = 1, status = FindingStatus.Open),
                    ),
                ),
                events = listOf(
                    TaskEvent(who = "sam", text = "created the task", at = ago(70.0)),
                    TaskEvent(who = "planner", text = "wrote plan v1", at = ago(50.0)),
                    TaskEvent(who = ME, text = "asked the planner to handle the Approve action in the background", at = ago(30.0)),
                    TaskEvent(who = "planner", text = "wrote plan v2", at = ago(4.0)),
                ),
                comments = listOf(Comment(id = "c1", author = "sam", text = "@andrea can you take a look before standup?", at = ago(3.0), mentions = listOf(ME))),
            )
        },
        task("APP-12", "g-app", "Offline cache for the inbox", TaskState.Building, updated = 9.0) {
            it.copy(
                brief = "Keep the last snapshot on disk so the inbox opens instantly, even on a plane.",
                plan = listOf(
                    PlanStep(text = "Persist the last snapshot as JSON in the app's files", file = "apps/android/app/src/main/java/dev/maplefactory/FeedCache.kt", progress = StepProgress.Done, added = false),
                    PlanStep(text = "Show the cached inbox while the socket connects", file = "apps/android/app/src/main/java/dev/maplefactory/ui/RootScreen.kt", progress = StepProgress.Active, added = false),
                    PlanStep(text = "Clear the cache on sign-out", file = "apps/android/app/src/main/java/dev/maplefactory/FactoryStore.kt", progress = StepProgress.Pending, added = false),
                ),
                worker = Worker(role = Role.Builder, agent = "claude", machine = "m-studio", session = "s1", startedAt = ago(25.0)),
                question = Question(text = "Should the cache be per factory, or only the last one you used?", options = listOf("Per factory", "Only the last one"), role = Role.Builder, at = ago(9.0)),
                approvals = listOf(ME),
            )
        },
        task("API-31", "g-api", "Rate limit API tokens per org", TaskState.Reviewing, owner = "kit", updated = 18.0) {
            it.copy(
                brief = "Each org gets 600 requests a minute across its tokens; over that, 429 with Retry-After.",
                plan = listOf(
                    PlanStep(text = "A sliding-window counter per org in a Durable Object", file = "server/src/ratelimit.ts", progress = StepProgress.Done, added = false),
                    PlanStep(text = "Answer 429 with Retry-After over the limit", file = "server/src/api.ts", progress = StepProgress.Done, added = false),
                ),
                diff = Diff(added = 86, removed = 12, files = listOf("server/src/ratelimit.ts", "server/src/api.ts")),
                pr = PullRequest(
                    number = 412, url = "https://github.com/acme/api/pull/412", state = PRState.Open, branch = "agent/api-31", base = "main",
                    checks = listOf(
                        CICheck(name = "test", status = CheckStatus.Passed, duration = "1m 12s", required = true),
                        CICheck(name = "lint", status = CheckStatus.Passed, duration = "18s", required = true),
                    ),
                ),
                autoReview = AutoReview(
                    maxRounds = 3,
                    rounds = listOf(
                        ReviewRound(number = 1, verdict = ReviewVerdict.ChangesRequested, found = 2, at = ago(40.0)),
                        ReviewRound(number = 2, verdict = ReviewVerdict.Passed, found = 0, at = ago(20.0)),
                    ),
                    summary = "The limiter is correct under concurrency; both findings from round 1 are fixed.",
                    ask = listOf(ReviewCheck(text = "600 requests a minute per org", verdict = CheckVerdict.Met)),
                    proofs = listOf(ReviewCheck(text = "Tests pass", verdict = CheckVerdict.Met)),
                    findings = listOf(
                        Finding(id = "f1", kind = FindingKind.Code, severity = Severity.Major, text = "The window resets on every deploy because the counter lives in memory.", file = "server/src/ratelimit.ts", raisedIn = 1, status = FindingStatus.Fixed, fixedIn = 2),
                        Finding(id = "f2", kind = FindingKind.Code, severity = Severity.Minor, text = "Retry-After was in milliseconds; it should be seconds.", file = "server/src/api.ts", raisedIn = 1, status = FindingStatus.Fixed, fixedIn = 2),
                    ),
                ),
                doneWhen = listOf(
                    DoneItem(
                        text = "Server tests cover the limit and Retry-After", proof = ProofKind.Tests, status = ProofStatus.Proven,
                        evidence = Evidence(
                            kind = ProofKind.Tests, summary = "14 tests pass", command = "npm test -- ratelimit",
                            output = listOf("✓ allows 600 a minute", "✓ answers 429 with Retry-After: 12", "Tests: 14 passed"),
                            passed = 14, failed = 0, by = "builder", at = ago(22.0),
                        ),
                    ),
                ),
                mergeAt = now + 8 * 60_000,
            )
        },
        task("BIL-7", "g-web", "Invoice PDFs with line items", TaskState.Building, owner = "sam", updated = 35.0) {
            it.copy(
                brief = "Render each invoice as a PDF with its usage line items.",
                hand = Hand(
                    reason = HandReason.NeedsInput, summary = "Stripe's invoice API doesn't return usage line items for metered prices. Build them from our own usage table instead?",
                    at = ago(35.0), assignee = ME,
                    options = listOf(
                        HandOption(title = "Use our usage table", detail = "Matches what customers see in the app.", recommended = true),
                        HandOption(title = "Wait for Stripe's line items", detail = "Simpler, but needs their beta.", recommended = false),
                    ),
                ),
                worker = Worker(role = Role.Builder, agent = "codex", machine = "m-mini", session = "s3", startedAt = ago(50.0)),
            )
        },
        task("API-29", "g-api", "Token scopes: read, write and admin", TaskState.Reviewing, owner = "kit", updated = 60.0) {
            it.copy(
                brief = "Tokens carry scopes; write endpoints refuse read tokens.",
                pr = PullRequest(
                    number = 405, state = PRState.Open, branch = "agent/api-29", base = "main",
                    checks = listOf(
                        CICheck(name = "test", status = CheckStatus.Failed, duration = "58s", required = true),
                        CICheck(name = "lint", status = CheckStatus.Passed, duration = "14s", required = true),
                    ),
                ),
                autoReview = AutoReview(maxRounds = 3, rounds = listOf(ReviewRound(number = 1, verdict = ReviewVerdict.Passed, found = 0, at = ago(70.0))), summary = "Looks right."),
                diff = Diff(added = 140, removed = 31, files = listOf("server/src/tokens.ts")),
            )
        },
        task("APP-9", "g-app", "Sign in with GitHub's device flow", TaskState.Merged, updated = 60.0 * 26) { it.copy(brief = "Sign in on the phone with a code, like the Mac app.") },
        task("BIL-5", "g-web", "Plans page", TaskState.Planning, owner = "sam", updated = 3.0),
        task("APP-15", "g-app", "Tablet layout with a sidebar", TaskState.Drafting, updated = 120.0),
        task("API-33", "g-api", "Webhooks for task events", TaskState.Backlog, owner = "kit", updated = 300.0),
    )

    private fun acmeMachines(): List<Machine> {
        val gig = 1_073_741_824L
        val agents = listOf(AgentInstall(name = "claude", version = "2.4.1", loggedIn = true), AgentInstall(name = "codex", version = "0.61.0", loggedIn = true))
        return listOf(
            Machine(
                id = "m-studio", name = "Andrea's Mac Studio", owner = ME, online = true, version = "0.65.0", os = "macOS 27.0",
                health = Health(cpu = 0.42, cores = 24, load1 = 6.2, memUsed = 41 * gig, memTotal = 96 * gig, diskUsed = 610 * gig, diskTotal = 2000 * gig, uptime = 86400 * 3, agents = agents),
                sessions = listOf(
                    LiveSession(
                        session = SessionInfo(id = "s1", agent = "claude", cwd = "~/maple/worktrees/app-12", startedAt = ago(25.0), taskId = "APP-12"),
                        activity = Activity(state = AgentState.Waiting, message = "Asked a question", at = ago(9.0)),
                    ),
                ),
                capacity = 4,
            ),
            Machine(
                id = "m-mini", name = "Build Mini", owner = "sam", online = true, version = "0.63.2", os = "macOS 26.4",
                health = Health(cpu = 0.18, cores = 10, load1 = 1.4, memUsed = 9 * gig, memTotal = 32 * gig, diskUsed = 120 * gig, diskTotal = 512 * gig, uptime = 86400 * 12, agents = agents),
                sessions = listOf(
                    LiveSession(
                        session = SessionInfo(id = "s3", agent = "codex", cwd = "~/maple/worktrees/bil-7", startedAt = ago(50.0), taskId = "BIL-7"),
                        activity = Activity(state = AgentState.Waiting, message = "Raised a hand", at = ago(35.0)),
                    ),
                ),
                capacity = 2,
            ),
            Machine(id = "m-air", name = "Kit's MacBook Air", owner = "kit", online = false, lastSeen = ago(60.0 * 5), version = "0.65.0", os = "macOS 27.0"),
        )
    }

    fun diff(): List<DiffFile> = DiffFile.parse(
        """
        diff --git a/server/src/ratelimit.ts b/server/src/ratelimit.ts
        new file mode 100644
        --- /dev/null
        +++ b/server/src/ratelimit.ts
        @@ -0,0 +1,9 @@
        +// A sliding window per org, kept in a Durable Object so deploys don't reset it.
        +export class RateLimiter {
        +  constructor(private state: DurableObjectState) {}
        +
        +  async take(limit = 600): Promise<number | null> {
        +    const used = (await this.state.storage.get<number>("used")) ?? 0;
        +    if (used >= limit) return 12;
        +    await this.state.storage.put("used", used + 1);
        +    return null;
        diff --git a/server/src/api.ts b/server/src/api.ts
        --- a/server/src/api.ts
        +++ b/server/src/api.ts
        @@ -40,6 +40,9 @@ export async function api(request: Request, env: Env) {
           const token = await authenticate(request, env);
           if (!token) return new Response("Unauthorized", { status: 401 });
        -  return route(request, env, token);
        +  const wait = await limiter(env, token.org).take();
        +  if (wait !== null) return new Response("Too many requests", { status: 429, headers: { "Retry-After": String(wait) } });
        +  return route(request, env, token);
         }
        """.trimIndent(),
    )

    private const val MOCKUP_HTML = """<html><head><meta name="viewport" content="width=device-width,initial-scale=1"><style>
body{margin:0;font:15px system-ui,sans-serif;background:linear-gradient(160deg,#3b2a5a,#d24e26);height:100vh;display:flex;align-items:flex-start;justify-content:center;padding-top:40px}
.n{background:rgba(255,255,255,.88);border-radius:22px;padding:14px 16px;width:86%;box-shadow:0 8px 30px rgba(0,0,0,.2)}
.h{display:flex;gap:8px;align-items:center;font-size:12px;color:#555}.i{width:20px;height:20px;border-radius:5px;background:#d24e26}
b{display:block;margin:6px 0 2px}.a{display:flex;gap:8px;margin-top:12px}.a div{flex:1;text-align:center;padding:9px;border-radius:12px;background:#fff;font-weight:600}
.a .p{background:#1f883d;color:#fff}
</style></head><body><div class="n"><div class="h"><div class="i"></div>MAPLE FACTORY · now</div>
<b>APP-14 plan is ready</b>Push notifications when a plan needs your approval<div class="a"><div class="p">Approve</div><div>Open</div></div></div></body></html>"""
}

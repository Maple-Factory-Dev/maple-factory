import SwiftUI

/// The connected factory's goals, people and presence. `FactoryData` reads them through here so the
/// views that show them redraw when the feed changes them; nil means not signed in (the mockup's).
@MainActor @Observable final class LiveData {
    static let shared = LiveData()

    var goals: [Goal]?
    var people: [Person]?
    var presence: [(person: Person, viewing: String?)]?
}

enum FactoryData {
    // MARK: People

    /// You: the signed-in member once the app is connected to a factory (`FactoryClient`).
    nonisolated(unsafe) static var me = Person(name: "Andrea Fomera", color: Color(light: 0xD9488F, dark: 0xF07AB4), isHuman: true, github: "afomera")
    static let chris = Person(name: "Chris", color: Color(light: 0xE0662F, dark: 0xFF8A5B), isHuman: true, github: "excid3")

    /// The org's people: its members when connected, for mentions, facepiles and avatars.
    @MainActor static var people: [Person] { livePeople ?? [me, chris] }
    @MainActor static var livePeople: [Person]? {
        get { LiveData.shared.people }
        set { LiveData.shared.people = newValue }
    }

    /// Who's online and which task they have open (nil = elsewhere in the workspace).
    @MainActor static var presence: [(person: Person, viewing: String?)] { livePresence ?? seedPresence }
    /// Who's online in the connected factory (`FactoryClient`).
    @MainActor static var livePresence: [(person: Person, viewing: String?)]? {
        get { LiveData.shared.presence }
        set { LiveData.shared.presence = newValue }
    }

    static let seedPresence: [(person: Person, viewing: String?)] = [
        (me, nil),
        (chris, "ATL-147"),
    ]

    static let agents: [Agent] = [
        Agent(name: "Maple-1", color: Theme.State.awaitingApproval),
        Agent(name: "Maple-2", color: Theme.State.building),
        Agent(name: "Maple-3", color: Theme.State.planning),
        Agent(name: "Maple-4", color: Theme.State.planning),
        Agent(name: "Maple-5", color: Theme.State.building),
    ]

    /// What each agent is doing right now, for the sidebar roster.
    static let agentStatus: [(agent: Agent, state: TaskState, task: String)] = [
        (agents[0], .awaitingApproval, "ATL-147"),
        (agents[1], .building, "ATL-144"),
        (agents[2], .planning, "ATL-158"),
        (agents[3], .planning, "ATL-160"),
        (agents[4], .building, "ATL-149"),
    ]

    static let repo = "afomera/atlas-platform"

    /// Goals that have signed off on letting the factory auto-merge riskier work.
    static let seedAcceptances: [String: RiskAcceptance] = [
        "Docs site": RiskAcceptance(autoMergeUpTo: .medium, acceptedBy: chris, when: "Oct 20",
                                    note: "Docs deploys are isolated from the app; worst case is a bad page."),
    ]

    // MARK: Calendar

    /// The mockup's calendar is pinned to its story; a live workspace's starts 11 days before today.
    @MainActor static var timelineStart: Date {
        liveGoals == nil
            ? Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 13))!
            : Calendar.current.date(byAdding: .day, value: -todayOffset, to: Calendar.current.startOfDay(for: Date()))!
    }
    static let timelineDays = 49
    static let todayOffset = 11

    @MainActor static func date(_ offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: timelineStart)!
    }

    @MainActor static func dueLabel(_ goal: Goal) -> String? {
        goal.dueOffset.map { date($0).formatted(.dateTime.month(.abbreviated).day()) }
    }

    static func isOverdue(_ goal: Goal) -> Bool {
        goal.dueOffset.map { $0 < todayOffset } ?? false
    }

    // MARK: Goals

    /// The connected factory's goals, when signed in (`FactoryClient`); the mockup's otherwise.
    @MainActor static var liveGoals: [Goal]? {
        get { LiveData.shared.goals }
        set { LiveData.shared.goals = newValue }
    }
    @MainActor static var goals: [Goal] { liveGoals ?? seedGoals }
    /// The goals still in play: the sidebar's and the composer's.
    @MainActor static var activeGoals: [Goal] { goals.filter { !$0.archived } }

    static let seedGoals: [Goal] = [
        Goal(name: "Auth overhaul", color: Theme.State.merged, dueOffset: 32, lead: me,
             summary: "Move every surface to rotating sessions, passkeys and enterprise SSO ahead of the Q1 security review."),
        Goal(name: "Billing v2", color: Theme.State.building, dueOffset: 25, lead: chris,
             summary: "Usage-based pricing with clean proration, idempotent webhooks and invoices customers can actually read."),
        Goal(name: "Onboarding revamp", color: Theme.State.planning, dueOffset: 39, lead: me,
             summary: "Get a new workspace from sign-up to first merged task in under ten minutes."),
        Goal(name: "Performance budget", color: Theme.State.awaitingApproval, dueOffset: 18, lead: me,
             summary: "Hold cold start under 300ms and the main bundle under 250kb, enforced in CI."),
        Goal(name: "Docs site", color: Theme.State.reviewing, dueOffset: 46, lead: chris,
             summary: "A searchable docs site with generated API reference and live examples."),
    ]

    @MainActor static func goal(named name: String) -> Goal {
        goals.first { $0.name == name } ?? Goal(name: name, color: Theme.textMuted, dueOffset: nil, lead: me, summary: "")
    }

    // MARK: Tasks

    static let seedTasks: [FactoryTask] = [
        // Auth overhaul
        FactoryTask(id: "ATL-161", title: "Passkey enrollment flow in account settings", state: .drafting,
                    detail: "Edited 2h ago", span: 11...26, updated: "2h"),
        FactoryTask(id: "ATL-163", title: "Audit session cookie flags", state: .drafting,
                    owner: chris, detail: "Edited yesterday", span: 10...14, updated: "1d"),

        FactoryTask(
            id: "ATL-158", title: "Migrate session store to Redis", state: .planning,
            agent: agents[2], owner: chris, detail: "Drafting plan · step 4", span: 11...22, updated: "now",
            brief: "Move sessions out of Postgres into Redis so token lookups stop hitting the primary database on every request.",
            plan: [
                PlanStep(text: "Add a Redis client with connection pooling", file: "lib/redis.ts", progress: .done),
                PlanStep(text: "Implement a SessionStore interface over Redis", file: "lib/session/redis-store.ts", progress: .done),
                PlanStep(text: "Dual-write sessions to Postgres and Redis", file: "lib/session/index.ts", progress: .done),
                PlanStep(text: "Drafting next step…", file: "", progress: .active),
            ],
            changeRequests: [
                ChangeRequest(author: me, text: "Keep the in-memory store for local dev so nobody needs Redis running to work on the app.",
                              status: .queued, when: "2m", timing: "Maple-3 will fold this into the plan"),
            ],
            doneWhen: [
                DoneCriterion(text: "p95 session lookup under 5ms in staging", proof: .terminal),
                DoneCriterion(text: "No session reads hit Postgres after cutover", proof: .screenshot),
            ],
            liveLog: "Reading lib/session/postgres-store.ts",
            footprint: (5, 300, true), areas: ["Auth"]
        ),
        FactoryTask(
            id: "ATL-160", title: "SSO for enterprise orgs (SAML + OIDC)", state: .planning,
            agent: agents[3], detail: "Blocked on a question", needsYou: true, span: 10...28, updated: "12m",
            brief: "Let enterprise customers sign in through their own identity provider, with SAML 2.0 and OIDC both supported from day one.",
            question: "Should users who sign in through SAML be auto-provisioned into the org's default team, or should they need an invite first?",
            questionOptions: ["Auto-provision", "Require invite"],
            activity: [
                ActivityItem(who: "Maple-4", text: "Asked a question", when: "12m"),
                ActivityItem(who: "Maple-4", text: "Drafted 3 of 5 plan steps", when: "18m"),
            ]
        ),

        FactoryTask(
            id: "ATL-147", title: "Refresh-token rotation with reuse detection", state: .awaitingApproval,
            agent: agents[0], detail: "Plan v2 ready · 7 steps", needsYou: true, span: 9...19, updated: "2m",
            brief: "Rotate the refresh token on every use and revoke the whole token family if an old token is replayed. Clients should retry once on 401 with the new token.",
            plan: [
                PlanStep(text: "Add refresh_tokens table with family id and rotated_at", file: "db/migrations/0042_refresh_tokens.sql"),
                PlanStep(text: "Issue a rotating refresh token on login", file: "lib/auth/session.ts"),
                PlanStep(text: "Detect reuse and revoke the token family", file: "lib/auth/refresh.ts"),
                PlanStep(text: "Update the refresh route handler", file: "app/api/auth/refresh/route.ts"),
                PlanStep(text: "Keep /api/auth/token as a deprecated alias until mobile 2.14 ships", file: "app/api/auth/token/route.ts", change: .added),
                PlanStep(text: "Client retries once on 401 with the new token", file: "lib/api.ts"),
                PlanStep(text: "Tests for rotation, reuse, expiry and the legacy alias", file: "tests/auth.test.ts",
                         change: .modified(from: "Tests for rotation, reuse and expiry")),
            ],
            activity: [
                ActivityItem(who: "Chris", text: "Approved plan v2", when: "1m"),
                ActivityItem(who: "Maple-1", text: "Revised the plan to v2 (+1 step, 1 changed)", when: "2m"),
                ActivityItem(who: "Chris", text: "Requested a change on step 4", when: "3m"),
                ActivityItem(who: "Maple-1", text: "Plan v1 ready for review", when: "4m"),
                ActivityItem(who: "Andrea Fomera", text: "Moved from Drafting to Planning", when: "21m"),
            ],
            viewers: [chris],
            approvals: [chris],
            approvalsNeeded: 2,
            comments: [
                Comment(author: chris, text: "@afomera can we keep the old refresh endpoint around for one release? The mobile app still calls it.", when: "3m", anchor: "Step 4"),
                Comment(author: agents[0], text: "Good call. I'll add a step to keep /api/auth/token as a deprecated alias until mobile 2.14 ships.", when: "2m", anchor: "Step 4"),
            ],
            planVersion: 2,
            changeRequests: [
                ChangeRequest(author: chris, text: "Keep the old refresh endpoint around for one release. Mobile still calls it.",
                              anchor: "Step 4", status: .applied, when: "3m", timing: "Applied in v2"),
            ],
            doneWhen: [
                DoneCriterion(text: "Replaying a rotated refresh token revokes the whole family", proof: .tests),
                DoneCriterion(text: "/api/auth/token still returns 200 with a Deprecation header", proof: .terminal),
                DoneCriterion(text: "A signed-in user stays signed in through a forced 401 refresh", proof: .video),
                DoneCriterion(text: "No new type errors or lint warnings", proof: .terminal),
            ],
            footprint: (7, 380, true), areas: ["Auth", "Migrations"]
        ),
        FactoryTask(id: "ATL-152", title: "Rate-limit login attempts per IP and account", state: .awaitingApproval,
                    agent: agents[0], owner: chris, detail: "Plan ready · 4 steps", needsYou: true, span: 10...18, updated: "26m", footprint: (4, 180, true), areas: ["Auth"]),

        FactoryTask(
            id: "ATL-144", title: "Extract auth middleware from route handlers", state: .building,
            agent: agents[1], detail: "Step 4 of 7", progress: 0.57, span: 8...15, updated: "now",
            brief: "Pull the duplicated session and role checks out of 34 route handlers into a single middleware.",
            plan: [
                PlanStep(text: "Inventory auth checks across route handlers", file: "app/api/**/route.ts", progress: .done),
                PlanStep(text: "Create withAuth middleware with role options", file: "lib/auth/middleware.ts", progress: .done),
                PlanStep(text: "Migrate /api/projects routes", file: "app/api/projects", progress: .done),
                PlanStep(text: "Migrate /api/billing routes", file: "app/api/billing", progress: .active),
                PlanStep(text: "Migrate the remaining routes", file: "app/api", progress: .pending),
                PlanStep(text: "Delete the inline requireSession checks", file: "lib/auth/legacy.ts", progress: .pending),
                PlanStep(text: "Tests for each role and the unauthenticated path", file: "tests/middleware.test.ts", progress: .pending),
            ],
            activity: [
                ActivityItem(who: "Chris", text: "Queued a change for after step 4", when: "6m"),
                ActivityItem(who: "Maple-2", text: "Finished step 3 · 12 routes migrated", when: "9m"),
                ActivityItem(who: "Andrea Fomera", text: "Approved the plan", when: "52m"),
            ],
            changeRequests: [
                ChangeRequest(author: chris, text: "Reuse the existing withSession helper instead of adding a second wrapper.",
                              status: .queued, when: "6m", timing: "Applies after step 4"),
            ],
            doneWhen: [
                DoneCriterion(text: "Middleware type-checks cleanly", proof: .terminal, status: .proven,
                              evidence: .terminal(command: "npx tsc --noEmit", output: ["✓ No errors in 1,284 files (6.2s)"])),
                DoneCriterion(text: "No route handler calls requireSession directly", proof: .terminal, status: .proving,
                              evidence: .terminal(command: "rg -c \"requireSession\\(\" app/api", output: ["app/api/billing/invoices/route.ts:2", "app/api/billing/plans/route.ts:1", "", "3 matches left · all in step 4 scope"])),
                DoneCriterion(text: "Existing auth tests still pass", proof: .tests, status: .proving,
                              evidence: .tests(suite: "tests/auth", passed: 31, failed: 0)),
                DoneCriterion(text: "Unauthenticated request to /api/billing returns 401", proof: .terminal),
            ],
            liveLog: "Editing app/api/billing/invoices/route.ts",
            footprint: (34, 1240, false), areas: ["Auth", "Billing"],
            pr: PullRequest(number: 487, state: .draft, checks: CICheck.standard(running: ["unit tests", "e2e"]))
        ),
        FactoryTask(id: "ATL-149", title: "Email magic-link fallback", state: .building,
                    agent: agents[4], owner: chris, detail: "Writing tests", progress: 0.22, span: 10...17, updated: "now", footprint: (6, 260, false), areas: ["Auth"], pr: PullRequest(number: 488, state: .draft, checks: CICheck.standard(running: ["e2e"]))),

        FactoryTask(
            id: "ATL-141", title: "Replace jsonwebtoken with jose", state: .reviewing,
            agent: agents[1], owner: chris, detail: "12 checks passed", diff: (170, 128), span: 5...12, updated: "1h",
            brief: """
            jsonwebtoken pulls in Node crypto and won't run on the edge runtime. Swap it for jose everywhere we sign or verify tokens.

            ## Why now
            The middleware that checks sessions has to move to the edge for the latency budget, and it can't while token verification needs Node's crypto module. Every request currently pays a hop to the Node region just to read the cookie.

            ## What changes
            - `lib/auth/jwt.ts` becomes the one place that signs and verifies, on top of jose.
            - jose's helpers are async, so every caller awaits them: the refresh route, the session middleware, the API key exchange and the WebSocket upgrade.
            - Tokens already issued keep verifying: same algorithm (RS256), same key IDs, same claims.

            ## Out of scope
            Rotating the signing keys, and moving the refresh endpoint itself to the edge. Both follow once this lands.
            """,
            plan: [
                PlanStep(text: "Wrap sign and verify around jose", file: "lib/auth/jwt.ts", progress: .done),
                PlanStep(text: "Await the new async helpers at every call site", file: "app/api/auth/refresh/route.ts", progress: .done),
                PlanStep(text: "Verify sessions in the edge middleware", file: "middleware.ts", progress: .done),
                PlanStep(text: "Await tokens in the WebSocket upgrade", file: "server/ws/upgrade.ts", progress: .done),
                PlanStep(text: "Remove jsonwebtoken and add jose", file: "package.json", progress: .done),
                PlanStep(text: "Update the auth tests for async tokens", file: "tests/auth/jwt.test.ts", progress: .done),
            ],
            activity: [
                ActivityItem(who: "Maple-2", text: "Attached 4 proofs · ready for review", when: "1h"),
                ActivityItem(who: "Maple-2", text: "Opened PR #489", when: "1h"),
            ],
            doneWhen: [
                DoneCriterion(text: "jsonwebtoken is gone from the dependency tree", proof: .terminal, status: .proven,
                              evidence: .terminal(command: "npm ls jsonwebtoken", output: ["atlas-platform@0.42.0 /app", "└── (empty)"])),
                DoneCriterion(text: "Auth test suite passes", proof: .tests, status: .proven,
                              evidence: .tests(suite: "tests/auth", passed: 48, failed: 0)),
                DoneCriterion(text: "Sign-in works end to end on the edge runtime", proof: .video, status: .proven,
                              evidence: .video(caption: "Sign in → refresh → sign out on preview deploy", duration: "0:42")),
                DoneCriterion(text: "Login page renders unchanged", proof: .screenshot, status: .proven,
                              evidence: .screenshot(caption: "/login on preview-489.atlas.dev")),
            ],
            footprint: (9, 298, false), areas: ["Auth"],
            pr: PullRequest(number: 489, state: .open, checks: CICheck.standard())
        ),
        FactoryTask(
            id: "ATL-150", title: "Sign out across all devices", state: .reviewing,
            agent: agents[4], detail: "1 check failing", diff: (96, 12), checksFailing: true, span: 7...13, updated: "35m",
            brief: "A \"Sign out everywhere\" button in account settings that revokes every session for the user.",
            doneWhen: [
                DoneCriterion(text: "Signing out on one device ends sessions on the others", proof: .tests, status: .failed,
                              evidence: .tests(suite: "e2e/sign-out", passed: 11, failed: 1)),
                DoneCriterion(text: "Settings page shows the new button", proof: .screenshot, status: .proven,
                              evidence: .screenshot(caption: "/settings/security on preview-491.atlas.dev")),
            ],
            footprint: (6, 108, false), areas: ["Auth"],
            pr: PullRequest(number: 491, state: .open, checks: CICheck.standard(failing: ["e2e"]))
        ),

        FactoryTask(id: "ATL-133", title: "Auth guard for the assistant panel", state: .merged,
                    agent: agents[0], detail: "#482 · 1d ago", span: 3...10, updated: "1d"),
        FactoryTask(id: "ATL-136", title: "Password reset tokens expire after 30 min", state: .merged,
                    agent: agents[1], owner: chris, detail: "#476 · 3d ago", span: 1...8, updated: "3d"),
        FactoryTask(id: "ATL-138", title: "CSRF protection on form posts", state: .merged,
                    agent: agents[2], detail: "#471 · 4d ago", span: 0...7, updated: "4d"),
        FactoryTask(id: "ATL-139", title: "Session telemetry events", state: .merged,
                    agent: agents[4], detail: "#468 · 5d ago", span: 2...6, updated: "5d"),

        FactoryTask(id: "ATL-145", title: "Roll our own OAuth server", state: .cancelled,
                    detail: "Superseded by ATL-160", span: 0...5, updated: "6d"),

        // Billing v2
        FactoryTask(id: "BIL-88", goal: "Billing v2", title: "Proration for mid-cycle plan changes", state: .awaitingApproval,
                    agent: agents[1], owner: chris, detail: "Plan ready · 5 steps", needsYou: true, span: 8...16, updated: "18m", footprint: (8, 420, true), areas: ["Billing", "Migrations"]),
        FactoryTask(id: "BIL-91", goal: "Billing v2", title: "Idempotency keys on Stripe webhooks", state: .reviewing,
                    agent: agents[4], owner: chris, detail: "2 checks failing", diff: (142, 20), checksFailing: true, span: 6...13, updated: "8m", footprint: (3, 162, false), areas: ["Billing"], pr: PullRequest(number: 490, state: .open, checks: CICheck.standard(failing: ["unit tests", "e2e"]))),
        FactoryTask(id: "BIL-93", goal: "Billing v2", title: "Usage-based metering pipeline", state: .building,
                    agent: agents[1], owner: chris, detail: "Step 2 of 5", progress: 0.4, span: 9...20, updated: "now", footprint: (14, 610, false), areas: ["Billing"], pr: PullRequest(number: 492, state: .draft, checks: CICheck.standard(running: ["unit tests"]))),
        FactoryTask(id: "BIL-84", goal: "Billing v2", title: "Invoice PDF redesign", state: .merged,
                    agent: agents[2], owner: chris, detail: "#459 · 6d ago", span: 0...5, updated: "6d"),
        FactoryTask(id: "BIL-85", goal: "Billing v2", title: "Tax IDs on invoices", state: .merged,
                    agent: agents[3], owner: chris, detail: "#463 · 5d ago", span: 1...6, updated: "5d"),

        // Onboarding revamp
        FactoryTask(id: "ONB-23", goal: "Onboarding revamp", title: "Import a repo from GitHub during sign-up", state: .drafting,
                    detail: "Edited 3h ago", span: 12...24, updated: "3h"),
        FactoryTask(id: "ONB-21", goal: "Onboarding revamp", title: "Workspace templates picker", state: .planning,
                    agent: agents[2], detail: "Drafting plan · 2 of 4", span: 10...21, updated: "5m", footprint: (6, 340, true)),
        FactoryTask(id: "ONB-19", goal: "Onboarding revamp", title: "Invite-teammates step", state: .reviewing,
                    agent: agents[3], detail: "9 checks passed", diff: (88, 14), span: 5...12, updated: "40m", doneWhen: [
                        DoneCriterion(text: "Invite email renders in Gmail and Outlook", proof: .screenshot, status: .proving),
                    ], footprint: (5, 102, false), pr: PullRequest(number: 485, state: .open, checks: CICheck.standard())),
        FactoryTask(id: "ONB-17", goal: "Onboarding revamp", title: "Welcome checklist", state: .merged,
                    agent: agents[0], detail: "#455 · 7d ago", span: 0...4, updated: "7d"),

        // Performance budget
        FactoryTask(id: "PRF-14", goal: "Performance budget", title: "Bundle-size gate in CI", state: .awaitingApproval,
                    agent: agents[0], detail: "Plan ready · 3 steps", needsYou: true, span: 10...15, updated: "1h", footprint: (2, 60, true)),
        FactoryTask(id: "PRF-12", goal: "Performance budget", title: "Lazy-load the code editor bundle", state: .reviewing,
                    agent: agents[0], detail: "11 checks passed", diff: (61, 140), span: 6...12, updated: "2h", footprint: (4, 201, false), pr: PullRequest(number: 483, state: .open, checks: CICheck.standard(running: ["e2e"]))),
        FactoryTask(id: "PRF-9", goal: "Performance budget", title: "Serve images as AVIF from the CDN", state: .merged,
                    agent: agents[4], owner: chris, detail: "#461 · 5d ago", span: 0...6, updated: "5d"),
        FactoryTask(id: "PRF-10", goal: "Performance budget", title: "Cut cold start under 300ms", state: .merged,
                    agent: agents[1], detail: "#466 · 4d ago", span: 2...8, updated: "4d"),

        // Docs site
        FactoryTask(id: "DOC-6", goal: "Docs site", title: "Generated API reference", state: .planning,
                    agent: agents[3], owner: chris, detail: "Exploring codebase…", span: 11...30, updated: "now", footprint: (16, 900, true)),
        FactoryTask(id: "DOC-5", goal: "Docs site", title: "Search with keyboard navigation", state: .building,
                    agent: agents[4], owner: chris, detail: "Step 5 of 7", progress: 0.7, span: 7...15, updated: "now", footprint: (11, 480, false), pr: PullRequest(number: 486, state: .draft, checks: CICheck.standard(running: ["preview deploy"]))),
        FactoryTask(id: "DOC-3", goal: "Docs site", title: "MDX component library", state: .merged,
                    agent: agents[2], owner: chris, detail: "#450 · 9d ago", span: 0...3, updated: "9d"),
    ]

    // MARK: Inbox

    static let seedInbox: [InboxItem] = [
        InboxItem(kind: .mention, taskID: "ATL-147", message: "Chris: “can we keep the old refresh endpoint around for one release?”", when: "3m"),
        InboxItem(kind: .approval, taskID: "ATL-147", message: "Plan v2 · Chris approved · needs 1 more", when: "4m"),
        InboxItem(kind: .approval, taskID: "BIL-88", assignee: chris, message: "Maple-2 wrote a 5-step plan with a data migration", when: "18m"),
        InboxItem(kind: .approval, taskID: "ATL-152", assignee: chris, message: "Maple-1 wrote a 4-step plan", when: "26m"),
        InboxItem(kind: .approval, taskID: "PRF-14", message: "Maple-1 wrote a 3-step plan", when: "1h"),
        InboxItem(kind: .question, taskID: "ATL-160", message: "Auto-provision SAML users, or require an invite?", when: "12m"),
        InboxItem(kind: .failing, taskID: "BIL-91", assignee: chris, message: "webhook-replay and e2e/checkout failing", when: "8m"),
        InboxItem(kind: .failing, taskID: "ATL-150", message: "e2e/sign-out timed out after 30s", when: "35m"),
        InboxItem(kind: .review, taskID: "ONB-19", message: "+88 −14 · all checks passed", when: "40m"),
        InboxItem(kind: .review, taskID: "ATL-141", message: "+170 −128 · all checks passed · high risk", when: "1h"),
        InboxItem(kind: .review, taskID: "PRF-12", message: "+61 −140 · e2e still running", when: "2h"),
    ]


    // MARK: Composer & scratchpad

    static let templates: [(name: String, icon: String, body: String)] = [
        ("Feature", "sparkles", """
        Describe what should exist when this ships, and why it matters.

        ## Context
        - Who is this for?
        - Links to designs, threads or prior art

        ## Done when
        - [ ] The happy path works end to end (record a video)
        - [ ] New tests pass
        - [ ] The page renders correctly in light and dark (screenshot)
        """),
        ("Bug", "ladybug", """
        What's broken, for whom, and how often.

        ## Steps to reproduce
        1. 
        2. 

        ## Expected vs actual

        ## Done when
        - [ ] A failing test reproduces the bug, then passes
        - [ ] The original steps no longer reproduce it (record a video)
        """),
        ("Refactor", "arrow.triangle.2.circlepath", """
        What's being restructured and what must not change.

        ## Constraints
        - No behaviour changes
        - Keep each PR under the budget

        ## Done when
        - [ ] Existing test suite passes unchanged
        - [ ] Type-check is clean
        """),
    ]

    static let sampleBrief = """
    Let people sign in with a passkey from the login page, falling back to email + password. Most of our enterprise customers have asked for this before the Q1 security review.

    ## Context
    - Enrollment already ships in ATL-161; this is the sign-in half
    - Use the WebAuthn helpers in `lib/auth/webauthn.ts`
    - @excid3 has opinions on the fallback copy

    ## Out of scope
    - Passkeys on mobile (separate task)

    ## Done when
    - [ ] Signing in with a passkey works end to end on Safari and Chrome (record a video)
    - [ ] The login page shows the passkey button above the password form (screenshot)
    - [ ] Auth tests pass, including a new passkey assertion test
    - [ ] `npm run typecheck` is clean
    """

    static let seedNotes: [Note] = [
        Note(id: UUID(), title: "Session hardening ideas", body: """
        Random things that came up in the security review prep.

        - Bind refresh tokens to a device fingerprint?
        - Shorter access token TTL for admin roles
        - Log every token family revocation to the audit log
        - Rate-limit the refresh endpoint separately from login

        > Ask @excid3 whether the mobile app can handle 5 minute access tokens.
        """, updated: "12m"),
        Note(id: UUID(), title: "Billing edge cases from support", body: """
        From this week's support tickets:

        1. Downgrade mid-cycle shows a negative invoice line
        2. Tax ID disappears after changing the billing email
        3. Webhook retries double-apply credits

        The third one is probably BIL-91.
        """, updated: "2h"),
        Note(id: UUID(), title: "Q1 security review checklist", body: """
        ## Must have
        - [x] CSRF on every form post
        - [x] Password reset tokens expire
        - [ ] Refresh-token rotation
        - [ ] SSO for enterprise orgs

        ## Nice to have
        - [ ] Passkeys
        """, updated: "1d"),
    ]

    /// How long ago (in minutes) you last opened each task, for "changes since you last looked".
    static let seedLastViewed: [String: Int] = [
        "ATL-147": 25,
        "ATL-144": 60,
        "ATL-141": 90,
        "ATL-158": 30,
    ]
}

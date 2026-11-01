import Foundation
import MapleKit

/// Sample goals, tasks and machines for the demo (`-demo YES`, or Try the demo when signed out), so
/// every screen renders with no server.
enum DemoData {
    static var now: UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
    private static func ago(_ minutes: Double) -> UInt64 { now - UInt64(minutes * 60_000) }

    static let me = "andrea"
    /// `-demoRole member` signs the demo in as a plain member, to see what a non-admin sees; admin otherwise.
    static var role: String { UserDefaults.standard.string(forKey: "demoRole") ?? "admin" }

    static func feed() -> FeedState {
        var feed = FeedState()
        feed.org = "acme"
        feed.name = "Acme"
        feed.me = Wire.Member(login: me, name: "Andrea", role: role, teams: ["mobile"])
        feed.members = [
            feed.me!,
            Wire.Member(login: "sam", name: "Sam Rivera", role: "member", teams: ["mobile"]),
            Wire.Member(login: "kit", name: "Kit Okafor", role: "member", teams: ["platform"]),
        ]
        feed.repos = ["acme/app", "acme/push", "acme/api", "acme/web", "acme/docs"].map { Wire.OrgRepo(name: $0, defaultBranch: "main", isPrivate: true, source: .github) }
        feed.goals = [
            Wire.Goal(id: "g-app", name: "Mobile app", prefix: "APP", color: "#D24E26", summary: "Ship the iPhone app: inbox, review and approvals on the go.", lead: me, repo: "acme/app", repos: ["acme/app", "acme/push"], team: "mobile"),
            Wire.Goal(id: "g-api", name: "Public API", prefix: "API", color: "#2F6FEB", summary: "A versioned REST API with tokens and rate limits.", lead: "kit", repo: "acme/api", repos: ["acme/api"]),
            Wire.Goal(id: "g-web", name: "Billing", prefix: "BIL", color: "#14A866", summary: "Usage-based plans and invoices.", lead: "sam", repo: "acme/web", repos: ["acme/web"]),
            Wire.Goal(id: "g-onb", name: "Onboarding", prefix: "ONB", color: "#8E5BD8", summary: "A first run that gets a new teammate to their first merged task.", lead: me, repo: "acme/app", repos: ["acme/app", "acme/web"], team: "mobile"),
        ]
        feed.tasks = tasks()
        // Low-risk work merges on its own; Kit let the Public API auto-merge up to low.
        feed.policy = Wire.RiskPolicy(maxFiles: 20, maxLines: 400, planApprovals: ["low": 1, "medium": 1, "high": 2], finalReviews: ["low": 0, "medium": 1, "high": 2],
                                      autoMerge: ["low": true, "medium": false, "high": false], autoMerges: UserDefaults.standard.string(forKey: "demoAutoMerges") != "off")
        feed.acceptances = [Wire.RiskAcceptance(goal: "g-api", upTo: .low, by: "kit", at: ago(60 * 24 * 3))]
        feed.machines = machines()
        feed.runnerLatest = "0.65.0"
        feed.serverVersion = "0.51.0"
        feed.hasSnapshot = true
        return feed
    }

    private static func task(_ id: String, goal: String, title: String, state: Wire.TaskState, owner: String = me, updated: Double,
                             _ configure: (inout Wire.Task) -> Void = { _ in }) -> Wire.Task {
        var task = Wire.Task(id: id, goal: goal, title: title, state: state, owner: owner, brief: "", createdAt: ago(updated + 600), updatedAt: ago(updated),
                             planVersion: 1, approvalsNeeded: 1, reviewsNeeded: 1, shareable: false, agent: "claude", model: "opus")
        configure(&task)
        return task
    }

    private static func tasks() -> [Wire.Task] {
        [
            task("APP-14", goal: "g-app", title: "Push notifications when a plan needs your approval", state: .awaitingApproval, owner: "sam", updated: 4) { t in
                t.brief = "When a plan is ready, the people who need to approve it should get a push notification on their phone, with Approve right there in the notification."
                t.planVersion = 2
                t.planSummary = "Register for APNs, store each member's device tokens on the server, and send a notification with an Approve action when a task enters awaitingApproval."
                t.plan = [
                    .init(text: "Register for remote notifications on sign-in and send the device token to POST /api/devices", file: "apps/ios/Sources/Notifications.swift", added: false),
                    .init(text: "Store device tokens per member in D1, removed on sign-out", file: "server/src/devices.ts", added: false),
                    .init(text: "Send an APNs push with an APPROVE category when a task's plan awaits a member's approval", file: "server/src/push.ts", added: true),
                    .init(text: "Handle the Approve action by sending task.approvePlan, without opening the app", file: "apps/ios/Sources/Notifications.swift", added: false, from: "Open the task when the notification is tapped"),
                ]
                t.doneWhen = [
                    .init(text: "A plan awaiting approval sends a push to each approver's phone", proof: .screenshot, status: .pending),
                    .init(text: "Approve from the notification moves the task to building", proof: .video, status: .pending),
                    .init(text: "Server tests cover token storage and removal", proof: .tests, status: .pending),
                ]
                t.risk = .init(level: .medium, reasons: ["Touches sign-in", "New server table"], areas: ["auth"])
                t.footprint = .init(files: 6, lines: 240, estimated: true)
                t.mockups = [.init(id: "m1", title: "The notification", kind: "screen", html: mockupHTML, status: .proposed, version: 1)]
                t.events = [
                    .init(who: "sam", text: "created the task", at: ago(70)),
                    .init(who: "planner", text: "wrote plan v1", at: ago(50)),
                    .init(who: me, text: "asked the planner to handle the Approve action in the background", at: ago(30)),
                    .init(who: "planner", text: "wrote plan v2", at: ago(4)),
                ]
                t.comments = [.init(id: "c1", author: "sam", text: "@andrea can you take a look before standup?", at: ago(3), mentions: [me])]
            },
            task("APP-12", goal: "g-app", title: "Offline cache for the inbox", state: .building, updated: 9) { t in
                t.brief = "Keep the last snapshot on disk so the inbox opens instantly, even on a plane."
                t.effort = "Offline"
                t.plan = [
                    .init(text: "Persist the last snapshot as JSON in Application Support", file: "apps/ios/Sources/FeedCache.swift", progress: .done, added: false),
                    .init(text: "Show the cached inbox while the socket connects", file: "apps/ios/Sources/RootView.swift", progress: .active, added: false),
                    .init(text: "Clear the cache on sign-out", file: "apps/ios/Sources/FactoryStore.swift", progress: .pending, added: false),
                ]
                t.worker = .init(role: .builder, agent: "claude", machine: "m-studio", session: "s1", startedAt: ago(25))
                t.question = .init(text: "Should the cache be per factory, or only the last one you used?", options: ["Per factory", "Only the last one"], role: .builder, at: ago(9))
                t.doneWhen = [
                    .init(text: "FeedCache round-trips a snapshot", proof: .tests, status: .proven,
                          evidence: .init(kind: .tests, summary: "FeedCacheTests: 4 passed", command: "xcodebuild test -only-testing:MapleFactoryTests/FeedCacheTests", passed: 4, failed: 0, by: "builder", at: ago(15))),
                    .init(text: "The inbox opens with no network, showing the cached tasks", proof: .screenshot, status: .pending),
                    .init(text: "Signing out leaves no cache file behind", proof: .terminal, status: .pending),
                ]
                t.approvals = [me]
            },
            task("APP-16", goal: "g-app", title: "Crash reports with Sentry", state: .building, updated: 2) { t in
                t.brief = "Send crashes and errors from the app to Sentry, with release and user context."
                t.plan = [
                    .init(text: "Add @sentry/react-native and initialise it before the app renders", file: "app/index.ts", progress: .active, added: false),
                    .init(text: "Upload source maps from the release build", file: "app/eas.json", progress: .pending, added: false),
                ]
                t.worker = .init(role: .builder, agent: "claude", machine: "m-studio", session: "s2", startedAt: ago(6))
                t.approvals = [me]
            },
            task("API-31", goal: "g-api", title: "Rate limit API tokens per org", state: .reviewing, owner: "kit", updated: 18) { t in
                t.brief = "Each org gets 600 requests a minute across its tokens; over that, 429 with Retry-After."
                t.plan = [
                    .init(text: "A sliding-window counter per org in a Durable Object", file: "server/src/ratelimit.ts", progress: .done, added: false),
                    .init(text: "Answer 429 with Retry-After over the limit", file: "server/src/api.ts", progress: .done, added: false),
                ]
                t.diff = .init(added: 86, removed: 12, files: ["server/src/ratelimit.ts", "server/src/api.ts"])
                t.pr = .init(number: 412, url: "https://github.com/acme/api/pull/412", state: .open, branch: "agent/api-31", base: "main",
                             checks: [.init(name: "test", status: .passed, duration: "1m 12s", required: true), .init(name: "lint", status: .passed, duration: "18s", required: true)])
                t.autoReview = .init(maxRounds: 3, rounds: [.init(number: 1, verdict: .changesRequested, found: 2, at: ago(40)), .init(number: 2, verdict: .passed, found: 0, at: ago(20))],
                                     summary: "The limiter is correct under concurrency; both findings from round 1 are fixed.",
                                     ask: [.init(text: "600 requests a minute per org", verdict: .met)],
                                     proofs: [.init(text: "Tests pass", verdict: .met)],
                                     findings: [
                                        .init(id: "f1", kind: .code, severity: .major, text: "The window resets on every deploy because the counter lives in memory.", file: "server/src/ratelimit.ts", raisedIn: 1, status: .fixed, fixedIn: 2),
                                        .init(id: "f2", kind: .code, severity: .minor, text: "Retry-After was in milliseconds; it should be seconds.", file: "server/src/api.ts", raisedIn: 1, status: .fixed, fixedIn: 2),
                                     ])
                t.doneWhen = [.init(text: "Server tests cover the limit and Retry-After", proof: .tests, status: .proven,
                                    evidence: .init(kind: .tests, summary: "14 tests pass", command: "npm test -- ratelimit", output: ["✓ allows 600 a minute", "✓ answers 429 with Retry-After: 12", "Tests: 14 passed"], passed: 14, failed: 0, by: "builder", at: ago(22)))]
                t.mergeAt = now + 8 * 60_000
            },
            task("BIL-7", goal: "g-web", title: "Invoice PDFs with line items", state: .building, owner: "sam", updated: 35) { t in
                t.brief = "Render each invoice as a PDF with its usage line items."
                t.hand = .init(reason: .needsInput, summary: "Stripe's invoice API doesn't return usage line items for metered prices. Build them from our own usage table instead?", at: ago(35), assignee: me,
                               options: [.init(title: "Use our usage table", detail: "Matches what customers see in the app.", recommended: true),
                                         .init(title: "Wait for Stripe's line items", detail: "Simpler, but needs their beta.", recommended: false)])
                t.worker = .init(role: .builder, agent: "codex", machine: "m-mini", session: "s3", startedAt: ago(50))
            },
            task("API-29", goal: "g-api", title: "Token scopes: read, write and admin", state: .reviewing, owner: "kit", updated: 60) { t in
                t.brief = "Tokens carry scopes; write endpoints refuse read tokens."
                t.pr = .init(number: 405, url: "https://github.com/acme/api/pull/405", state: .open, branch: "agent/api-29", base: "main",
                             checks: [.init(name: "test", status: .failed, duration: "58s", required: true), .init(name: "lint", status: .passed, duration: "14s", required: true)])
                t.autoReview = .init(maxRounds: 3, rounds: [.init(number: 1, verdict: .passed, found: 2, at: ago(70))], summary: "Looks right; two things to pick up later.",
                                     findings: [
                                        .init(id: "f1", kind: .code, severity: .minor, text: "Scopes are compared as strings; an enum would catch typos like \"wirte\".", file: "server/src/tokens.ts", raisedIn: 1, status: .open),
                                        .init(id: "f2", kind: .scope, severity: .major, text: "An admin-scoped token can mint new tokens with wider scopes than its own.", file: "server/src/tokens.ts:64", raisedIn: 1, status: .disputed),
                                     ])
                t.diff = .init(added: 140, removed: 31, files: ["server/src/tokens.ts"])
            },
            task("APP-9", goal: "g-app", title: "Sign in with GitHub's device flow", state: .merged, updated: 60 * 26) { t in
                t.brief = "Sign in on the phone with a code, like the Mac app."
            },
            // Both stranded on Kit's MacBook Air, which went offline: Machines offers to move them.
            task("BIL-8", goal: "g-web", title: "Receipt emails after a payment", state: .building, updated: 300) { t in
                t.brief = "Email a receipt with the invoice PDF once a payment clears."
                t.worker = .init(role: .builder, agent: "claude", machine: "m-air", session: "s4", startedAt: ago(320))
                t.approvals = [me]
            },
            task("API-34", goal: "g-api", title: "OpenAPI spec from the routes", state: .building, owner: "kit", updated: 300) { t in
                t.brief = "Generate an OpenAPI document from the route table."
                t.worker = .init(role: .builder, agent: "claude", machine: "m-air", session: "s5", startedAt: ago(330))
            },
            task("BIL-5", goal: "g-web", title: "Plans page", state: .planning, owner: "sam", updated: 3),
            task("APP-15", goal: "g-app", title: "iPad layout with a sidebar", state: .drafting, updated: 120),
            task("APP-17", goal: "g-app", title: "Home screen widget for the inbox", state: .drafting, updated: 90),
            task("API-33", goal: "g-api", title: "Webhooks for task events", state: .backlog, owner: "kit", updated: 300),
        ]
    }

    private static func machines() -> [Wire.Machine] {
        let gig: UInt64 = 1_073_741_824
        let agents = [Wire.AgentInstall(name: "claude", version: "2.4.1", loggedIn: true), Wire.AgentInstall(name: "codex", version: "0.61.0", loggedIn: true)]
        // The Studio and the Mini share one Claude Code account (the Mini read it last); Kit's Air has its own.
        // `-demoUsage none` leaves every machine without readings, for Usage's empty state.
        let noUsage = UserDefaults.standard.string(forKey: "demoUsage") == "none"
        func ahead(_ minutes: Double) -> UInt64 { now + UInt64(minutes * 60_000) }
        let team = Wire.UsageAccountRef(id: "acct-team", name: "Acme team")
        func claude(observed: UInt64) -> Wire.AgentUsage {
            Wire.AgentUsage(agent: "claude", windows: [
                .init(label: "5h", usedPercent: 82, windowMinutes: 300, resetsAt: ahead(48)),
                .init(label: "7d", usedPercent: 63, windowMinutes: 10080, resetsAt: ahead(60 * 82)),
                .init(label: "7d", usedPercent: 5, windowMinutes: 10080, resetsAt: ahead(60 * 82), name: "Fable"),
            ], plan: "max", observedAt: observed, source: "statusline", account: team)
        }
        let codex = Wire.AgentUsage(agent: "codex", windows: [.init(label: "7d", usedPercent: 8, windowMinutes: 10080, resetsAt: ahead(60 * 166))],
                                    plan: "prolite", observedAt: ago(12), source: "codex", resetCredits: 2, account: .init(id: "acct-sam-codex", name: "Sam · personal"))
        let kit = Wire.AgentUsage(agent: "claude", windows: [.init(label: "5h", usedPercent: 31, windowMinutes: 300, resetsAt: ahead(20)),
                                                             .init(label: "7d", usedPercent: 44, windowMinutes: 10080, resetsAt: ahead(60 * 40))],
                                  plan: "pro", observedAt: ago(60 * 5), source: "statusline", account: .init(id: "acct-kit", name: "Kit · personal"))
        return [
            Wire.Machine(id: "m-studio", name: "Andrea's Mac Studio", owner: me, online: true, version: "0.65.0", os: "macOS 27.0",
                         health: .init(cpu: 0.42, cores: 24, load1: 6.2, memUsed: 41 * gig, memTotal: 96 * gig, diskUsed: 610 * gig, diskTotal: 2000 * gig, uptime: 86400 * 3, agents: agents),
                         sessions: [.init(session: .init(id: "s1", agent: "claude", cwd: "~/maple/worktrees/app-12", startedAt: ago(25), taskId: "APP-12"),
                                          activity: .init(state: .waiting, message: "Asked a question", at: ago(9))),
                                    .init(session: .init(id: "s2", agent: "claude", cwd: "~/maple/worktrees/app-16", startedAt: ago(6), taskId: "APP-16"),
                                          activity: .init(state: .waiting, message: "Claude needs your permission to use Bash", question: permissionQuestion, at: ago(2)))],
                         capacity: 4, usage: noUsage ? [] : [claude(observed: ago(9))]),
            Wire.Machine(id: "m-mini", name: "Build Mini", owner: "sam", online: true, version: "0.63.2", os: "macOS 26.4",
                         health: .init(cpu: 0.18, cores: 10, load1: 1.4, memUsed: 9 * gig, memTotal: 32 * gig, diskUsed: 120 * gig, diskTotal: 512 * gig, uptime: 86400 * 12, agents: agents),
                         sessions: [.init(session: .init(id: "s3", agent: "codex", cwd: "~/maple/worktrees/bil-7", startedAt: ago(50), taskId: "BIL-7"),
                                          activity: .init(state: .waiting, message: "Raised a hand", at: ago(35)),
                                          shares: [.init(login: me, canType: false, by: "sam", at: ago(40))])],
                         capacity: 2, usage: noUsage ? [] : [claude(observed: ago(4)), codex]),
            Wire.Machine(id: "m-air", name: "Kit's MacBook Air", owner: "kit", online: false, lastSeen: ago(60 * 5), version: "0.65.0", os: "macOS 27.0",
                         sessions: [.init(session: .init(id: "s4", agent: "claude", cwd: "~/maple/worktrees/bil-8", startedAt: ago(320), taskId: "BIL-8"),
                                          activity: .init(state: .working, message: "Lost contact", at: ago(300))),
                                    .init(session: .init(id: "s5", agent: "claude", cwd: "~/maple/worktrees/api-34", startedAt: ago(330), taskId: "API-34"),
                                          activity: .init(state: .working, message: "Lost contact", at: ago(300)))],
                         usage: noUsage ? [] : [kit]),
        ]
    }

    /// What a session's terminal shows in the demo, played into SessionTerminalView instead of a socket.
    static func terminal(for session: String) -> String {
        let blue = "\u{1B}[34m", green = "\u{1B}[32m", red = "\u{1B}[31m", yellow = "\u{1B}[33m", dim = "\u{1B}[2m", off = "\u{1B}[0m"
        let lines = session == "s3" ? [
            "\(blue)•\(off) Reading billing/invoices.ts",
            "\(blue)•\(off) Bash(npm test -- invoices)",
            "  \(red)✗ 1 failed\(off), \(green)22 passed\(off)",
            "\(dim)  rounding: expected 10.01, received 10.00\(off)",
            "",
            "\(yellow)✋ Raised a hand: which rounding mode does finance want?\(off)",
        ] : [
            "\(blue)⏺\(off) Reading apps/web/src/limits.ts",
            "\(blue)⏺\(off) Update(apps/web/src/limits.ts)",
            "  \(green)+ const PER_ORG = 600; // req/min\(off)",
            "  \(red)- const PER_ORG = 100;\(off)",
            "\(blue)⏺\(off) Bash(npm test -- limits)",
            "  \(green)✓ 14 passed\(off)",
            "",
            "\(dim)A wide line, the way agents print them: 120 columns, so it runs off the side of the phone and scrolls sideways →|\(off)",
            "",
            "\(yellow)✻ Thinking…\(off)",
        ]
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// What APP-16's builder is stopped at: the runner's `question.permission`.
    private static let permissionQuestion: Wire.JSONValue = .object(["permission": .object([
        "tool": .string("Bash"),
        "summary": .string("npm install @sentry/react-native"),
        "detail": .string("cd app && npm install @sentry/react-native --save"),
        "warning": .string("Runs the package's install scripts on your machine."),
    ])])

    /// A compact `stats` reply for Statistics; its counts scale with the range, so 24h reads smaller than 90d.
    static func stats(days: Int) -> Wire.StatsSummary {
        let scale = Double(days) / 30
        func n(_ month: Double) -> UInt32 { UInt32(max(0, (month * scale).rounded())) }
        let hour: UInt64 = 3_600_000
        func row(_ task: String, _ title: String, _ kind: Wire.FindingKind, _ severity: Wire.Severity, _ text: String, _ file: String?,
                 _ area: String, _ status: Wire.FindingStatus?, _ round: UInt32, _ hoursAgo: UInt64) -> Wire.StatsFindingRow {
            .init(task: task, title: title, kind: kind, severity: severity, text: text, file: file, area: area, status: status, raisedIn: round, at: now - hoursAgo * hour)
        }
        let recent = [
            row("API-31", "Rate limit API tokens per org", .code, .major, "The window resets on every deploy because the counter lives in memory.", "server/src/ratelimit.ts", "server/src", .fixed, 1, 5),
            row("API-31", "Rate limit API tokens per org", .code, .minor, "Retry-After was in milliseconds; it should be seconds.", "server/src/api.ts", "server/src", .fixed, 1, 5),
            row("API-29", "Token scopes: read, write and admin", .scope, .blocker, "An admin-scoped token can mint new tokens with wider scopes than its own.", "server/src/tokens.ts:64", "server/src", .open, 2, 14),
            row("APP-9", "Sign in with GitHub's device flow", .proof, .major, "The screenshot shows the code screen but not the signed-in inbox afterwards.", nil, "(no file)", .fixed, 1, 30),
            row("APP-9", "Sign in with GitHub's device flow", .code, .major, "Polling ignores slow_down, so GitHub rate-limits the device.", "ios/Sources/SignIn.swift:88", "ios/Sources", .fixed, 1, 30),
            row("BIL-7", "Invoice PDFs with line items", .code, .minor, "Totals are summed as floats; use integer cents.", "web/lib/invoice.ts", "web/lib", .open, 1, 60),
            row("BIL-3", "Stripe customer sync", .risk, .major, "The backfill rewrites live customers without a dry run.", "web/db/migrate/0012_customers.sql", "web/db", .disputed, 2, 200),
            row("API-22", "Pagination for list endpoints", .code, .minor, "The cursor isn't signed, so clients can forge offsets.", "server/src/page.ts", "server/src", .fixed, 1, 900),
        ].filter { $0.at >= now - UInt64(days) * 24 * hour }
        let open = UInt32(recent.filter { $0.status == .open }.count)
        return .init(
            days: UInt32(days), since: now - UInt64(days) * 86_400_000, generatedAt: now, inferred: 0,
            totals: .init(merged: max(1, n(47)), autoMerged: n(12), cancelled: n(3), created: max(1, n(58)), tasksTouched: max(2, n(61)), handsRaised: n(16), handsOpen: 1,
                          questions: n(9), steers: n(34), prompts: n(11), restarts: n(4), reviewRounds: max(1, n(83)), findings: max(UInt32(recent.count), n(112)),
                          planVersions: n(74), approvals: n(52), cycleMedianMs: UInt64(4 + days % 5) * hour, handOpenMedianMs: days >= 3 ? 42 * 60_000 : nil,
                          firstTryApproval: days >= 3 ? 0.71 : 1, avgPlanVersions: days >= 3 ? 1.4 : 1, reviewRoundsPerMerge: 1.7, steersPerTask: 0.56),
            costTotal: .init(key: "total", sessions: max(3, n(186)), costUsd: 412.6 * scale, tokens: UInt64(318_400_000 * scale), unpriced: n(31)),
            findings: .init(
                areas: recent.isEmpty ? [] : [.init(key: "server/src", count: max(1, n(38)), tasks: max(1, n(14)), serious: n(22)),
                                              .init(key: "ios/Sources", count: n(21), tasks: n(7), serious: n(12)),
                                              .init(key: "(no file)", count: n(19), tasks: n(14), serious: n(9)),
                                              .init(key: "web/lib", count: n(11), tasks: n(4), serious: n(5))].filter { $0.count > 0 },
                outcomes: .init(fixed: max(UInt32(recent.count) - open, n(78)), disputed: n(9), open: max(open, n(21)), unknown: n(4), roundsToFixMedian: 1),
                recent: recent
            )
        )
    }

    static func diff(for id: String) -> [DiffFile] {
        DiffFile.parse("""
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
        """)
    }

    private static let mockupHTML = """
    <html><head><meta name="viewport" content="width=device-width,initial-scale=1"><style>
    body{margin:0;font:15px -apple-system;background:linear-gradient(160deg,#3b2a5a,#d24e26);height:100vh;display:flex;align-items:flex-start;justify-content:center;padding-top:40px}
    .n{background:rgba(255,255,255,.82);backdrop-filter:blur(20px);border-radius:22px;padding:14px 16px;width:86%;box-shadow:0 8px 30px rgba(0,0,0,.2)}
    .h{display:flex;gap:8px;align-items:center;font-size:12px;color:#555}.i{width:20px;height:20px;border-radius:5px;background:#d24e26}
    b{display:block;margin:6px 0 2px}.a{display:flex;gap:8px;margin-top:12px}.a div{flex:1;text-align:center;padding:9px;border-radius:12px;background:#fff;font-weight:600}
    .a .p{background:#1f883d;color:#fff}
    </style></head><body><div class="n"><div class="h"><div class="i"></div>MAPLE FACTORY · now</div>
    <b>APP-14 plan is ready</b>Push notifications when a plan needs your approval<div class="a"><div class="p">Approve</div><div>Open</div></div></div></body></html>
    """

    /// A check's log in the demo: a GitHub Actions job, failing at the end when the check failed (the Mac's `CheckLog.sample`).
    static func checkLog(task: String, check: String, failed: Bool) -> Wire.ServerToClientCheckLog {
        var lines = [
            "##[group]Run actions/checkout@v4",
            "Syncing repository: acme/api",
            "Determining the checkout info",
            "##[endgroup]",
            "##[group]Run actions/setup-node@v4",
            "Found in cache @ /opt/hostedtoolcache/node/22.11.0/x64",
            "##[endgroup]",
            "##[group]Run npm ci",
            "added 1214 packages, and audited 1215 packages in 21s",
            "found 0 vulnerabilities",
            "##[endgroup]",
            "##[group]Run npm run \(check)",
            "> api@2.14.0 \(check)",
        ]
        lines += (1...14).map { "  \u{1B}[32m✓\u{1B}[0m tokens/scopes.spec.ts › read token reaches GET /v1/items #\($0) (\(80 + $0 * 13)ms)" }
        if failed {
            lines += [
                "  ✗ tokens/scopes.spec.ts › write endpoints refuse read tokens (5012ms)",
                "",
                "    Error: expected 403 Forbidden, got 200 OK",
                "      at tokens/scopes.spec.ts:48:41",
                "",
                "##[warning]1 test was retried",
                "  1 failed, 14 passed (38.2s)",
                "##[error]Process completed with exit code 1.",
                "##[endgroup]",
            ]
        } else {
            lines += ["  15 passed (36.9s)", "##[endgroup]"]
        }
        return .init(id: task, check: check, url: "https://github.com/acme/api/actions/runs/1/job/\(check)", text: lines.joined(separator: "\n"),
                     truncated: false, failedStep: failed ? "Process completed with exit code 1." : nil)
    }
}

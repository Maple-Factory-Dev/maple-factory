import SwiftUI

// MARK: Automated review

/// One thing the review agent flagged. Findings carry across rounds so you can see what got fixed when.
struct ReviewFinding: Identifiable {
    enum Kind: String { case scope = "Scope", proof = "Proof", code = "Code", risk = "Risk" }

    enum Severity {
        case blocker, major, minor

        var title: String {
            switch self {
            case .blocker: "Blocker"
            case .major: "Major"
            case .minor: "Minor"
            }
        }

        var color: Color {
            switch self {
            case .blocker: Theme.State.cancelled
            case .major: Theme.State.awaitingApproval
            case .minor: Theme.textMuted
            }
        }
    }

    enum Status: Equatable { case open, fixed(round: Int), disputed }

    let id = UUID()
    let kind: Kind
    let severity: Severity
    let text: String
    var file: String? = nil
    var raisedIn = 1
    var status: Status = .open
}

/// A review pass and the fix that followed it.
struct ReviewRound: Identifiable {
    enum Verdict { case changesRequested, passed, escalated, inProgress }

    let number: Int
    let verdict: Verdict
    let found: Int
    let when: String
    /// The commit the builder pushed in response, if it did.
    var fix: String? = nil
    var id: Int { number }
}

/// The reviewer's answer to "did it do what was asked?" or "is this proof real?", one line each.
struct ReviewCheck: Identifiable {
    enum Verdict {
        case met, partial, missed

        var icon: String {
            switch self {
            case .met: "checkmark.circle.fill"
            case .partial: "circle.lefthalf.filled"
            case .missed: "xmark.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .met: Theme.State.merged
            case .partial: Theme.State.awaitingApproval
            case .missed: Theme.State.cancelled
            }
        }
    }

    let text: String
    let verdict: Verdict
    var note: String? = nil
    var id: String { text }
}

/// What the dedicated review agent made of the finished change, round by round.
struct AutoReview {
    var reviewer: Agent = FactoryData.reviewer
    var maxRounds = 5
    var rounds: [ReviewRound]
    var summary: String
    var ask: [ReviewCheck]
    var proofs: [ReviewCheck]
    var findings: [ReviewFinding]

    var current: ReviewRound? { rounds.last }
    var open: [ReviewFinding] { findings.filter { $0.status == .open || $0.status == .disputed } }
    var resolved: [ReviewFinding] { findings.filter { if case .fixed = $0.status { true } else { false } } }
}

// MARK: Hand raises

/// An agent stopping to ask a human for help it can't get anywhere else.
struct HandRaise {
    enum Reason {
        case reviewLoop, proofBurden, needsInput, overBudget, sessionEnded, mergeFailed
        /// A reason a newer factory sent that this build doesn't know.
        case other

        var title: String {
            switch self {
            case .reviewLoop: "Review loop exhausted"
            case .proofBurden: "Can't meet the proof"
            case .needsInput: "Needs more input"
            case .overBudget: "Fix goes over budget"
            case .sessionEnded: "Its session ended"
            case .mergeFailed: "Didn't merge"
            case .other: "Needs attention"
            }
        }

        var icon: String {
            switch self {
            case .reviewLoop: "arrow.triangle.2.circlepath"
            case .proofBurden: "checkmark.seal"
            case .needsInput: "text.bubble"
            case .overBudget: "gauge.with.dots.needle.100percent"
            case .sessionEnded: "bolt.horizontal.circle"
            case .mergeFailed: "arrow.triangle.merge"
            case .other: "hand.raised"
            }
        }

        var color: Color {
            switch self {
            case .reviewLoop: Theme.State.cancelled
            case .proofBurden: Theme.State.reviewing
            case .needsInput: Theme.State.planning
            case .overBudget: Theme.State.awaitingApproval
            case .sessionEnded: Theme.State.cancelled
            case .mergeFailed: Theme.State.cancelled
            case .other: Theme.State.awaitingApproval
            }
        }
    }

    struct Option: Identifiable {
        let title: String
        let detail: String
        var recommended = false
        var id: String { title }
    }

    let reason: Reason
    let since: String
    var assignee: Person = FactoryData.me
    let headline: String
    let explanation: String
    /// What the agent already tried before giving up, oldest first.
    let tried: [String]
    let options: [Option]
}

extension FactoryData {
    static let reviewer = Agent(name: "Sentinel", color: Theme.State.reviewing)

    static let seedReviews: [String: AutoReview] = [
        "ATL-141": AutoReview(
            rounds: [
                ReviewRound(number: 1, verdict: .changesRequested, found: 3, when: "2h", fix: "a41c9e2 Await verify in middleware, pin algorithms"),
                ReviewRound(number: 2, verdict: .passed, found: 0, when: "1h"),
            ],
            summary: "Every sign and verify now goes through jose and jsonwebtoken is out of the tree. Round 1 caught a missing await in the middleware that let unverified tokens through, and verify() wasn't pinned to HS256. Both are fixed and covered by new tests. Nothing left that I'd block on.",
            ask: [
                ReviewCheck(text: "Swap jsonwebtoken for jose everywhere we sign or verify", verdict: .met, note: "14 call sites moved · 0 imports of jsonwebtoken left"),
                ReviewCheck(text: "Runs on the edge runtime", verdict: .met, note: "runtime = \"edge\" on all 3 auth routes, preview deploy boots"),
                ReviewCheck(text: "No change for signed-in users", verdict: .met, note: "Existing tokens still verify; checked against a token minted on main"),
            ],
            proofs: [
                ReviewCheck(text: "Dependency tree", verdict: .met, note: "Re-ran npm ls on the PR head, output matches"),
                ReviewCheck(text: "Auth test suite", verdict: .met, note: "48 passed, includes 3 new tests from round 1"),
                ReviewCheck(text: "Edge sign-in video", verdict: .met, note: "Shows sign in, forced refresh and sign out on preview-489"),
                ReviewCheck(text: "Login page screenshot", verdict: .met, note: "Pixel diff against main: 0.0%"),
            ],
            findings: [
                ReviewFinding(kind: .code, severity: .blocker, text: "verifyToken() isn't awaited in withAuth, so the promise is always truthy and any token passes.", file: "lib/auth/middleware.ts:38", status: .fixed(round: 2)),
                ReviewFinding(kind: .risk, severity: .major, text: "jwtVerify() doesn't pin algorithms; pass { algorithms: ['HS256'] }.", file: "lib/auth/jwt.ts:21", status: .fixed(round: 2)),
                ReviewFinding(kind: .proof, severity: .minor, text: "The video cuts before the token refresh, so it doesn't show the refresh path.", status: .fixed(round: 2)),
            ]
        ),
        "ATL-150": AutoReview(
            rounds: [
                ReviewRound(number: 1, verdict: .changesRequested, found: 2, when: "1h", fix: "c19d2f0 Revoke refresh family on sign-out"),
                ReviewRound(number: 2, verdict: .changesRequested, found: 1, when: "50m", fix: "7be44a1 Bust edge session cache"),
                ReviewRound(number: 3, verdict: .inProgress, found: 0, when: "now"),
            ],
            summary: "The button and the revoke endpoint are right. The e2e proof still fails because sessions are cached at the edge for 60 seconds, so the second device stays signed in until the cache expires. Round 2's fix purges the cache, but only in the region that handled the request. Re-checking now.",
            ask: [
                ReviewCheck(text: "Sign out everywhere button in account settings", verdict: .met, note: "Under Security, with a confirm step"),
                ReviewCheck(text: "Revokes every session for the user", verdict: .partial, note: "Revoked in Postgres, still cached at the edge for up to 60s"),
            ],
            proofs: [
                ReviewCheck(text: "Other devices are signed out", verdict: .missed, note: "e2e/sign-out: 1 of 12 failing, the cross-device case"),
                ReviewCheck(text: "Settings screenshot", verdict: .met),
            ],
            findings: [
                ReviewFinding(kind: .scope, severity: .blocker, text: "Edge session cache isn't purged in every region, so other devices stay signed in for up to 60s.", file: "lib/session/edge-cache.ts:52", raisedIn: 2),
                ReviewFinding(kind: .code, severity: .major, text: "Refresh tokens survive sign-out; revoke the token family too.", file: "lib/auth/refresh.ts", status: .fixed(round: 2)),
                ReviewFinding(kind: .code, severity: .minor, text: "Button has no loading state; double-clicks send two requests.", file: "app/settings/security/page.tsx:88", status: .fixed(round: 2)),
            ]
        ),
        "BIL-91": AutoReview(
            rounds: [
                ReviewRound(number: 1, verdict: .changesRequested, found: 2, when: "3h", fix: "e02a9b1 Store event ids with a unique index"),
                ReviewRound(number: 2, verdict: .changesRequested, found: 1, when: "2h", fix: "5f1c7d3 Skip events older than the stored one"),
                ReviewRound(number: 3, verdict: .changesRequested, found: 1, when: "1h", fix: "91aa0e4 Process in arrival order again"),
                ReviewRound(number: 4, verdict: .changesRequested, found: 1, when: "40m", fix: "d7730c2 Compare event.created, not arrival"),
                ReviewRound(number: 5, verdict: .escalated, found: 1, when: "8m"),
            ],
            summary: "Duplicate deliveries are handled correctly now. The remaining failure goes back and forth: dropping stale events breaks the out-of-order test, and applying them breaks the downgrade test. This needs a product decision, not another fix.",
            ask: [
                ReviewCheck(text: "Webhook handler is idempotent", verdict: .met, note: "Unique index on stripe_event_id, replays are no-ops"),
                ReviewCheck(text: "Handles events that arrive out of order", verdict: .missed, note: "Behaviour isn't specified in the brief"),
            ],
            proofs: [
                ReviewCheck(text: "Replay test suite", verdict: .met, note: "Duplicate delivery: 6 of 6 pass"),
                ReviewCheck(text: "Unit and e2e checks", verdict: .missed, note: "2 required checks failing"),
            ],
            findings: [
                ReviewFinding(kind: .scope, severity: .blocker, text: "customer.subscription.updated arriving after a newer event either drops a real downgrade or re-applies a stale plan.", file: "app/api/webhooks/stripe/route.ts:64", raisedIn: 2),
                ReviewFinding(kind: .code, severity: .major, text: "Event ids aren't unique-indexed; a race can process the same event twice.", file: "db/migrations/0044_stripe_events.sql", status: .fixed(round: 2)),
                ReviewFinding(kind: .proof, severity: .minor, text: "Replay proof only covers invoice.paid.", status: .fixed(round: 2)),
            ]
        ),
        "ONB-19": AutoReview(
            rounds: [
                ReviewRound(number: 1, verdict: .changesRequested, found: 1, when: "1h", fix: "3c0b5e8 Inline CSS for the invite email"),
                ReviewRound(number: 2, verdict: .escalated, found: 1, when: "22m"),
            ],
            summary: "The step itself is good. I can't sign off on the email proof: the brief asks for Gmail and Outlook renders, and there's no Outlook test account or Litmus key in the factory's secrets.",
            ask: [
                ReviewCheck(text: "Invite teammates during onboarding", verdict: .met),
                ReviewCheck(text: "Invite email works in Gmail and Outlook", verdict: .partial, note: "Gmail and Apple Mail verified, Outlook unverified"),
            ],
            proofs: [
                ReviewCheck(text: "Email renders in Gmail and Outlook", verdict: .partial, note: "2 of 3 clients captured"),
            ],
            findings: [
                ReviewFinding(kind: .proof, severity: .major, text: "No Outlook render attached; Outlook is where table layouts usually break.", raisedIn: 2),
                ReviewFinding(kind: .code, severity: .major, text: "Email used a <style> block, which Gmail strips.", file: "emails/invite.tsx", status: .fixed(round: 2)),
            ]
        ),
        "PRF-12": AutoReview(
            rounds: [
                ReviewRound(number: 1, verdict: .escalated, found: 1, when: "2h"),
            ],
            summary: "The lazy loading works and cuts 312 KB from the first load. But 9 other routes import the editor directly and would still pull in the whole bundle. Fixing them goes past the PR budget, so I'm checking before it grows.",
            ask: [
                ReviewCheck(text: "Code editor bundle loads on demand", verdict: .partial, note: "On /projects; 9 other routes still import it directly"),
            ],
            proofs: [
                ReviewCheck(text: "Bundle size report", verdict: .met, note: "First load JS: 498 KB → 186 KB on /projects"),
            ],
            findings: [
                ReviewFinding(kind: .scope, severity: .major, text: "9 routes still import CodeEditor directly and skip the lazy boundary.", file: "app/(app)/**/page.tsx"),
            ]
        ),
    ]

    static let seedHands: [String: HandRaise] = [
        "BIL-91": HandRaise(
            reason: .reviewLoop, since: "8m",
            headline: "Stripe events arriving out of order: drop the stale one or apply it?",
            explanation: "Five review rounds couldn't settle this. When customer.subscription.updated arrives after a newer event for the same customer, dropping it loses a real downgrade and applying it brings back an old plan. The brief doesn't say which one is right, so each fix just breaks the other test.",
            tried: [
                "Unique index on event id (fixed duplicates)",
                "Skip events older than the last one stored",
                "Process strictly in arrival order",
                "Compare event.created instead of arrival time",
            ],
            options: [
                .init(title: "Re-fetch the subscription from Stripe on every update", detail: "Treat the webhook as a nudge and read the current state. One extra API call per event, but order stops mattering.", recommended: true),
                .init(title: "Drop events older than the stored one", detail: "Simplest. A downgrade can be lost if events cross, and it gets fixed on the next event."),
                .init(title: "Queue events per customer and apply in order", detail: "Correct, but about 220 more lines and over the PR budget. Would split into a follow-up."),
            ]
        ),
        "ONB-19": HandRaise(
            reason: .proofBurden, since: "22m",
            headline: "Can't get an Outlook render of the invite email",
            explanation: "“Done when” asks for screenshots in Gmail and Outlook. I have Gmail and Apple Mail, but the factory has no Outlook test inbox and no Litmus API key, so I can't produce the Outlook proof myself.",
            tried: [
                "Sent to the shared QA Gmail inbox and captured it",
                "Rendered in Apple Mail on the factory Mac mini",
                "Looked for Outlook or Litmus credentials in the factory secrets",
            ],
            options: [
                .init(title: "Add a Litmus API key to the factory secrets", detail: "I'll capture Outlook 2021, Outlook.com and new Outlook, and reuse it for every email after this.", recommended: true),
                .init(title: "Accept Gmail and Apple Mail as enough", detail: "Mark the Outlook part of the check as waived, with your name on it."),
                .init(title: "I'll attach the Outlook screenshot myself", detail: "The task waits in Reviewing until a screenshot shows up on the check."),
            ]
        ),
        "PRF-12": HandRaise(
            reason: .overBudget, since: "2h", assignee: chris,
            headline: "Finishing the fix takes this PR to 15 files and 520 lines",
            explanation: "Review found 9 more routes that import the editor directly. Fixing them in this PR goes past the 12-file, 500-line budget. I can split them out or go over once.",
            tried: [
                "Checked for a shared layout to fix them all at once (none fits all 9)",
                "Codemod to swap the imports (works, but touches every route)",
            ],
            options: [
                .init(title: "Ship /projects now, split the 9 routes into PRF-15", detail: "This PR merges at 4 files. The follow-up is about 11 files and 330 lines.", recommended: true),
                .init(title: "Allow going over budget this once", detail: "One PR, 15 files and 520 lines. Needs an extra review under the risk policy."),
            ]
        ),
        "DOC-6": HandRaise(
            reason: .needsInput, since: "35m", assignee: chris,
            headline: "Three API surfaces: which ones are public?",
            explanation: "The brief says “generate the API reference”. There's REST v1, REST v2 and an internal tRPC router, and about 40% of v2 is behind feature flags. I don't want to plan docs for endpoints you'd rather keep private.",
            tried: [
                "Read the OpenAPI specs for v1 and v2",
                "Checked the marketing site for which APIs are advertised (v2 only)",
            ],
            options: [
                .init(title: "REST v2 only, skip flagged endpoints", detail: "About 120 endpoints. v1 gets a deprecation banner linking to v2.", recommended: true),
                .init(title: "REST v1 and v2", detail: "About 190 endpoints, with a version switcher."),
                .init(title: "Everything, tRPC included", detail: "Internal docs behind sign-in. Roughly doubles the plan."),
            ]
        ),
    ]
}

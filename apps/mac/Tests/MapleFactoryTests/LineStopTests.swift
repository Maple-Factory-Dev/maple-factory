import Foundation
import Testing
import MapleKit
@testable import MapleFactory

/// Stop the line (MF-397): which repos the popover offers, what "All goal repos" holds, the reason and the pill.
struct LineStopTests {
    private func goal(_ name: String, repo: String?, repos: [String] = [], archived: Bool? = nil) -> Wire.Goal {
        Wire.Goal(id: name, name: name, prefix: "X", color: "blue", summary: "", lead: "", repo: repo,
                  repos: repos, archived: archived)
    }

    private var goals: [Wire.Goal] {
        [goal("Web", repo: "acme/web", repos: ["acme/web", "acme/shared"]),
         goal("API", repo: "acme/api"),
         goal("Old", repo: "acme/legacy", archived: true)]
    }

    private func hold(_ repo: String) -> Wire.MergeHold { Wire.MergeHold(repo: repo, reason: "Incident #42", by: "jo", at: 0) }

    @Test func offersTheCurrentGoalsRepoFirstThenGoalReposThenTheRest() {
        let offered = LineStop.offeredRepos(current: "acme/api", goals: goals,
                                            orgRepos: ["acme/docs", "ACME/web", "acme/api", "acme/legacy"])
        #expect(offered == ["acme/api", "acme/web", "acme/shared", "acme/docs", "acme/legacy"])
    }

    @Test func offersGoalReposFirstWithNoCurrentGoal() {
        #expect(LineStop.offeredRepos(current: nil, goals: goals, orgRepos: ["acme/docs"]) == ["acme/web", "acme/shared", "acme/api", "acme/docs"])
    }

    @Test func aGoalsRepoFallsBackToItsFirstRepo() {
        #expect(LineStop.repo(of: goal("G", repo: nil, repos: ["acme/x", "acme/y"])) == "acme/x")
        #expect(LineStop.repo(of: goal("G", repo: "acme/z")) == "acme/z")
        #expect(LineStop.repo(of: nil) == nil)
    }

    @Test func allGoalReposExpandsToUnarchivedGoalsReposSkippingHeldOnes() {
        #expect(LineStop.repos(for: .allGoalRepos, goals: goals, holds: []) == ["acme/web", "acme/shared", "acme/api"])
        #expect(LineStop.repos(for: .allGoalRepos, goals: goals, holds: [hold("ACME/Shared")]) == ["acme/web", "acme/api"])
    }

    @Test func oneRepoIsSkippedWhenAlreadyHeld() {
        #expect(LineStop.repos(for: .repo("acme/api"), goals: goals, holds: []) == ["acme/api"])
        #expect(LineStop.repos(for: .repo("acme/api"), goals: goals, holds: [hold("acme/api")]).isEmpty)
    }

    @Test func reasonMustBeNonBlankAndAtMost200Characters() {
        #expect(LineStop.validReason("  Incident #42 \n") == "Incident #42")
        #expect(LineStop.validReason("   ") == nil)
        #expect(LineStop.validReason("") == nil)
        #expect(LineStop.validReason(String(repeating: "a", count: 200)) != nil)
        #expect(LineStop.validReason(String(repeating: "a", count: 201)) == nil)
    }

    @Test func pillSummarisesTheHolds() {
        #expect(LineStop.pillLabel([]) == nil)
        #expect(LineStop.pillLabel([hold("acme/api")]) == "Line stopped · acme/api")
        #expect(LineStop.pillLabel([hold("acme/api"), hold("acme/web"), hold("acme/docs")]) == "Line stopped · 3 repos")
        #expect(LineStop.bannerTitle([hold("acme/api")]) == "Merges into acme/api are on hold")
        #expect(LineStop.bannerTitle([hold("a/b"), hold("c/d")]) == "Merges into 2 repos are on hold")
    }

    @MainActor @Test func detailSaysWhyWhoAndWhen() {
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        #expect(LineStop.detail(Wire.MergeHold(repo: "acme/api", reason: "Incident #42", by: "jo", at: now)) == "Incident #42 · jo, just now")
    }

    @Test func paletteOffersStopTheLineSignedInAndRestartOnlyWhileStopped() {
        #expect(!PaletteAction.available(taskPanel: true, signedIn: false, holds: 0).contains(.stopTheLine))
        let signedIn = PaletteAction.available(taskPanel: true, signedIn: true, holds: 0)
        #expect(signedIn.contains(.stopTheLine))
        #expect(!signedIn.contains(.restartTheLine))
        #expect(PaletteAction.available(taskPanel: true, signedIn: true, holds: 2).contains(.restartTheLine))
        #expect(!PaletteAction.available(taskPanel: false, signedIn: true, holds: 0).contains(.toggleTaskPanel))
    }
}

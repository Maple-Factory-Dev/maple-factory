import Foundation
import MapleKit

/// "Stop the line": the top bar's andon cord for merge holds. Pure, so the popover's choices are tested on their own.
enum LineStop {
    /// The server's limit on a hold's reason.
    static let maxReason = 200

    /// What the popover's picker holds: one repo, or every repo the goals use.
    enum Target: Hashable {
        case repo(String)
        case allGoalRepos
    }

    /// The repos to offer, each once (case-insensitively): the current goal's repo first, then the goals' repos,
    /// then the rest of the org's.
    static func offeredRepos(current: String?, goals: [Wire.Goal], orgRepos: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        func add(_ repo: String?) {
            guard let repo, !repo.isEmpty, seen.insert(repo.lowercased()).inserted else { return }
            out.append(repo)
        }
        add(current)
        for repo in goalRepos(goals) { add(repo) }
        for repo in orgRepos { add(repo) }
        return out
    }

    /// Every repo the (unarchived) goals work in, each once, in goal order.
    static func goalRepos(_ goals: [Wire.Goal]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for goal in goals where goal.archived != true {
            for repo in [goal.repo].compactMap({ $0 }) + goal.repos where !repo.isEmpty && seen.insert(repo.lowercased()).inserted {
                out.append(repo)
            }
        }
        return out
    }

    /// The repo a goal's tasks change by default: its `repo`, else the first of `repos`.
    static func repo(of goal: Wire.Goal?) -> String? {
        guard let goal else { return nil }
        if let repo = goal.repo, !repo.isEmpty { return repo }
        return goal.repos.first { !$0.isEmpty }
    }

    /// The repos a target puts on hold, leaving out ones already held.
    static func repos(for target: Target, goals: [Wire.Goal], holds: [Wire.MergeHold]) -> [String] {
        let held = Set(holds.map { $0.repo.lowercased() })
        let repos: [String] = switch target {
        case .repo(let repo): [repo]
        case .allGoalRepos: goalRepos(goals)
        }
        return repos.filter { !held.contains($0.lowercased()) }
    }

    /// The reason, trimmed, if the server would take it: not blank, at most 200 characters.
    static func validReason(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.count > maxReason ? nil : trimmed
    }

    /// The top bar pill while holds are on: "Line stopped · acme/api", or "Line stopped · 3 repos". Nil with none.
    static func pillLabel(_ holds: [Wire.MergeHold]) -> String? {
        switch holds.count {
        case 0: nil
        case 1: "Line stopped · \(holds[0].repo)"
        default: "Line stopped · \(holds.count) repos"
        }
    }

    /// "Incident #42 · jo, 4m ago": why, who and when, for the banner and the popover.
    @MainActor static func detail(_ hold: Wire.MergeHold) -> String {
        let ago = LiveAdapter.ago(hold.at)
        return "\(hold.reason) · \(hold.by), \(ago == "now" ? "just now" : "\(ago) ago")"
    }

    /// The banner's headline: one hold names its repo, several count them.
    static func bannerTitle(_ holds: [Wire.MergeHold]) -> String {
        holds.count == 1 ? "Merges into \(holds[0].repo) are on hold" : "Merges into \(holds.count) repos are on hold"
    }

    /// The lift confirmation's title: "Lift the hold on acme/api?", or "Restart the line?" for several.
    static func liftTitle(repos: [String]) -> String {
        repos.count == 1 ? "Lift the hold on \(repos[0])?" : "Restart the line?"
    }

    /// Its destructive button: "Lift hold", or "Lift all 3 holds".
    static func liftButton(count: Int) -> String {
        count <= 1 ? "Lift hold" : "Lift all \(count) holds"
    }

    /// What lifting does, then why each hold went on: "Merges into acme/api go again; the tasks waiting merge on
    /// their own. Held by jo: Incident #42."
    static func liftMessage(holds: [Wire.MergeHold]) -> String {
        let repos = holds.map(\.repo).joined(separator: ", ")
        let what = "Merges into \(repos) go again; the tasks waiting merge on their own."
        switch holds.count {
        case 0: return what
        case 1: return "\(what) Held by \(holds[0].by): \(holds[0].reason)."
        default: return ([what] + holds.map { "\($0.repo), held by \($0.by): \($0.reason)." }).joined(separator: "\n")
        }
    }
}

extension FactoryClient {
    /// Puts each repo on hold with the same reason: one repos.holdMerges per repo.
    func stopLine(repos: [String], reason: String) {
        for repo in repos { holdMerges(repo: repo, reason: reason) }
    }

    /// Lifts every hold (the palette's "Restart the line").
    func restartLine() {
        for hold in mergeHolds { releaseMerges(repo: hold.repo) }
    }
}

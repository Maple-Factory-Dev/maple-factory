import SwiftUI

enum RiskLevel: Int, CaseIterable, Comparable {
    case low, medium, high

    static func < (a: RiskLevel, b: RiskLevel) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    var color: Color {
        switch self {
        case .low: Theme.State.merged
        case .medium: Theme.State.awaitingApproval
        case .high: Theme.State.cancelled
        }
    }

    var icon: String {
        switch self {
        case .low: "checkmark.shield"
        case .medium: "exclamationmark.shield"
        case .high: "exclamationmark.shield.fill"
        }
    }
}

/// A risk check: code paths that raise a task's risk just by being touched, or a plain-language rule
/// the planner judges and cites (like "changes the public HTTP API").
struct SensitiveArea: Identifiable {
    var name: String
    var paths: [String]
    var level: RiskLevel
    var enabled = true
    var rule: String? = nil
    /// Names are unique (the server refuses two the same) and the Mac editor doesn't rename checks.
    var id: String { name }

    var isRule: Bool { !(rule ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
}

/// One reason the server gave for a task's risk level (Wire.RiskFactor).
struct RiskFactor: Identifiable, Equatable {
    enum Source { case planner, check, size, classifier, acceptance }
    let source: Source
    let label: String
    let level: RiskLevel
    var detail: String? = nil
    var files: [String] = []
    var id: String { "\(source)/\(label)" }
}

/// Team-wide rules for how big a change may be and how much human sign-off each risk level needs.
struct RiskPolicy {
    var maxFiles = 12
    var maxLines = 500
    var sensitiveAreas: [SensitiveArea] = [
        SensitiveArea(name: "Auth", paths: ["lib/auth/**", "app/api/auth/**"], level: .high),
        SensitiveArea(name: "Billing", paths: ["lib/billing/**", "app/api/billing/**"], level: .high),
        SensitiveArea(name: "Migrations", paths: ["db/migrations/**"], level: .medium),
    ]
    var planApprovals: [RiskLevel: Int] = [.low: 1, .medium: 1, .high: 2]
    var finalReviews: [RiskLevel: Int] = [.low: 0, .medium: 1, .high: 2]
    var autoMerge: [RiskLevel: Bool] = [.low: true, .medium: false, .high: false]
    /// An approved change that won't merge goes back to a builder to fix before anyone's asked.
    var autoFixMerges = true
    /// Off for the whole factory: nothing merges on its own, whatever the levels or a goal's acceptance say.
    var autoMerges = true
    /// The most leftovers one Scout run turns into drafted plans (1–10).
    var scoutItems = 3
    /// Minutes of agent work a task gets before it asks for a hand; 0 is off.
    var taskMinutes = 60
    /// Dollars of agent work a task gets before it asks for a hand; nil is no cost limit.
    var taskCostUsd: Double?
    /// Past its budget, a task raises a hand (false), or hands off: pushes its work, files a draft follow-up for
    /// a person to review and reinvest in, and is cancelled (true).
    var handOffOverBudget = false
    /// The reviewer grades each built change against this prompt; it can raise the risk and ask for a person's review.
    var classifierEnabled = false
    var classifierPrompt = ""

    func assess(_ task: FactoryTask, acceptance: RiskAcceptance? = nil) -> RiskAssessment? {
        guard let footprint = task.footprint else { return nil }

        let areas = sensitiveAreas.filter { $0.enabled && task.areas.contains($0.name) }
        let overFiles = footprint.files > maxFiles
        let overLines = footprint.lines > maxLines
        let areaLevel = areas.map(\.level).max() ?? .low
        let sizeLevel: RiskLevel = overFiles || overLines ? .medium : .low
        let level = max(areaLevel, sizeLevel, task.plannedRisk)
        // A goal that has accepted risk up to this level lets the factory merge without human review.
        // The classifier asking for a person's review overrides acceptance, as on the server.
        let humanReview = classifierEnabled && task.classifierReview
        let accepted = !humanReview && (acceptance.map { level <= $0.autoMergeUpTo } ?? false)
        let reviews = accepted ? 0 : finalReviews[level, default: 1]

        return RiskAssessment(
            level: level,
            files: footprint.files,
            lines: footprint.lines,
            estimated: footprint.estimated,
            areas: areas,
            factors: task.riskFactors,
            overFiles: overFiles,
            overLines: overLines,
            approvals: planApprovals[level, default: 1],
            reviews: humanReview ? max(reviews, 1) : reviews,
            autoMerge: !humanReview && autoMerges && (accepted || autoMerge[level, default: false]),
            acceptance: accepted && autoMerges ? acceptance : nil,
            suggestedSplit: overFiles || overLines
                ? max(Int((Double(footprint.files) / Double(maxFiles)).rounded(.up)),
                      Int((Double(footprint.lines) / Double(maxLines)).rounded(.up)))
                : nil
        )
    }
}

struct RiskAssessment {
    let level: RiskLevel
    let files: Int
    let lines: Int
    /// Planning-stage numbers are the agent's estimate; building and later are measured from the diff.
    let estimated: Bool
    let areas: [SensitiveArea]
    /// The server's reasons for the level, highest first; empty from an older server or in the demo.
    let factors: [RiskFactor]
    let overFiles: Bool
    let overLines: Bool
    let approvals: Int
    let reviews: Int
    let autoMerge: Bool
    /// Set when the goal's risk acceptance is what's allowing auto-merge.
    let acceptance: RiskAcceptance?
    let suggestedSplit: Int?
}

/// A goal-level decision to let the factory auto-merge work up to a given risk level, on the record.
struct RiskAcceptance {
    var autoMergeUpTo: RiskLevel
    var acceptedBy: Person
    var when: String
    var note: String? = nil
}

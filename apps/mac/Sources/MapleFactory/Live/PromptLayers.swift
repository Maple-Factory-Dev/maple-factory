import Foundation

/// What an agent in one role is told, in the order it reads it: Maple's own prompt, then the org's
/// instructions, then the goal's. The goal's are appended after the org's (server prompts.ts `extra`),
/// never in place of them.
struct PromptLayers: Equatable {
    enum Role: String, CaseIterable { case planner, builder, reviewer }

    enum Source: Equatable { case builtIn, org, goal }

    struct Layer: Equatable {
        let source: Source
        /// None: nothing set at this layer. The built-in one's text lives on the server.
        let text: String?
        var editable: Bool { source == .goal }
    }

    enum Status: Equatable {
        /// The goal adds its own after the org's.
        case addsToOrg
        /// The org has none for this role; the goal's is the only addition.
        case onlyAddition
        /// The goal adds nothing (the org's may still apply).
        case notSet
    }

    let role: Role
    let layers: [Layer]

    init(role: Role, org: Wire.PromptAdditions?, goal: Wire.PromptAdditions?) {
        self.role = role
        let text = { (p: Wire.PromptAdditions?) -> String? in
            guard let p else { return nil }
            let value = switch role {
            case .planner: p.planner
            case .builder: p.builder
            case .reviewer: p.reviewer
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        layers = [Layer(source: .builtIn, text: nil), Layer(source: .org, text: text(org)), Layer(source: .goal, text: text(goal))]
    }

    var org: String? { layers.first { $0.source == .org }?.text }
    var goal: String? { layers.first { $0.source == .goal }?.text }

    var status: Status {
        guard goal != nil else { return .notSet }
        return org == nil ? .onlyAddition : .addsToOrg
    }

    /// All three roles, planner first.
    static func all(org: Wire.PromptAdditions?, goal: Wire.PromptAdditions?) -> [PromptLayers] {
        Role.allCases.map { PromptLayers(role: $0, org: org, goal: goal) }
    }
}

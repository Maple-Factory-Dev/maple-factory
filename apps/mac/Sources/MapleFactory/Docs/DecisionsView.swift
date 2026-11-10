import SwiftUI
import MapleKit

/// The Decisions page (MF-367, docs/planning-docs.md): every doc decision in the factory, filtered by status,
/// person (proposed or decided by) and goal. A row opens its doc.
struct DecisionsView: View {
    @Environment(AppState.self) private var state
    @Environment(FactoryClient.self) private var client
    @State private var filter: FeedState.DecisionFilter = .open
    @State private var person: String? = nil
    @State private var goal: String? = nil

    private var people: [String] {
        Array(Set(client.decisions.flatMap { [$0.proposedBy, $0.decidedBy].compactMap { $0 } })).sorted()
    }

    var body: some View {
        let list = FeedState.filterDecisions(client.decisions, filter: filter, person: person, goal: goal)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Picker("Status", selection: $filter) {
                    ForEach(FeedState.DecisionFilter.allCases, id: \.self) { f in
                        let n = FeedState.filterDecisions(client.decisions, filter: f, person: person, goal: goal).count
                        Text(f == .all ? f.rawValue : "\(f.rawValue) \(n)").tag(f)
                    }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Picker("Person", selection: $person) {
                    Text("Anyone").tag(String?.none)
                    ForEach(people, id: \.self) { Text("@\($0)").tag(String?.some($0)) }
                }
                .fixedSize()
                Picker("Goal", selection: $goal) {
                    Text("All goals").tag(String?.none)
                    ForEach(client.goals, id: \.id) { Text($0.name).tag(String?.some($0.id)) }
                }
                .fixedSize()
                Spacer()
            }
            if list.isEmpty {
                ContentUnavailableView(filter == .open ? "No open decisions" : "No decisions match", systemImage: "checkmark.seal",
                                       description: Text("Propose one in a doc with /decision."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(list) { d in DecisionRow(decision: d) }
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.editorBG)
    }
}

struct DecisionRow: View {
    @Environment(AppState.self) private var state
    @Environment(FactoryClient.self) private var client
    let decision: Wire.Decision
    @State private var hovering = false

    private var statusText: String { decision.status == .proposed ? "open" : decision.status.rawValue }
    private var tint: Color {
        switch decision.status {
        case .proposed: .orange
        case .accepted: .green
        case .rejected: .red
        default: .gray
        }
    }

    var body: some View {
        let d = decision
        let chosen = d.options.first { $0.id == d.chosen }?.label
        let doc = client.docs.first { $0.id == d.doc }
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(statusText).font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(tint.opacity(0.18)))
                Text(d.question).font(.system(size: 13, weight: .medium)).lineLimit(2)
                Spacer()
            }
            HStack(spacing: 4) {
                if let chosen, d.status != .proposed { Text("→ \(chosen)").fontWeight(.semibold) }
                Text(who(d))
                if let doc { Text("· in \(doc.title.isEmpty ? "Untitled doc" : doc.title)") }
            }
            .font(.system(size: 11.5)).foregroundStyle(Theme.textMuted).lineLimit(1)
            if let why = d.why { Text("Why: \(why)").font(.system(size: 11.5)).italic().foregroundStyle(Theme.textMuted).lineLimit(2) }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Theme.fill : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { state.closeFocus(); state.destination = .doc(d.doc) }
    }

    private func who(_ d: Wire.Decision) -> String {
        func ago(_ ms: UInt64?) -> String { Date(timeIntervalSince1970: Double(ms ?? 0) / 1000).formatted(.relative(presentation: .named)) }
        if d.status == .proposed { return "proposed by @\(d.proposedBy)\(d.agent.map { " (\($0))" } ?? "") \(ago(d.proposedAt))" }
        return "\(d.status == .rejected ? "rejected" : "accepted") by @\(d.decidedBy ?? "?") \(ago(d.decidedAt))"
    }
}

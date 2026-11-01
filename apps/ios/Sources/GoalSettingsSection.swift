import MapleKit
import SwiftUI

/// A goal's Merging section: how far the factory may auto-merge its work, and archiving it. Like the
/// server, only the goal's lead or an admin can change either; anyone else sees them read-only.
/// The rest of a goal is edited in GoalEditorSheet (Edit goal); scouting a goal, and its color, due date
/// and folder, stay on the Mac.
struct GoalSettingsSection: View {
    @Environment(FactoryStore.self) private var store
    let goal: Wire.Goal
    /// After archiving: back to Goals.
    var onArchive: () -> Void = {}

    @State private var confirmingArchive = false

    var body: some View {
        let canLead = store.canLead(goal)
        let acceptance = store.feed.acceptance(for: goal.id)
        Section {
            Picker("Auto-merge up to", selection: Binding(
                get: { acceptance?.upTo },
                set: { level in if level != acceptance?.upTo { store.acceptRisk(goal: goal, upTo: level) } }
            )) {
                Text("Off").tag(Wire.RiskLevel?.none)
                ForEach(Wire.RiskLevel.allCases, id: \.self) { level in
                    Text(level.title).tag(Wire.RiskLevel?.some(level))
                }
            }
            .pickerStyle(.menu)
            .disabled(!canLead)
            .accessibilityIdentifier("auto-merge-picker")

            if goal.archived == true {
                Button("Unarchive Goal") { store.archiveGoal(goal, archived: false, unfinished: nil) }
                    .disabled(!canLead)
                    .accessibilityIdentifier("unarchive-goal")
            } else {
                Button("Archive Goal…", role: .destructive) { confirmingArchive = true }
                    .disabled(!canLead)
                    .accessibilityIdentifier("archive-goal")
            }
        } header: {
            Text("Merging")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(caption(acceptance)).accessibilityIdentifier("auto-merge-caption")
                if store.feed.policy?.autoMerges == false {
                    Text("Auto-merge is off for the whole factory, so a person merges everything.")
                        .accessibilityIdentifier("auto-merge-factory-off")
                }
                if !canLead {
                    Text("Only \(goal.lead) or an admin can change this.").accessibilityIdentifier("goal-settings-who")
                }
            }
        }
        .confirmationDialog(dialogTitle, isPresented: $confirmingArchive, titleVisibility: .visible) {
            let unfinished = store.feed.unfinishedTasks(in: goal.id)
            if unfinished.isEmpty {
                Button("Archive Goal", role: .destructive) { archive(nil) }
            } else {
                Button("Cancel tasks and clean up", role: .destructive) { archive(.cleanup) }
                Button("Cancel tasks, keep worktrees", role: .destructive) { archive(.cancel) }
                Button("Let them finish") { archive(.finish) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(dialogMessage)
        }
    }

    private var dialogTitle: String { "Archive \(goal.name)?" }

    private var dialogMessage: String {
        let count = store.feed.unfinishedTasks(in: goal.id).count
        let hidden = "It leaves the Goals list; its tasks and history stay."
        return switch count {
        case 0: hidden
        case 1: "1 task isn't finished. End it, or let it finish? \(hidden)"
        default: "\(count) tasks aren't finished. End them, or let them finish? \(hidden)"
        }
    }

    /// Archives, then goes back to Goals, as the Mac goes back to All goals.
    private func archive(_ unfinished: Wire.UnfinishedTasks?) {
        store.archiveGoal(goal, archived: true, unfinished: unfinished)
        onArchive()
    }

    /// "You accepted up to medium · 5m ago", or what Off means.
    private func caption(_ acceptance: Wire.RiskAcceptance?) -> String {
        guard let acceptance else { return "Off: the factory's own rules decide what merges without a person." }
        let who = acceptance.by == store.me ? "You" : store.feed.member(acceptance.by)?.name ?? acceptance.by
        let ago = When.ago(acceptance.at)
        return "\(who) accepted up to \(acceptance.upTo.rawValue) · \(ago == "now" ? "just now" : "\(ago) ago")"
    }
}

struct GoalSettingsRoute: Hashable { let goal: String }

/// Goal settings, from the goal page's … menu: its Merging section (auto-merge and archiving).
struct GoalSettingsView: View {
    @Environment(FactoryStore.self) private var store
    let id: String
    var onArchive: () -> Void = {}

    var body: some View {
        Form {
            if let goal = store.feed.goal(id) { GoalSettingsSection(goal: goal, onArchive: onArchive) }
        }
        .navigationTitle("Goal settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension Wire.RiskLevel {
    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

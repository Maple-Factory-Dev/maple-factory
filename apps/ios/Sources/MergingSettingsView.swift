import MapleKit
import SwiftUI

/// What happens after a change is approved, for everyone in the factory. Saved as each toggle flips.
struct MergingSettingsView: View {
    @Environment(FactoryStore.self) private var store

    var body: some View {
        Form {
            if store.feed.policy == nil {
                ContentUnavailableView("Not connected", systemImage: "arrow.triangle.merge", description: Text("Connect to a factory to see how it merges."))
            } else {
                Section {
                    toggle("Merge approved changes automatically",
                           detail: "When a change is proven, reviewed and its checks pass, the factory merges it if its risk level (or its goal's accepted risk) allows. Off: nothing merges on its own; ready changes wait in Pending merge until someone taps Merge.",
                           key: \.autoMerges, id: "toggle-autoMerges")
                    toggle("Fix merges automatically",
                           detail: "When an approved change won't merge into its base, a builder brings the branch up to date, resolves the conflicts and pushes, and review runs again. It tries twice before asking you. Off: the factory raises its hand and you pick what to do.",
                           key: \.autoFixMerges, id: "toggle-autoFixMerges")
                } header: {
                    Text("After approval")
                } footer: {
                    if !store.isAdmin { AdminOnlyNote() }
                }
            }
        }
        .navigationTitle("Merging")
    }

    private func toggle(_ title: String, detail: String, key: WritableKeyPath<Wire.RiskPolicy, Bool?>, id: String) -> some View {
        Toggle(isOn: Binding(
            get: { store.feed.policy?[keyPath: key] ?? true },
            set: { on in
                guard var policy = store.feed.policy else { return }
                policy[keyPath: key] = on
                store.savePolicy(policy)
            }
        )) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(!store.isAdmin)
        .accessibilityIdentifier(id)
    }
}

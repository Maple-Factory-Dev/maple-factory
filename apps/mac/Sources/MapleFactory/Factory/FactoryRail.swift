import SwiftUI

/// The Slack-style factory rail on the far left: a tile for each saved factory, the current one
/// ringed, ⌘1–⌘9 to jump between them, and + to add one. View › Show/Hide Factory Rail (⌘⇧S).
struct FactoryRail: View {
    @Environment(AppState.self) private var state
    @Environment(FactoryClient.self) private var client

    var body: some View {
        VStack(spacing: 10) {
            ForEach(Array(client.savedFactories.enumerated()), id: \.element.id) { index, factory in
                tile(factory, number: index + 1)
            }
            addTile
            Spacer(minLength: 0)
        }
        .padding(.top, 44)
        .frame(width: 60)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.black.opacity(0.035))
        .overlay(alignment: .trailing) { Hairline(vertical: true) }
    }

    private func isCurrent(_ factory: SavedFactory) -> Bool {
        client.isSignedIn && client.server.map(SavedFactory.key) == factory.id
    }

    private func tile(_ factory: SavedFactory, number: Int) -> some View {
        let current = isCurrent(factory)
        return FactoryRailTile(current: current) {
            FactoryIcon(name: factory.name,
                        image: current ? client.icon : factory.icon.flatMap(FactoryIcons.image),
                        size: 32)
        }
        .railTooltip(factory.name, detail: number <= 9 ? "\(factory.host) · ⌘\(number)" : factory.host)
        .onTapGesture { state.switchToFactory(at: number) }
        .contextMenu {
            if current {
                Button("Sign out of \(factory.name)") { state.signOut() }
            } else {
                Button("Switch to \(factory.name)") { state.switchToFactory(at: number) }
            }
        }
    }

    private var addTile: some View {
        FactoryRailTile(current: false) {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 32 * 0.27).fill(Theme.fillSelected))
        }
        .railTooltip("Add a factory")
        .onTapGesture { state.startOnboarding() }
    }
}

/// One rail tile: a 2pt ring round the current factory; the others dim a little until hovered.
private struct FactoryRailTile<Content: View>: View {
    let current: Bool
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        content
            .opacity(current || hovering ? 1 : 0.62)
            .padding(3)
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(current ? Theme.text : hovering ? Theme.stroke : .clear, lineWidth: 2)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

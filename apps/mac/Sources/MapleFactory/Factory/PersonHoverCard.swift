import SwiftUI

/// A person's own status: an emoji and a short sentence, optionally until a time. Nothing sets one
/// from the server yet; `kind` leaves room for snoozed notifications and out-of-office later.
struct PersonStatus: Equatable {
    enum Kind: Equatable { case custom, snoozed, outOfOffice }

    var emoji: String
    var text: String
    var until: Date? = nil
    var kind: Kind = .custom
}

/// The card that opens when hovering a person in the sidebar: who they are, where they are, and
/// their status when they've set one.
struct PersonHoverCard: View {
    let person: Person
    let presence: String
    let online: Bool
    let mobile: Bool
    let status: PersonStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AgentAvatar(agent: person, size: 40, online: online, mobile: mobile, shape: .roundedSquare)
                VStack(alignment: .leading, spacing: 2) {
                    Text(person.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    if let login = person.github {
                        Text("@\(login)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textMuted)
                    }
                }
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(online ? Theme.State.merged : Theme.textFaint)
                    .frame(width: 7, height: 7)
                Text(presence)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text.opacity(0.85))
            }
            if let status {
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(status.emoji).font(.system(size: 14))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(status.text)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                        if let until = FactorySidebar.untilLine(status) {
                            Text(until)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textMuted)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 230, alignment: .leading)
    }
}

extension View {
    /// Opens a `PersonHoverCard` beside the view after a short hover, and closes it when the mouse leaves.
    func personHoverCard(_ person: Person, presence: String, online: Bool, mobile: Bool,
                         status: PersonStatus?) -> some View {
        modifier(PersonHoverCardModifier(person: person, presence: presence, online: online,
                                         mobile: mobile, status: status))
    }
}

enum PersonHover {
    /// A demo script's `hoverperson:<first name>` (or `none`) opens or closes a row's card.
    static let demoHover = Notification.Name("PersonHover.demoHover")
}

private struct PersonHoverCardModifier: ViewModifier {
    let person: Person
    let presence: String
    let online: Bool
    let mobile: Bool
    let status: PersonStatus?
    @State private var hovering = false
    @State private var shown = false
    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            .onHover { inside in
                hovering = inside
                if inside {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(450))
                        if hovering { shown = true }
                    }
                } else {
                    shown = false
                }
            }
            .popover(isPresented: $shown, arrowEdge: .trailing) {
                PersonHoverCard(person: person, presence: presence, online: online, mobile: mobile, status: status)
            }
            .onReceive(NotificationCenter.default.publisher(for: PersonHover.demoHover)) { note in
                shown = (note.userInfo?["name"] as? String)?.lowercased() == person.firstName.lowercased()
            }
            .onChange(of: shown) { _, open in
                guard Headless.isOn else { return }
                if open { Headless.popoverAnchor = frame } else if Headless.popoverAnchor == frame { Headless.popoverAnchor = nil }
            }
    }
}

import MapleKit
import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }

    /// A color that resolves per appearance.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(Color(hex: dark)) : UIColor(Color(hex: light)) })
    }

    /// A goal's "#RRGGBB".
    init(goalHex: String) {
        self.init(hex: UInt32(goalHex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x8A909A)
    }
}

/// The Mac app's palette, for the phone.
enum Theme {
    static let accent = Color(light: 0xD24E26, dark: 0xFF7A48)
    static let approve = Color(light: 0x1F883D, dark: 0x2EA043)
    static let warning = Color(light: 0xB7791F, dark: 0xE2A93B)
    static let mention = Color(light: 0xD9488F, dark: 0xF07AB4)
    static let danger = Color(light: 0xC8474B, dark: 0xD9696C)

    static func state(_ state: Wire.TaskState) -> Color {
        switch state {
        case .drafting: Color(light: 0x8A909A, dark: 0x8B919B)
        case .planning: Color(light: 0x7C5CE0, dark: 0xA48BFA)
        case .awaitingApproval: Color(light: 0xC27C0E, dark: 0xE9B04A)
        case .backlog: Color(light: 0x5B6B86, dark: 0x93A3BF)
        case .building: Color(light: 0x2F6FEB, dark: 0x6B9BF5)
        case .reviewing: Color(light: 0x0E8FA3, dark: 0x4CC4D6)
        case .merged: Color(light: 0x14A866, dark: 0x3DD68C)
        // Finished with nothing to merge: a neutral gray, darker than Drafting's.
        case .closed: Color(light: 0x6B7079, dark: 0xA4AAB4)
        case .cancelled, .other: Color(light: 0xC8474B, dark: 0xD9696C)
        }
    }
}

extension Wire.TaskState {
    var title: String {
        switch self {
        case .drafting: "Drafting"
        case .planning: "Planning"
        case .awaitingApproval: "Awaiting approval"
        case .backlog: "Backlog"
        case .building: "Building"
        case .reviewing: "Reviewing"
        case .merged: "Merged"
        case .cancelled: "Cancelled"
        case .closed: "Closed"
        case .other(let value): value
        }
    }

    var icon: String {
        switch self {
        case .drafting: "pencil"
        case .planning: "sparkles"
        case .awaitingApproval: "hand.raised"
        case .backlog: "tray"
        case .building: "hammer"
        case .reviewing: "eye"
        case .merged: "checkmark.circle"
        case .closed: "circle.badge.checkmark"
        case .cancelled, .other: "xmark.circle"
        }
    }
}

extension InboxEntry.Kind {
    var icon: String {
        switch self {
        case .approval: "hand.raised.fill"
        case .hand: "exclamationmark.triangle.fill"
        case .question: "questionmark.bubble.fill"
        case .review: "eye.fill"
        case .failing: "xmark.octagon.fill"
        case .mention: "at"
        }
    }

    var color: Color {
        switch self {
        case .approval: Theme.state(.awaitingApproval)
        case .hand: Theme.warning
        case .question: Theme.state(.planning)
        case .review: Theme.state(.reviewing)
        case .failing: Theme.danger
        case .mention: Theme.mention
        }
    }
}

/// A task's state as a small colored pill.
struct StatePill: View {
    let state: Wire.TaskState

    var body: some View {
        Label(state.title, systemImage: state.icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(Theme.state(state))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Theme.state(state).opacity(0.14)))
    }
}

/// A member's GitHub avatar, or their initial.
struct Avatar: View {
    @Environment(FactoryStore.self) private var store
    let login: String
    var url: String? = nil
    var size: CGFloat = 22

    var body: some View {
        Group {
            if let link = (url ?? store.feed.member(login)?.avatarUrl).flatMap(URL.init(string:)) {
                AsyncImage(url: link) { $0.resizable().scaledToFill() } placeholder: { initial }
            } else {
                initial
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var initial: some View {
        Text(login.prefix(1).uppercased())
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.accent.gradient)
    }
}

enum When {
    /// "now", "5m", "3h", "2d" since `ms`.
    static func ago(_ ms: UInt64, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince1970 - Double(ms) / 1000)
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86400: return "\(Int(seconds / 3600))h"
        default: return "\(Int(seconds / 86400))d"
        }
    }
}

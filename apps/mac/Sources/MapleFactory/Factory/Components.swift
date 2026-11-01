import SwiftUI

struct AgentAvatar: View {
    let agent: Agent
    var size: CGFloat = 20
    var online = false
    /// Online only on a phone: a small phone badge stands in for the green dot.
    var mobile = false

    /// People show initials (or their GitHub picture over them); bots show a robot in their role's color.
    enum Face: Equatable { case initials, robot }
    static func face(for agent: Agent) -> Face { agent.isHuman ? .initials : .robot }

    var body: some View {
        ZStack {
            Circle().fill(agent.color.opacity(agent.isHuman ? 1 : 0.24))
            if Self.face(for: agent) == .initials {
                Text(agent.initials)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
                if let url = agent.avatarURL {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.clear
                    }
                    .clipShape(Circle())
                }
            } else {
                RobotFace(color: agent.color, size: size, online: online)
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if online && mobile {
                let height = max(size * 0.5, 9)
                Image(systemName: "iphone")
                    .font(.system(size: height * 0.68, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: height * 0.78, height: height)
                    .background(Capsule().fill(Theme.State.merged))
                    .overlay(Capsule().stroke(Theme.editorBG, lineWidth: 1.5))
                    .offset(x: 2, y: 2)
                    .accessibilityLabel("On mobile")
            } else if online {
                Circle()
                    .fill(Theme.State.merged)
                    .frame(width: max(size * 0.32, 6), height: max(size * 0.32, 6))
                    .overlay(Circle().stroke(Theme.editorBG, lineWidth: 1.5))
                    .offset(x: 1, y: 1)
            }
        }
        .help(agent.name)
    }
}

/// Owner in front, executing agent tucked behind — who's accountable and who's doing the work.
struct AvatarPair: View {
    let owner: Person
    let agent: Agent?
    var size: CGFloat = 18

    var body: some View {
        HStack(spacing: -size * 0.3) {
            if let agent {
                AgentAvatar(agent: agent, size: size)
                    .background(Circle().fill(Theme.cardBG).padding(-1.5))
            }
            AgentAvatar(agent: owner, size: size)
                .background(Circle().fill(Theme.cardBG).padding(-1.5))
        }
    }
}

struct Facepile: View {
    let people: [Person]
    var size: CGFloat = 24
    var ringColor = Theme.editorBG

    var body: some View {
        HStack(spacing: -size * 0.28) {
            ForEach(people) { person in
                AgentAvatar(agent: person, size: size)
                    .overlay(Circle().stroke(ringColor, lineWidth: 2))
            }
        }
    }
}

/// A Figma-style name tag in the teammate's color, for tasks someone else has open.
struct PresenceTag: View {
    let person: Person
    /// Looking from a phone: a tiny phone glyph after the name. The person's own flag by default.
    var mobile: Bool?

    var body: some View {
        let mobile = mobile ?? person.mobile
        HStack(spacing: 4) {
            AgentAvatar(agent: person, size: 13)
            Text(person.firstName)
                .font(.system(size: 10.5, weight: .semibold))
            if mobile {
                Image(systemName: "iphone")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.leading, -1)
                    .accessibilityLabel("on mobile")
            }
        }
        .foregroundStyle(.white)
        .padding(.leading, 2)
        .padding(.trailing, 7)
        .frame(height: 18)
        .background(Capsule().fill(person.color))
        .help(mobile ? "\(person.firstName) is looking on mobile" : person.name)
    }
}

struct ProgressRing: View {
    let progress: Double
    let color: Color
    var size: CGFloat = 14

    var body: some View {
        ZStack {
            // Tinted, so a goal with nothing merged yet still shows its color.
            Circle().stroke(color.opacity(0.4), lineWidth: 2)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}

struct StateBadge: View {
    let state: TaskState

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: state.icon).font(.system(size: 10, weight: .semibold))
            Text(state.title).font(.system(size: 11.5, weight: .medium))
        }
        .foregroundStyle(state.color)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(state.color.opacity(0.13)))
    }
}

struct NeedsYouBadge: View {
    var body: some View {
        Text("Needs you")
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Theme.State.awaitingApproval)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(Capsule().fill(Theme.State.awaitingApproval.opacity(0.14)))
    }
}

struct NeedsHandBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "hand.raised.fill").font(.system(size: 8.5))
            Text("Needs a hand")
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(Theme.State.cancelled)
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(Capsule().fill(Theme.State.cancelled.opacity(0.13)))
    }
}

struct Hairline: View {
    var vertical = false

    var body: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

struct AppearanceButton: View {
    @AppStorage("appearance") private var appearance = Appearance.system

    var body: some View {
        Image(systemName: appearance.icon)
            .font(.system(size: 13))
            .foregroundStyle(Theme.textMuted)
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
            .onTapGesture { appearance = appearance.next }
            .help("Appearance: \(appearance.rawValue.capitalized)")
    }
}

struct SectionLabel: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Theme.textMuted)
    }
}

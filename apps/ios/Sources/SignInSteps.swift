import SwiftUI

// The pieces of the iPhone's sign-in flow (SignInView.swift). Named and worded like the Mac's
// OnboardingView so both apps say the same things.

/// 1 Connect · 2 Sign in · 3 Ready: where you are in joining a factory.
struct StepDots: View {
    /// 0 Connect, 1 Sign in, 2 Ready.
    let current: Int
    private let titles = ["Connect", "Sign in", "Ready"]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(titles.enumerated()), id: \.offset) { offset, title in
                HStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(offset <= current ? Theme.accent : Color(.tertiarySystemFill))
                            .frame(width: 20, height: 20)
                        if offset < current {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        } else {
                            Text("\(offset + 1)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(offset == current ? .white : .secondary)
                        }
                    }
                    Text(title)
                        .font(.footnote.weight(offset == current ? .semibold : .regular))
                        .foregroundStyle(offset <= current ? .primary : .secondary)
                        .lineLimit(1)
                }
                if offset < titles.count - 1 {
                    Capsule()
                        .fill(offset < current ? Theme.accent.opacity(0.5) : Color(.separator))
                        .frame(width: 18, height: 2)
                }
            }
        }
        // Three steps fit across a phone up to the first accessibility size; past it, they'd crowd out.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current + 1) of 3: \(titles[current])")
        .accessibilityIdentifier("signin-steps")
    }
}

/// One connection check: a spinner while it runs, a green tick when it passed, a red cross with the
/// reason under it when it failed.
struct CheckRow: View {
    struct Check: Identifiable, Equatable {
        enum State: Equatable { case running, done, failed(String) }
        /// Short and stable, for the accessibility identifier (signin-check-<key>).
        let key: String
        let text: String
        var detail: String? = nil
        var state: State = .running
        var id: String { key }
    }

    let check: Check
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(spacing: 8))
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            icon.frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                layout {
                    Text(check.text)
                        .foregroundStyle(check.state == .running ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
                    if let detail = check.detail, check.state != .running {
                        Text(detail)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                if case .failed(let reason) = check.state {
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("signin-check-error")
                }
            }
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("signin-check-\(check.key)")
    }

    @ViewBuilder private var icon: some View {
        switch check.state {
        case .running: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.approve)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.danger)
        }
    }
}

/// One thing GitHub shares with the factory when you sign in.
struct PermissionRow: View {
    let icon: String
    let text: String

    init(_ icon: String, _ text: String) {
        self.icon = icon
        self.text = text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}

/// The factory you're joining: its mark, org and host, with a green Connected tick.
struct FactoryHeader: View {
    let org: String
    let host: String

    var body: some View {
        HStack(spacing: 12) {
            Image("Mark")
                .resizable()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(org).font(.headline)
                Text(host).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Label("Connected", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.approve)
                .labelStyle(CompactLabel())
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemBackground)))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("signin-factory")
    }
}

/// Icon then title with a tight gap; at accessibility sizes just the icon, so the org keeps its room.
private struct CompactLabel: LabelStyle {
    @Environment(\.dynamicTypeSize) private var typeSize

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            if !typeSize.isAccessibilitySize { configuration.title }
        }
    }
}

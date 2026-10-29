import SwiftUI

/// Signed in, before the factory's first snapshot: what's happening in place of the mock's goal, with
/// a way out when the factory never answers.
struct FactoryLoadingView: View {
    @Environment(AppState.self) private var state
    @Environment(FactoryClient.self) private var client

    private var host: String { client.server?.host() ?? "factory" }

    /// Why it's taking a while, when the client knows.
    private var detail: String? {
        switch client.status {
        case .reconnecting(let attempt, let reason): "Reconnecting (attempt \(attempt)): \(reason)"
        case .tooNew: FactoryClient.tooNewMessage
        default: nil
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            MapleMark(size: 48)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Connecting to \(host)…")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
            }
            if let detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .transition(.opacity)
            }
            HStack(spacing: 8) {
                SecondaryButton(title: "Sign Out") { state.signOut() }
                SecondaryButton(title: "Connect to Another Factory…") { state.startOnboarding() }
            }
            .fixedSize()
            .padding(.top, 6)
        }
        .animation(.easeInOut(duration: 0.2), value: detail)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.editorBG)
    }
}

/// Placeholder rows for the sidebar's goals while the first snapshot is on its way.
struct GoalsSkeleton: View {
    private let widths: [CGFloat] = [120, 92, 140]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(widths.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    Circle().fill(Theme.fill).frame(width: 8, height: 8)
                    RoundedRectangle(cornerRadius: 3).fill(Theme.fill).frame(width: widths[index], height: 9)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityLabel("Loading goals")
    }
}

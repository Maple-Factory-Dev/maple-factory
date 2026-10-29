import SwiftUI

/// An update on offer, at the top of the window until it's answered: one Update & Restart that
/// downloads, installs and relaunches, with its progress shown in place of the button. The × puts
/// this version away; the sidebar footer still offers it.
struct UpdateToastView: View {
    private var updater = Updater.shared

    var body: some View {
        let phase = updater.phase
        HStack(spacing: 11) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(UpdatePhase.updateToastTitle(version: updater.offeredVersion ?? ""))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if let url = updater.releaseNotesURL {
                    Text("\(UpdatePhase.releaseNotesLinkLabel) ↗")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .contentShape(Rectangle())
                        .onTapGesture { NSWorkspace.shared.open(url) }
                        .pointerStyle(.link)
                        .help("See the release notes")
                }
            }
            .fixedSize()
            Spacer(minLength: 8)
            if offersButton(phase) {
                Text(UpdatePhase.updateToastButtonLabel)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .background(Capsule().fill(Theme.accent))
                    .contentShape(Capsule())
                    .onTapGesture { updater.updateAndRestart() }
                    .transition(.opacity)
            } else {
                progress(phase)
                    .transition(.opacity)
            }
            Image(systemName: "xmark")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeOut(duration: 0.25)) { updater.dismissToast() } }
                .help("Not now")
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        // 440 at least, wider once the progress (which outgrows the button) takes its place.
        .frame(minWidth: 440)
        .frame(height: 50)
        .fixedSize(horizontal: true, vertical: false)
        .background(
            Capsule()
                .fill(Theme.cardBG)
                .overlay(Capsule().strokeBorder(Theme.stroke))
                .shadow(color: .black.opacity(0.2), radius: 14, y: 6)
        )
        .animation(.snappy(duration: 0.2), value: offersButton(phase))
    }

    /// The button until it's been clicked (an update already downloaded still asks once).
    private func offersButton(_ phase: UpdatePhase) -> Bool {
        switch phase {
        case .available: true
        case .readyToRelaunch: !updater.relaunchWhenReady
        default: false
        }
    }

    private func progress(_ phase: UpdatePhase) -> some View {
        HStack(spacing: 8) {
            // Kept in place once it's done (Restarting…), so the toast holds its width to the end.
            Group {
                if let fraction = phase.progress { ProgressView(value: fraction) } else { ProgressView() }
            }
            .progressViewStyle(.linear)
            .controlSize(.mini)
            .tint(Theme.accent)
            .frame(width: 70)
            .opacity(phase.isBusy ? 1 : 0)
            Text(phase.updateToastProgressLabel ?? "")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
                .frame(minWidth: 96, alignment: .leading)
        }
        .fixedSize()
    }
}

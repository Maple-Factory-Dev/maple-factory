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
                if updater.releaseNotesURL != nil {
                    Text(UpdatePhase.releaseNotesLinkLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .contentShape(Rectangle())
                        .onTapGesture { updater.openReleaseNotes() }
                        .pointerStyle(.link)
                        .help("Read the release notes")
                }
            }
            .fixedSize()
            Spacer(minLength: 8)
            // Both are always laid out, so the slot is as wide as the button and the toast keeps
            // one width from the offer through the download to Restarting….
            ZStack(alignment: .leading) {
                Text(UpdatePhase.updateToastButtonLabel)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .background(Capsule().fill(Theme.accent))
                    .contentShape(Capsule())
                    .onTapGesture { updater.updateAndRestart() }
                    .opacity(offersButton(phase) ? 1 : 0)
                    .allowsHitTesting(offersButton(phase))
                progress(phase)
                    .opacity(offersButton(phase) ? 0 : 1)
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
        // 440 at least. The progress fits in the button's slot, so the toast keeps one width.
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
        HStack(spacing: 6) {
            // Kept in place once it's done (Restarting…), so the slot holds its layout to the end.
            UpdateRing(fraction: phase.progress)
                .padding(1)
                .opacity(phase.isBusy ? 1 : 0)
            Text(phase.updateToastProgressLabel ?? "")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
        }
        .fixedSize()
    }
}

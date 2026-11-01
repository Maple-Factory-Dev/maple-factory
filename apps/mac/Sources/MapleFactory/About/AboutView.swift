import AppKit
import SwiftUI

/// Maple Factory › About Maple Factory: the app on glass at the left (icon, version, the website and an
/// update check), and a note from Andrea at the right, signed with the afomera.dev mountain.
struct AboutView: View {
    static let windowID = "about"
    static let size = CGSize(width: 560, height: 340)
    static let website = URL(string: "https://maplefactory.dev")!

    /// The note, in one place so it's easy to reword.
    static let message = """
    Thanks for trying Maple Factory. I built it because I wanted a place where agents do the building \
    and people stay in charge: you write the brief, approve the plan, and review what comes back.

    It's early, and it gets better every week. If something feels off or you have an idea, \
    I'd love to hear it.
    """

    @Bindable private var updater = Updater.shared

    var body: some View {
        HStack(spacing: 0) {
            appColumn
                .frame(width: 200)
                .frame(maxHeight: .infinity)
                .background(VisualEffect(material: .sidebar))
            Divider()
            note
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Theme.editorBG)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .ignoresSafeArea()
    }

    // MARK: The app

    private var appColumn: some View {
        VStack(spacing: 0) {
            MapleMark(size: 72)
                .padding(.top, 44)
            Text("Maple Factory")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.text)
                .padding(.top, 14)
            Text(Self.versionLine(Bundle.main))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .textSelection(.enabled)
                .padding(.top, 3)
            Link("maplefactory.dev", destination: Self.website)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.accent)
                .padding(.top, 10)
            Spacer(minLength: 12)
            updateCheck
                .padding(.bottom, 22)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder private var updateCheck: some View {
        VStack(spacing: 6) {
            Button("Check for Updates…") { Self.checkForUpdates() }
            .controlSize(.regular)
            .disabled((updater.available || updater.isDemo) && !updater.canCheckNow)

            Group {
                if updater.phase == .checking {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("Checking…")
                    }
                } else if updater.available || updater.isDemo {
                    Text(updater.status)
                } else {
                    Text("Opens maplefactory.dev")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.textMuted)
            .frame(height: 14)
        }
    }

    // MARK: The note

    private var note: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("A note from me")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
                .textCase(.uppercase)
                .tracking(0.6)
            Text(Self.message)
                .font(.system(size: 13))
                .lineSpacing(3)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
            Spacer(minLength: 16)
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text("Andrea")
                    .font(.system(size: 20, weight: .medium, design: .serif))
                    .italic()
                    .foregroundStyle(Theme.text)
                if let mark = Self.mountain {
                    Image(nsImage: mark)
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 24)
                        .foregroundStyle(.primary)
                        .accessibilityLabel("afomera.dev")
                }
            }
            Text("© \(String(Self.year)) Andrea Fomera")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textFaint)
                .padding(.top, 10)
        }
        .padding(.horizontal, 28)
        .padding(.top, 40)
        .padding(.bottom, 22)
    }

    // MARK: Helpers

    /// The button: a check, or the website for a build that doesn't update itself (as Machines does).
    /// `-actions about:check` presses it headless.
    @MainActor static func checkForUpdates() {
        let updater = Updater.shared
        if updater.available || updater.isDemo {
            updater.checkForUpdates()
        } else {
            NSWorkspace.shared.open(website)
        }
    }

    /// "Version 0.2.24 (build 57)", or "Version dev" under `swift run`, which has no bundle version.
    static func versionLine(_ bundle: Bundle) -> String {
        versionLine(
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }

    static func versionLine(version: String?, build: String?) -> String {
        guard let version, !version.isEmpty else { return "Version dev" }
        guard let build, !build.isEmpty, build != version else { return "Version \(version)" }
        return "Version \(version) (build \(build))"
    }

    /// The afomera.dev mountain, as a template so it takes the text colour in light and dark.
    @MainActor static let mountain: NSImage? = {
        guard let url = Bundle.module.url(forResource: "afomera-mountain", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        return image
    }()

    private static var year: Int { Calendar.current.component(.year, from: .now) }
}

/// Maple Factory › About Maple Factory, opening the window above (a Commands builder can't read openWindow itself).
struct AboutMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About Maple Factory") { openWindow(id: AboutView.windowID) }
    }
}

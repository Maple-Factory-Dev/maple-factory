import SwiftUI
import MapleKit

// MF-358: the planner's Mermaid diagrams. Each renders in the shared viewer page (Resources/mermaid,
// synced from assets/mermaid by scripts/sync-mermaid.mjs) with mermaid inlined, inside the no-network
// SandboxedPage: a fitted card inline, and Open shows it large through the proof lightbox, where it pans,
// zooms and searches (⌘F, Enter / ↑↓ through the matches).

enum DiagramPage {
    enum Mode: String { case inline, viewer }

    /// The bundled page and mermaid, read once.
    @MainActor private static var bundled: (page: String, mermaid: String)?

    @MainActor private static func load() -> (page: String, mermaid: String)? {
        if let bundled { return bundled }
        guard let page = Bundle.module.url(forResource: "diagram", withExtension: "html").flatMap({ try? String(contentsOf: $0, encoding: .utf8) }),
              let mermaid = Bundle.module.url(forResource: "mermaid.min", withExtension: "js").flatMap({ try? String(contentsOf: $0, encoding: .utf8) })
        else { return nil }
        bundled = (page, mermaid)
        return bundled
    }

    /// The viewer page for `source`, self-contained (SandboxedPage loads it with no base URL and no network).
    @MainActor static func html(source: String, mode: Mode, dark: Bool, query: String? = nil) -> String {
        guard let (page, mermaid) = load() else {
            return "<p style=\"font:13px -apple-system;color:#c92a2a\">The diagram viewer is missing from this build.</p><pre>\(escape(source))</pre>"
        }
        var input: [String: String] = ["source": source, "mode": mode.rawValue, "theme": dark ? "dark" : "light"]
        if let query { input["query"] = query }
        let json = (try? JSONSerialization.data(withJSONObject: input)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        // `</` can't end the inline script early, and the bundled mermaid has no "</script".
        let safe = json.replacingOccurrences(of: "</", with: "<\\/")
        let inlined = "<script>window.MAPLE_DIAGRAM = \(safe);</script>\n<script>\(mermaid)</script>"
        return page.replacingOccurrences(of: "<script src=\"mermaid.min.js\"></script>", with: inlined)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

struct DiagramsSection: View {
    /// A demo script's `diagram:open`: the first diagram on screen opens large (with `-diagramquery` searched).
    static let demoOpen = Notification.Name("DiagramsSection.demoOpen")

    @Environment(AppState.self) private var state
    @Environment(\.colorScheme) private var scheme
    let task: FactoryTask

    var body: some View {
        TaskSection(title: "Diagrams") {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(task.diagrams, id: \.id) { diagram in card(diagram) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.demoOpen)) { _ in
            if let first = task.diagrams.first { open(first, query: AppDefaults.string(forKey: "diagramquery")) }
        }
    }

    private func card(_ diagram: Wire.Diagram) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(.secondary)
                Text(diagram.title).font(.system(size: 13, weight: .semibold))
                Text(diagram.id).font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                Button("Open") { open(diagram) }
                    .controlSize(.small)
                    .help("Open large: zoom, pan and search (⌘F)")
            }
            SandboxedPage(html: DiagramPage.html(source: diagram.source, mode: .inline, dark: scheme == .dark))
                .frame(height: 280)
                .allowsHitTesting(false)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                .contentShape(Rectangle())
                .onTapGesture { open(diagram) }
            if !diagram.notes.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(diagram.notes.enumerated()), id: \.offset) { i, note in
                        Text("\(i + 1). \(note)").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func open(_ diagram: Wire.Diagram, query: String? = nil) {
        state.showLightbox(.diagram(html: DiagramPage.html(source: diagram.source, mode: .viewer, dark: scheme == .dark, query: query), caption: diagram.title))
    }
}

/// A diagram shown large: the viewer page fills the room; Esc and the backdrop close it, as for a page.
struct DiagramViewerView: View {
    let html: String
    let caption: String
    @Environment(AppState.self) private var state

    var body: some View {
        ZStack {
            Color.black.opacity(0.75)
                .contentShape(Rectangle())
                .onTapGesture { state.closeLightbox() }
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                    Text(caption).lineLimit(1)
                    Text("Scroll or pinch to zoom · drag to pan · ⌘F to search").foregroundStyle(.white.opacity(0.55))
                    Spacer(minLength: 16)
                    Button { state.closeLightbox() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(.white.opacity(0.16)))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help("Close (Esc)")
                }
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.85))
                SandboxedPage(html: html)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
            }
            .padding(32)
        }
    }
}

extension FactoryData {
    /// The demo factory's diagrams, for screenshots and UI tests.
    static let seedDiagrams: [String: [Wire.Diagram]] = [
        "ATL-152": [
            Wire.Diagram(id: "D1", title: "Login attempt with rate limits", source: """
            flowchart LR
              req[POST /login] --> ip{IP over limit?}
              ip -- yes --> block[429: try again later]
              ip -- no --> acct{Account over limit?}
              acct -- yes --> lock[Locked out: email unlock link]
              acct -- no --> check[Check password]
              check -- wrong --> count[Count the attempt against both limits]
              count --> req
              check -- right --> ok[Signed in: reset the limits]
            """, notes: ["Both limits are checked before the password, so a locked account costs no hash.", "A right password resets both counters."]),
        ],
    ]
}

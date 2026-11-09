import SwiftUI
import MapleKit
import WebKit

// MF-358: the planner's Mermaid diagrams. Each renders in the shared viewer page (Resources/mermaid, synced
// from assets/mermaid by scripts/sync-mermaid.mjs), mermaid inlined, in a WKWebView whose content rule list
// blocks every load: a fitted card in the task, and a full-screen viewer that pinches, pans and searches.

enum DiagramPage {
    enum Mode: String { case inline, viewer }

    @MainActor private static var bundled: (page: String, mermaid: String)?

    @MainActor private static func load() -> (page: String, mermaid: String)? {
        if let bundled { return bundled }
        guard let page = Bundle.main.url(forResource: "diagram", withExtension: "html").flatMap({ try? String(contentsOf: $0, encoding: .utf8) }),
              let mermaid = Bundle.main.url(forResource: "mermaid.min", withExtension: "js").flatMap({ try? String(contentsOf: $0, encoding: .utf8) })
        else { return nil }
        bundled = (page, mermaid)
        return bundled
    }

    /// The viewer page for `source`, self-contained: it loads with no base URL and every request blocked.
    @MainActor static func html(source: String, mode: Mode, dark: Bool) -> String {
        guard let (page, mermaid) = load() else {
            return "<p style=\"font:15px -apple-system;color:#c92a2a\">The diagram viewer is missing from this build.</p><pre>\(source.replacingOccurrences(of: "<", with: "&lt;"))</pre>"
        }
        let input = ["source": source, "mode": mode.rawValue, "theme": dark ? "dark" : "light"]
        let json = (try? JSONSerialization.data(withJSONObject: input)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let inlined = "<script>window.MAPLE_DIAGRAM = \(json.replacingOccurrences(of: "</", with: "<\\/"));</script>\n<script>\(mermaid)</script>"
        return page.replacingOccurrences(of: "<script src=\"mermaid.min.js\"></script>", with: inlined)
    }
}

/// The viewer page in a web view that can't reach the network; `interactive` lets touches through (the viewer).
struct DiagramWebView: UIViewRepresentable {
    let html: String
    var interactive = false

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.dataDetectorTypes = []
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.allowsLinkPreview = false
        // The page pans and zooms itself: the web view's own scrolling would take the gestures.
        view.scrollView.isScrollEnabled = false
        view.scrollView.pinchGestureRecognizer?.isEnabled = false
        view.isUserInteractionEnabled = interactive
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html
        let page = html
        Task { @MainActor in
            guard let rules = await SandboxedArtifactPage.blockEverything() else {
                view.loadHTMLString("<p style=\"font:15px -apple-system;color:#888\">Couldn't sandbox this diagram.</p>", baseURL: nil)
                return
            }
            view.configuration.userContentController.removeAllContentRuleLists()
            view.configuration.userContentController.add(rules)
            view.loadHTMLString(page, baseURL: nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: String?
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            action.request.url?.absoluteString == "about:blank" ? .allow : .cancel
        }
    }
}

/// A diagram in the task: fitted, with its notes; tapping it opens the full-screen viewer.
struct DiagramCard: View {
    let diagram: Wire.Diagram
    @Environment(\.colorScheme) private var scheme
    @State private var open = false

    var body: some View {
        DiagramWebView(html: DiagramPage.html(source: diagram.source, mode: .inline, dark: scheme == .dark))
            .frame(height: 240)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
            .contentShape(Rectangle())
            .onTapGesture { open = true }
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Open diagram \(diagram.title)")
            .accessibilityIdentifier("diagram.card.\(diagram.id)")
        ForEach(Array(diagram.notes.enumerated()), id: \.offset) { _, note in Text("• \(note)").font(.caption).foregroundStyle(.secondary) }
        Button { open = true } label: { Label("Open", systemImage: "arrow.up.left.and.arrow.down.right") }
            .font(.callout)
            .accessibilityIdentifier("diagram.open.\(diagram.id)")
            .fullScreenCover(isPresented: $open) { DiagramViewer(diagram: diagram) }
    }
}

/// Full screen: pinch to zoom, drag to pan, and the page's search field steps through the matches.
struct DiagramViewer: View {
    let diagram: Wire.Diagram
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationStack {
            DiagramWebView(html: DiagramPage.html(source: diagram.source, mode: .viewer, dark: scheme == .dark), interactive: true)
                .ignoresSafeArea(edges: .bottom)
                .accessibilityIdentifier("diagram.viewer.\(diagram.id)")
                .navigationTitle(diagram.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.accessibilityIdentifier("diagram.close")
                    }
                }
        }
    }
}

import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// Task artifacts (MF-205): files an agent shared with `share_artifact` (a chart, a repro page, an
// image, a PDF…), uploaded by the runner and kept as attachments. Picked from chips above one viewer.
// An HTML or SVG artifact runs its scripts, but in a web view with nothing to reach: no persistent
// store, every network load blocked by a content rule, a CSP that allows only inline code, and no origin.

typealias TaskArtifact = Wire.Artifact

extension Wire.Artifact: Identifiable {}

extension Wire.ArtifactKind {
    var icon: String {
        switch self {
        case .html: "chart.bar.doc.horizontal"
        case .image: "photo"
        case .svg: "scribble.variable"
        case .pdf: "doc.richtext"
        case .markdown: "text.document"
        case .text: "doc.plaintext"
        case .data: "tablecells"
        case .other: "doc"
        }
    }

    /// Run in the sandboxed web view rather than shown as an image or text.
    var isPage: Bool { self == .html || self == .svg }
}

struct ArtifactsSection: View {
    let task: FactoryTask
    @State private var selected: String?

    init(task: FactoryTask) {
        self.task = task
        // `-artifact <title>` opens on that one, for screenshots.
        let wanted = AppDefaults.string(forKey: "artifact")?.lowercased()
        _selected = State(initialValue: task.artifacts.first { $0.title.lowercased() == wanted }?.id)
    }

    private var artifact: TaskArtifact? {
        task.artifacts.first { $0.id == selected } ?? task.artifacts.last
    }

    var body: some View {
        if let artifact {
            TaskSection(title: "Artifacts") {
                VStack(alignment: .leading, spacing: 10) {
                    picker(active: artifact)
                    ArtifactViewer(artifact: artifact).id(artifact.id)
                }
            }
        }
    }

    private func picker(active: TaskArtifact) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(task.artifacts) { item in
                let on = item.id == active.id
                HStack(spacing: 5) {
                    Image(systemName: item.kind.icon).font(.system(size: 10.5))
                    Text(item.title).lineLimit(1)
                    if item.version > 1 {
                        Text("v\(item.version)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.textMuted)
                    }
                }
                .font(.system(size: 12, weight: on ? .medium : .regular))
                .foregroundStyle(on ? Theme.text : Theme.textMuted)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(on ? Theme.cardBG : .clear)
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(on ? Theme.stroke : Theme.stroke.opacity(0.5)))
                )
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.snappy(duration: 0.2)) { selected = item.id } }
                .help(item.summary ?? item.title)
            }
        }
    }
}

/// One artifact: fetched with the app's token, then drawn by kind, with its caption and actions under it.
private struct ArtifactViewer: View {
    let artifact: TaskArtifact
    @Environment(FactoryClient.self) private var client: FactoryClient?
    @Environment(AppState.self) private var state
    @State private var data: Data?
    @State private var failed: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let data {
                    content(data)
                } else {
                    HStack(spacing: 8) {
                        if failed == nil { ProgressView().controlSize(.small) }
                        Text(failed ?? "Loading…").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                    }
                    .frame(maxWidth: .infinity, minHeight: 120)
                }
            }
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.cardBG))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.stroke))
            footer
        }
        .task(id: artifact.file) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: PageViewerView.demoOpen)) { _ in
            if state.lightbox == nil, artifact.kind.isPage { openLarge() }
        }
    }

    @ViewBuilder private func content(_ data: Data) -> some View {
        switch artifact.kind {
        case .html, .svg:
            SandboxedPage(html: ArtifactFiles.page(data, kind: artifact.kind))
                .frame(height: 420)
                .overlay(alignment: .topTrailing) { ExpandPageButton(action: openLarge) }
        case .image:
            if let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: min(image.size.width, .infinity), maxHeight: 460)
                    .frame(maxWidth: .infinity)
                    .padding(8)
            } else {
                unreadable
            }
        case .pdf:
            PDFArtifact(data: data).frame(height: 480)
        case .markdown:
            ScrollView {
                MarkdownPreview(source: String(decoding: data, as: UTF8.self), baseSize: 13)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 420)
        case .text, .data, .other:
            ScrollView([.vertical, .horizontal]) {
                Text(String(decoding: data.prefix(512 * 1024), as: UTF8.self))
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 360)
        }
    }

    private var unreadable: some View {
        Text("This file couldn't be shown.").font(.system(size: 12)).foregroundStyle(Theme.textMuted).frame(maxWidth: .infinity, minHeight: 120)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: artifact.kind.icon).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
            VStack(alignment: .leading, spacing: 1) {
                Text(artifact.summary ?? artifact.title).font(.system(size: 12)).foregroundStyle(Theme.text).lineLimit(2)
                Text("Shared by the \(artifact.by)\(artifact.version > 1 ? " · v\(artifact.version)" : "") · \(ArtifactFiles.size(artifact.bytes))")
                    .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
            }
            Spacer()
            if artifact.kind.isPage {
                Button("Open Large") { openLarge() }
                    .disabled(data == nil)
                    .help("Shows it at Desktop, Tablet or Mobile width, still sandboxed")
            }
            Button(artifact.kind.isPage ? "Open in Browser…" : "Open…") { open() }
                .disabled(data == nil)
                .help(artifact.kind.isPage ? "Opens a copy that still can't reach the network" : "Opens it in its app")
            Button("Save…") { save() }.disabled(data == nil)
        }
        .controlSize(.small)
    }

    /// MF-296: the page shown large, with the same CSP and no-network sandbox as inline.
    private func openLarge() {
        guard let data, artifact.kind.isPage else { return }
        state.showLightbox(.page(html: ArtifactFiles.page(data, kind: artifact.kind), caption: artifact.title, scripts: true))
    }

    private func load() async {
        data = nil
        failed = nil
        if let demo = FactoryData.demoArtifactFiles[artifact.file] {
            data = demo
            return
        }
        do {
            guard let client else { throw FactoryClient.ClientError.message("Not signed in.") }
            data = try await client.attachment(artifact.file)
        } catch {
            failed = FactoryClient.describe(error)
        }
    }

    /// A copy in a temporary folder, quarantined like a download; a page gets the same no-network CSP.
    private func open() {
        guard let data, let name = ArtifactFiles.name(artifact) else { return }
        do {
            let folder = FileManager.default.temporaryDirectory.appending(path: "maple-artifacts/\(artifact.id)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: artifact.kind == .svg ? name + ".html" : name)
            try (artifact.kind.isPage ? Data(ArtifactFiles.page(data, kind: artifact.kind).utf8) : data).write(to: file)
            FactoryClient.quarantine(file)
            NSWorkspace.shared.open(file)
        } catch {
            failed = error.localizedDescription
        }
    }

    private func save() {
        guard let data else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ArtifactFiles.name(artifact) ?? artifact.title
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url) } catch { failed = error.localizedDescription }
    }
}

enum ArtifactFiles {
    /// No network, no frames, no forms: only the page's own inline scripts, styles and data: images.
    static let csp = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; media-src data: blob:"

    /// An HTML or SVG artifact as the page the viewer loads, with the CSP before anything else in it.
    static func page(_ data: Data, kind: Wire.ArtifactKind) -> String {
        let source = String(decoding: data, as: UTF8.self)
        let meta = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(csp)\">"
        if kind == .svg {
            return "<!doctype html><html><head>\(meta)<style>html,body{margin:0;height:100%;display:grid;place-items:center;background:#fff}svg{max-width:100%;max-height:100%}</style></head><body>\(source)</body></html>"
        }
        // First in the document (after a leading doctype only): the parser puts it in the implicit <head> ahead
        // of every other tag. Looking for "<head" instead would also match <header>, or one in a comment or script.
        if let doctype = source.range(of: "^\\uFEFF?\\s*<!doctype[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            return source.replacingCharacters(in: doctype, with: source[doctype] + meta)
        }
        return meta + source
    }

    static func name(_ artifact: TaskArtifact) -> String? {
        FactoryClient.attachmentLink(artifact.file)?.name ?? FactoryData.demoArtifactNames[artifact.file]
    }

    static func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// An artifact's page, scripts on, with nowhere to go: a non-persistent store, a content rule list
/// that blocks every load, the CSP from `ArtifactFiles.page`, no base URL (so no origin to reach) and
/// no navigation away from it.
struct SandboxedPage: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html
        let page = html
        Task { @MainActor in
            // The rule list goes on before the page loads, or its first requests would get out.
            if let rules = await Self.blockEverything() {
                view.configuration.userContentController.removeAllContentRuleLists()
                view.configuration.userContentController.add(rules)
            } else {
                // No rule list, no page: the CSP alone isn't enough to run someone's scripts.
                view.loadHTMLString("<p style=\"font:13px -apple-system;color:#888\">Couldn't sandbox this page.</p>", baseURL: nil)
                return
            }
            view.loadHTMLString(page, baseURL: nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: String?

        /// The page itself (about:blank, loadHTMLString's) loads; links and redirects go nowhere.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            action.request.url?.absoluteString == "about:blank" ? .allow : .cancel
        }
    }

    @MainActor private static var rules: WKContentRuleList?

    /// One rule, compiled once: block every load the page asks for.
    @MainActor static func blockEverything() async -> WKContentRuleList? {
        if let rules { return rules }
        let json = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#
        let compiled = try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "maple-artifact-no-network", encodedContentRuleList: json)
        rules = compiled
        return compiled
    }
}

private struct PDFArtifact: NSViewRepresentable {
    let data: Data

    /// The bytes the view shows, so an update compares them instead of re-serializing the document.
    final class Coordinator { var loaded: Data? }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.backgroundColor = .clear
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard context.coordinator.loaded != data else { return }
        context.coordinator.loaded = data
        view.document = PDFDocument(data: data)
    }
}

// MARK: - Demo data

extension FactoryData {
    /// A chart page, drawn by its own inline script, and an SVG: the demo factory's artifacts.
    static let seedArtifacts: [String: [TaskArtifact]] = [
        "ATL-152": [
            TaskArtifact(id: "art-chart", title: "Lockout attempts", kind: .html, summary: "Sign-in attempts per minute before and after the lockout, drawn from the load test",
                         file: demoChartPath, mime: "text/html", bytes: UInt64(demoChart.utf8.count), by: "builder", at: 0, version: 2),
            TaskArtifact(id: "art-flow", title: "Lockout flow", kind: .svg, summary: "How a fifth wrong password locks the account for 15 minutes",
                         file: demoFlowPath, mime: "image/svg+xml", bytes: UInt64(demoFlow.utf8.count), by: "builder", at: 0, version: 1),
        ],
    ]

    private static let demoChartPath = "/attachments/00000000-0000-4000-8000-0000000a0001/lockout-chart.html"
    private static let demoFlowPath = "/attachments/00000000-0000-4000-8000-0000000a0002/lockout-flow.svg"

    static let demoArtifactFiles: [String: Data] = [demoChartPath: Data(demoChart.utf8), demoFlowPath: Data(demoFlow.utf8)]
    static let demoArtifactNames: [String: String] = [demoChartPath: "lockout-chart.html", demoFlowPath: "lockout-flow.svg"]

    private static let demoChart = """
    <!doctype html><html><head><style>body{margin:0;font:13px -apple-system,sans-serif;color:#1d2025}h3{margin:16px 20px 4px;font-size:14px}
    p{margin:0 20px;color:#6a707a}canvas{display:block;margin:12px 20px}</style></head><body>
    <h3>Sign-in attempts per minute</h3><p>Grey: before · Green: with the lockout</p><canvas id="c" width="560" height="260"></canvas>
    <script>
    const before = [42, 58, 61, 77, 93, 120, 140, 162, 171, 188], after = [40, 44, 38, 22, 14, 11, 9, 9, 8, 7];
    const c = document.getElementById("c"), x = c.getContext("2d"), w = 560, h = 230, max = 200;
    x.strokeStyle = "#e2e4e8"; for (let i = 0; i <= 4; i++) { x.beginPath(); x.moveTo(30, 10 + i * h / 4); x.lineTo(w, 10 + i * h / 4); x.stroke(); }
    before.forEach((v, i) => { x.fillStyle = "#c4c8cf"; x.fillRect(40 + i * 52, 10 + h - v / max * h, 20, v / max * h); });
    after.forEach((v, i) => { x.fillStyle = "#14a866"; x.fillRect(62 + i * 52, 10 + h - v / max * h, 20, v / max * h); });
    </script></body></html>
    """

    private static let demoFlow = """
    <svg xmlns="http://www.w3.org/2000/svg" width="520" height="120" font-family="-apple-system,sans-serif" font-size="13">
    <rect x="10" y="40" width="140" height="40" rx="8" fill="#f1f2f4" stroke="#c4c8cf"/><text x="80" y="65" text-anchor="middle">5 wrong passwords</text>
    <path d="M150 60h50" stroke="#6a707a" marker-end="url(#a)"/><rect x="200" y="40" width="130" height="40" rx="8" fill="#fdecea" stroke="#d14343"/>
    <text x="265" y="65" text-anchor="middle">Locked 15 min</text><path d="M330 60h50" stroke="#6a707a" marker-end="url(#a)"/>
    <rect x="380" y="40" width="130" height="40" rx="8" fill="#e7f6ee" stroke="#14a866"/><text x="445" y="65" text-anchor="middle">Try again</text>
    <defs><marker id="a" markerWidth="8" markerHeight="8" refX="7" refY="4" orient="auto"><path d="M0 0L8 4L0 8z" fill="#6a707a"/></marker></defs></svg>
    """
}

import MapleKit
import PDFKit
import SwiftUI
import WebKit

// Task artifacts (MF-205, on the iPhone in MF-273): files an agent shared with `share_artifact`, picked
// from chips above one viewer, as on the Mac (Factory/ArtifactViews.swift). An HTML or SVG artifact runs
// its scripts, but in a web view with nothing to reach: no persistent store, every load blocked by a
// content rule, a CSP that allows only inline code, no origin and no navigation.

extension Wire.Artifact: @retroactive Identifiable {}

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
    let task: Wire.Task
    @State private var selected: String?

    private var artifact: Wire.Artifact? {
        task.artifacts.first { $0.id == selected } ?? task.artifacts.last
    }

    var body: some View {
        if let artifact {
            Card("Artifacts", icon: "paperclip") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(task.artifacts) { chip($0, on: $0.id == artifact.id) }
                    }
                }
                ArtifactViewer(artifact: artifact).id(artifact.id)
            }
        }
    }

    private func chip(_ item: Wire.Artifact, on: Bool) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { selected = item.id }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: item.kind.icon).font(.caption)
                Text(item.title).lineLimit(1)
                if item.version > 1 {
                    Text("v\(item.version)").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            .font(.subheadline.weight(on ? .medium : .regular))
            .foregroundStyle(on ? .primary : .secondary)
            .padding(.horizontal, 11)
            .frame(height: 32)
            .background(Capsule().fill(on ? Color(.tertiarySystemFill) : .clear))
            .overlay(Capsule().strokeBorder(Color(.separator).opacity(on ? 0.8 : 0.4)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("artifact.chip.\(item.id)")
    }
}

/// One artifact: its bytes fetched with your token, drawn by kind, with its caption and Share under it.
private struct ArtifactViewer: View {
    let artifact: Wire.Artifact
    @Environment(FactoryStore.self) private var store
    @State private var data: Data?
    @State private var loading = true
    @State private var viewingImage: LinkedAttachment?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let data {
                    content(data)
                } else {
                    HStack(spacing: 8) {
                        if loading { ProgressView() }
                        Text(loading ? "Loading…" : "Couldn't load it").font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 120)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(.systemBackground)))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(.separator).opacity(0.5)))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("artifact.viewer.\(artifact.id)")
            footer
        }
        .task(id: artifact.file) {
            loading = true
            data = await store.attachment(artifact.file)
            loading = false
        }
        .fullScreenCover(item: $viewingImage) { image in
            AttachmentViewer(images: [image], selection: image.path)
        }
        .fullScreenCover(isPresented: $expanded) {
            if let data { ExpandedArtifactPage(title: artifact.title, html: ArtifactPage.page(data, kind: artifact.kind)) }
        }
    }

    @ViewBuilder private func content(_ data: Data) -> some View {
        switch artifact.kind {
        case .html, .svg:
            SandboxedArtifactPage(html: ArtifactPage.page(data, kind: artifact.kind))
                .frame(height: 360)
                .overlay(alignment: .topTrailing) {
                    Button { expanded = true } label: {
                        Label("Expand", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .accessibilityIdentifier("artifact.expand")
                }
        case .image:
            if let image = UIImage(data: data) {
                Button {
                    viewingImage = LinkedAttachment(name: ArtifactPage.name(artifact), path: artifact.file, kind: .image)
                } label: {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: min(image.size.width, .infinity), maxHeight: 360)
                        .frame(maxWidth: .infinity)
                        .padding(8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(artifact.title)
                .accessibilityIdentifier("artifact.image.\(artifact.id)")
            } else {
                unreadable
            }
        case .pdf:
            PDFArtifact(data: data).frame(height: 420)
        case .markdown:
            ScrollView {
                MarkdownText(source: String(decoding: data, as: UTF8.self))
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 420)
        case .text, .data, .other:
            ScrollView([.vertical, .horizontal]) {
                Text(String(decoding: data.prefix(512 * 1024), as: UTF8.self))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 360)
        }
    }

    private var unreadable: some View {
        Text("This file couldn't be shown.").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(artifact.summary ?? artifact.title).font(.footnote).lineLimit(3)
                Text("Shared by the \(artifact.by)\(artifact.version > 1 ? " · v\(artifact.version)" : "") · \(ArtifactPage.size(artifact.bytes))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let data, let file = ArtifactPage.temporaryCopy(data, artifact: artifact) {
                ShareLink(item: file) { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Share \(artifact.title)")
                    .accessibilityIdentifier("artifact.share")
            }
        }
    }
}

/// The page full screen, in the same sandbox.
private struct ExpandedArtifactPage: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let html: String

    var body: some View {
        NavigationStack {
            SandboxedArtifactPage(html: html)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.accessibilityIdentifier("artifact.expanded.done")
                    }
                }
        }
    }
}

/// The Mac's ArtifactFiles, for the phone.
enum ArtifactPage {
    /// No network, no frames, no forms: only the page's own inline scripts, styles and data: images.
    static let csp = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; media-src data: blob:"

    /// An HTML or SVG artifact as the page the viewer loads, with the CSP before anything else in it.
    static func page(_ data: Data, kind: Wire.ArtifactKind) -> String {
        let source = String(decoding: data, as: UTF8.self)
        let meta = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(csp)\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
        if kind == .svg {
            return "<!doctype html><html><head>\(meta)<style>html,body{margin:0;height:100%;display:grid;place-items:center;background:#fff}svg{max-width:100%;max-height:100%}</style></head><body>\(source)</body></html>"
        }
        // First in the document (after a leading doctype only), so the parser puts it in the implicit <head>
        // ahead of every other tag.
        if let doctype = source.range(of: "^\\uFEFF?\\s*<!doctype[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            return source.replacingCharacters(in: doctype, with: source[doctype] + meta)
        }
        return meta + source
    }

    /// The file's own name, from its /attachments/<id>/<name> path.
    static func name(_ artifact: Wire.Artifact) -> String {
        artifact.file.split(separator: "/").last.map(String.init)?.removingPercentEncoding ?? artifact.title
    }

    static func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// A copy in a temporary folder for the share sheet.
    static func temporaryCopy(_ data: Data, artifact: Wire.Artifact) -> URL? {
        let folder = FileManager.default.temporaryDirectory.appending(path: "maple-artifacts/\(artifact.id)-v\(artifact.version)")
        let file = folder.appending(path: name(artifact))
        if FileManager.default.fileExists(atPath: file.path) { return file }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file)
            return file
        } catch {
            return nil
        }
    }
}

/// An artifact's page, scripts on, with nowhere to go: a non-persistent store, a content rule list that
/// blocks every load, the CSP from `ArtifactPage.page`, no base URL (so no origin) and no navigation away.
struct SandboxedArtifactPage: UIViewRepresentable {
    let html: String

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
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
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
                view.loadHTMLString("<p style=\"font:15px -apple-system;color:#888;margin:16px\">Couldn't sandbox this page.</p>", baseURL: nil)
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

private struct PDFArtifact: UIViewRepresentable {
    let data: Data

    /// The bytes the view shows, so an update compares them instead of re-reading the document.
    final class Coordinator { var loaded: Data? }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        guard context.coordinator.loaded != data else { return }
        context.coordinator.loaded = data
        view.document = PDFDocument(data: data)
    }
}

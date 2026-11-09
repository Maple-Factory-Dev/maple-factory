import SwiftUI
import WebKit
import MapleKit

/// What the editor host shows above the page: the bridge's `status`, `peers`, `synced` and `error` events.
@Observable final class DocEditorStatus {
    var status = "connecting"
    var synced = false
    var peers: [Peer] = []
    var error: String?

    struct Peer: Hashable { let login: String; let name: String; let color: String }
}

/// Hosts the shared docs editor (`/app/docs/embed.html`, MF-361) in a WKWebView and drives it through its JS
/// bridge (docs/planning-docs.md). The page URL carries only `?theme=`; the token goes over `mapleDocs.load`
/// as a typed argument. `openTask` opens the task natively; other server pages open natively (task links) or in the browser.
struct DocEditorView: NSViewRepresentable {
    /// Where the page comes from and what `load` gets.
    enum Source: Equatable {
        /// The factory's own embed, with the app's token handed over natively.
        case live(url: URL, token: String)
        /// The bundled copy, local-only: the signed-out mockup.
        case demo(markdown: String)
    }

    let docId: String
    let source: Source
    let me: [String: Any]
    let members: [[String: Any]]
    let tasks: [[String: Any]]
    let dark: Bool
    let status: DocEditorStatus
    /// Bumped by Retry to reload the page.
    let reloadToken: Int
    let openTask: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(WeakHandler(context.coordinator), name: "maple")
        config.setURLSchemeHandler(DocsEmbedScheme(), forURLScheme: DocsEmbedScheme.scheme)
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")
        #if DEBUG
        web.isInspectable = true
        #endif
        context.coordinator.web = web
        context.coordinator.update(self)
        context.coordinator.loadPage()
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        let coordinator = context.coordinator
        let reload = coordinator.view?.docId != docId || coordinator.view?.source != source || coordinator.view?.reloadToken != reloadToken
        let themeChanged = coordinator.view?.dark != dark
        coordinator.update(self)
        if reload { coordinator.loadPage() } else if themeChanged { coordinator.setTheme() }
    }

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        web.callAsyncJavaScript("window.mapleDocs?.destroy()", arguments: [:], in: nil, in: .page) { _ in }
        web.configuration.userContentController.removeScriptMessageHandler(forName: "maple")
    }

    /// The embed page for a source: no token, only the theme.
    static func pageURL(_ source: Source, dark: Bool) -> URL? {
        let theme = dark ? "dark" : "light"
        switch source {
        case .live(let url, _):
            guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            parts.queryItems = [URLQueryItem(name: "theme", value: theme)]
            return parts.url
        case .demo:
            return URL(string: "\(DocsEmbedScheme.scheme)://embed/embed.html?theme=\(theme)")
        }
    }

    enum Route: Equatable { case allow, task(String), external }

    /// The navigation policy: only the embed page itself (and frames on its origin) load in the view. Any other
    /// page on the server goes native when it names a task (`/app/#/task/MF-1`) and to the browser otherwise.
    static func route(_ url: URL, embed: URL?, isMainFrame: Bool) -> Route {
        guard let embed, url.scheme == embed.scheme, url.host() == embed.host(), url.port == embed.port else { return .external }
        if url.path == embed.path || !isMainFrame { return .allow }
        if let fragment = url.fragment, let match = fragment.firstMatch(of: /^\/?task\/([A-Za-z]+-\d+)$/) {
            return .task(String(match.1))
        }
        return .external
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var web: WKWebView?
        var view: DocEditorView?
        private var embedURL: URL?

        func update(_ view: DocEditorView) { self.view = view }

        func loadPage() {
            guard let view, let web, let url = DocEditorView.pageURL(view.source, dark: view.dark) else { return }
            embedURL = url
            view.status.error = nil
            view.status.synced = false
            view.status.peers = []
            view.status.status = "connecting"
            // The navigation log the proof reads: only `embed.html?theme=…`, never a token.
            print("[docs] load \(url.absoluteString)")
            web.load(URLRequest(url: url))
        }

        func setTheme() {
            guard let view else { return }
            web?.callAsyncJavaScript("window.mapleDocs?.setTheme(theme)", arguments: ["theme": view.dark ? "dark" : "light"],
                                     in: nil, in: .page) { _ in }
        }

        private func load() {
            guard let view, let web else { return }
            var args: [String: Any] = ["docId": view.docId, "me": view.me, "members": view.members, "tasks": view.tasks]
            switch view.source {
            case .live(_, let token): args["token"] = token
            case .demo(let markdown): args["demo"] = ["markdown": markdown]
            }
            web.callAsyncJavaScript("return await mapleDocs.load(args)", arguments: ["args": args], in: nil, in: .page) { result in
                if case .failure(let error) = result { view.status.error = error.localizedDescription }
            }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String, let view else { return }
            switch type {
            case "ready": load()
            case "status": view.status.status = body["status"] as? String ?? view.status.status
            case "synced": view.status.synced = true; view.status.error = nil
            case "peers":
                let peers = (body["peers"] as? [[String: Any]]) ?? []
                view.status.peers = peers.compactMap { p in
                    guard let login = p["login"] as? String else { return nil }
                    return .init(login: login, name: p["name"] as? String ?? login, color: p["color"] as? String ?? "#888888")
                }
            case "error": view.status.error = body["message"] as? String ?? "The doc couldn't be opened."
            case "openTask": if let id = body["id"] as? String { view.openTask(id) }
            default: break
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { return decisionHandler(.cancel) }
            print("[docs] navigate \(url.absoluteString)")
            switch DocEditorView.route(url, embed: embedURL, isMainFrame: action.targetFrame?.isMainFrame ?? true) {
            case .allow: return decisionHandler(.allow)
            case .task(let id): view?.openTask(id); return decisionHandler(.cancel)
            case .external: break
            }
            if url.scheme == "maplefactory" || url.scheme == "http" || url.scheme == "https" || url.scheme == "mailto" {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            view?.status.error = error.localizedDescription
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            view?.status.error = error.localizedDescription
        }
    }

    /// WKUserContentController keeps its handlers strongly; this keeps the coordinator from leaking.
    private final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var target: WKScriptMessageHandler?
        init(_ target: WKScriptMessageHandler) { self.target = target }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            target?.userContentController(controller, didReceive: message)
        }
    }
}

/// Serves the bundled embed (Resources/DocsEmbed, copied by scripts/build-docs-editor.mjs) on its own scheme, so
/// its ES module import works with no network.
final class DocsEmbedScheme: NSObject, WKURLSchemeHandler {
    static let scheme = "maple-docs"

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let name = url.lastPathComponent as NSString
        let ext = name.pathExtension
        let file = Bundle.module.url(forResource: name.deletingPathExtension, withExtension: ext, subdirectory: "DocsEmbed")
            ?? Bundle.module.url(forResource: name.deletingPathExtension, withExtension: ext)
        guard let file, let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mime = ["html": "text/html", "js": "text/javascript", "css": "text/css"][ext] ?? "application/octet-stream"
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "\(mime); charset=utf-8", "Content-Length": "\(data.count)"])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

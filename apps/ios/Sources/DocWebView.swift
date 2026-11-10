import MapleKit
import SwiftUI
import UIKit
import WebKit

/// What the Doc tab shows above the page: the bridge's `status`, `synced` and `error` events.
@Observable final class DocWebStatus {
    var status = "connecting"
    var synced = false
    var peers: [String] = []
    var error: String?
}

/// The Doc tab (MF-370): the shared editor with a status strip (connecting / synced / error, with Retry).
/// Signed out it shows the bundled embed in demo mode.
struct DocWebTab: View {
    @Environment(FactoryStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    let id: String
    let threads: [Wire.DocThread]
    let decisions: [Wire.Decision]
    @State private var status = DocWebStatus()
    @State private var reload = 0
    @State private var openTask: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if let error = status.error {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).lineLimit(2)
                    Spacer()
                    Button("Retry") { reload += 1 }.buttonStyle(.bordered).controlSize(.small)
                } else {
                    Circle().fill(status.synced ? Color.green : Color.orange).frame(width: 7, height: 7)
                    Text(status.synced ? "Synced" : status.status.capitalized)
                    Spacer()
                }
            }
            .font(.caption).foregroundStyle(.secondary).padding(.horizontal).padding(.bottom, 6)
            .accessibilityIdentifier("doc-status")
            if let source {
                DocWebView(docId: id, source: source, me: me, members: members, threadsJSON: json(threads), decisionsJSON: json(decisions),
                           dark: scheme == .dark, status: status, reloadToken: reload,
                           onCommand: { store.sendDocCommand($0) }) { openTask = $0 }
            } else {
                ContentUnavailableView("Doc not available", systemImage: "doc.richtext", description: Text("Sign in to open this doc."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationDestination(item: $openTask) { TaskDetailView(id: $0) }
    }

    private var source: DocWebView.Source? {
        if store.status == .demo { return .demo(markdown: DemoData.docsMarkdown) }
        guard let embed = store.docEmbed() else { return nil }
        return .live(url: embed.url, token: embed.token)
    }

    private var me: [String: Any] {
        guard let me = store.feed.me else { return ["login": "you", "name": "You"] }
        return ["login": me.login, "name": me.name ?? me.login, "avatar": me.avatarUrl as Any]
    }

    private var members: [[String: Any]] {
        store.feed.members.map { ["login": $0.login, "name": $0.name ?? $0.login, "avatar": $0.avatarUrl as Any] }
    }

    private func json<T: Encodable>(_ value: T) -> String {
        (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }
}

/// Hosts the shared docs editor (`/app/docs/embed.html`, MF-361) in a WKWebView and drives it through its JS
/// bridge (docs/planning-docs.md). The page URL carries only `?theme=`; the token goes over `mapleDocs.load`
/// as a typed argument. `openTask` opens the task natively; other server pages open natively (task links) or in the browser.
struct DocWebView: UIViewRepresentable {
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
    /// Tasks, JSON-encoded (MF-368: with state and fromDoc): pushed with `mapleDocs.updateTasks` when they change.
    var tasksJSON: String = "[]"
    /// The doc's comment threads, JSON-encoded (MF-364): pushed with `mapleDocs.updateThreads` when they change.
    var threadsJSON: String = "[]"
    /// The doc's decisions, JSON-encoded (MF-367): pushed with `mapleDocs.updateDecisions` when they change.
    var decisionsJSON: String = "[]"
    /// Goals the Make tasks dialog can pick (MF-368) when the doc has none, and the doc's own goal.
    var goals: [[String: String]] = []
    var docGoal: String? = nil
    let dark: Bool
    let status: DocWebStatus
    /// Bumped by Retry to reload the page.
    let reloadToken: Int
    /// Put the caret in the doc once it syncs (MF-382): a doc we just created opens ready to type.
    var focusOnSync = false
    /// Called after that focus, so it happens once.
    var onFocused: () -> Void = {}
    /// The embed's `command` events (doc.comment / doc.resolve / doc.reopen, decision.*), for the app's socket.
    var onCommand: ([String: Any]) -> Void = { _ in }
    let openTask: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(WeakHandler(context.coordinator), name: "maple")
        config.userContentController.addUserScript(WKUserScript(source: Self.frameRelay, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.setURLSchemeHandler(DocsEmbedSchemeIOS(), forURLScheme: DocsEmbedSchemeIOS.scheme)
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.isOpaque = false
        web.backgroundColor = .clear
        #if DEBUG
        web.isInspectable = true
        #endif
        context.coordinator.web = web
        context.coordinator.update(self)
        context.coordinator.loadPage()
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        let coordinator = context.coordinator
        let reload = coordinator.view?.docId != docId || coordinator.view?.source != source || coordinator.view?.reloadToken != reloadToken
        let themeChanged = coordinator.view?.dark != dark
        let threadsChanged = coordinator.view?.threadsJSON != threadsJSON
        let decisionsChanged = coordinator.view?.decisionsJSON != decisionsJSON
        let tasksChanged = coordinator.view?.tasksJSON != tasksJSON
        let goalsChanged = coordinator.view?.goals != goals || coordinator.view?.docGoal != docGoal
        coordinator.update(self)
        if reload { coordinator.loadPage() } else if themeChanged { coordinator.setTheme() }
        if !reload && threadsChanged { coordinator.pushThreads() }
        if !reload && decisionsChanged { coordinator.pushDecisions() }
        if !reload && tasksChanged { coordinator.pushTasks() }
        if !reload && goalsChanged { coordinator.pushGoals() }
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
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
            return URL(string: "\(DocsEmbedSchemeIOS.scheme)://embed/embed.html?theme=\(theme)")
        }
    }

    /// Runs in every frame (MF-387): script errors, unhandled rejections and CSP violations, plus the diagram
    /// frames' `maple.diagram.state` events, go to the `maple` handler as `frame` messages and land in the log as
    /// `[docs] frame …`, so a blank diagram frame says why.
    static let frameRelay = """
    (() => {
      const post = (detail) => { try { window.webkit.messageHandlers.maple.postMessage({ type: "frame", frame: String(location.href).split("?")[0], detail }); } catch (_) {} };
      addEventListener("error", (e) => post(`error ${e.message || (e.target && (e.target.src || e.target.href)) || "?"} ${e.filename || ""}:${e.lineno || 0}`), true);
      addEventListener("unhandledrejection", (e) => post(`unhandledrejection ${e.reason && (e.reason.message || e.reason)}`));
      addEventListener("securitypolicyviolation", (e) => post(`csp ${e.violatedDirective} blocked ${e.blockedURI || "inline"}`));
      if (window.top === window) addEventListener("message", (e) => {
        const d = e.data;
        if (d && d.type === "maple.diagram.state") post(`diagram ${d.event || ""}${d.message ? " " + String(d.message).split("\\n")[0] : ""}`);
      });
    })();
    """

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
        var view: DocWebView?
        private var embedURL: URL?

        func update(_ view: DocWebView) { self.view = view }

        func loadPage() {
            guard let view, let web, let url = DocWebView.pageURL(view.source, dark: view.dark) else { return }
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

        /// Makes the page first responder and puts the caret at the end of the doc, so typing works without a click.
        func focusEditor() {
            guard let web else { return }
            web.callAsyncJavaScript("window.mapleDocs?.focus()", arguments: [:], in: nil, in: .page) { _ in }
        }

        func pushThreads() {
            guard let view else { return }
            web?.callAsyncJavaScript("window.mapleDocs?.updateThreads(JSON.parse(json))", arguments: ["json": view.threadsJSON],
                                     in: nil, in: .page) { _ in }
        }

        func pushDecisions() {
            guard let view else { return }
            web?.callAsyncJavaScript("window.mapleDocs?.updateDecisions(JSON.parse(json))", arguments: ["json": view.decisionsJSON],
                                     in: nil, in: .page) { _ in }
        }

        func pushTasks() {
            guard let view else { return }
            web?.callAsyncJavaScript("window.mapleDocs?.updateTasks(JSON.parse(json))", arguments: ["json": view.tasksJSON],
                                     in: nil, in: .page) { _ in }
        }

        func pushGoals() {
            guard let view else { return }
            web?.callAsyncJavaScript("window.mapleDocs?.updateGoals(goals, docGoal)", arguments: ["goals": view.goals, "docGoal": view.docGoal ?? NSNull()],
                                     in: nil, in: .page) { _ in }
        }

        private func load() {
            guard let view, let web else { return }
            var args: [String: Any] = ["docId": view.docId, "me": view.me, "members": view.members, "goals": view.goals, "docGoal": view.docGoal ?? NSNull()]
            if let tasks = try? JSONSerialization.jsonObject(with: Data(view.tasksJSON.utf8)) { args["tasks"] = tasks }
            if let threads = try? JSONSerialization.jsonObject(with: Data(view.threadsJSON.utf8)) { args["threads"] = threads }
            if let decisions = try? JSONSerialization.jsonObject(with: Data(view.decisionsJSON.utf8)) { args["decisions"] = decisions }
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
            guard DocWebView.acceptsMessage(type, isMainFrame: message.frameInfo.isMainFrame) else {
                print("[docs] dropped \(type) message from a subframe"); return
            }
            switch type {
            case "ready": load()
            case "status": view.status.status = body["status"] as? String ?? view.status.status
            case "synced":
                view.status.synced = true; view.status.error = nil
                if view.focusOnSync { focusEditor(); view.onFocused() }
            case "peers":
                let peers = (body["peers"] as? [[String: Any]]) ?? []
                view.status.peers = peers.compactMap { $0["login"] as? String }
            case "error": view.status.error = body["message"] as? String ?? "The doc couldn't be opened."
            case "openTask": if let id = body["id"] as? String { view.openTask(id) }
            case "frame": print("[docs] frame \(body["frame"] as? String ?? "?") \(body["detail"] as? String ?? "")")
            case "command": if let command = body["command"] as? [String: Any] { view.onCommand(command) }
            default: break
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { return decisionHandler(.cancel) }
            let isMainFrame = action.targetFrame?.isMainFrame ?? true
            let route = DocWebView.route(url, embed: embedURL, isMainFrame: isMainFrame)
            print("[docs] navigate \(isMainFrame ? "main" : "subframe") \(url.absoluteString) → \(route)")
            switch route {
            case .allow: return decisionHandler(.allow)
            case .task(let id): view?.openTask(id); return decisionHandler(.cancel)
            case .external: break
            }
            if url.scheme == "maplefactory" || url.scheme == "http" || url.scheme == "https" || url.scheme == "mailto" {
                UIApplication.shared.open(url)
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

extension DocWebView {
    /// Subframes (the sandboxed diagram frames render agent-written source) may only send the diagnostic `frame`
    /// message; everything that drives the editor or the app has to come from the embed's main frame.
    static func acceptsMessage(_ type: String, isMainFrame: Bool) -> Bool {
        isMainFrame || type == "frame"
    }
}

/// Serves the bundled embed (Resources/DocsEmbed, copied by scripts/build-docs-editor.mjs) on its own scheme, so
/// its ES module import works with no network.
final class DocsEmbedSchemeIOS: NSObject, WKURLSchemeHandler {
    static let scheme = "maple-docs"

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let name = url.lastPathComponent as NSString
        let ext = name.pathExtension
        let file = Bundle.main.url(forResource: name.deletingPathExtension, withExtension: ext, subdirectory: "DocsEmbed")
            ?? Bundle.main.url(forResource: name.deletingPathExtension, withExtension: ext)
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

import AppKit
import SwiftUI
import WebKit

/// "What's new" for the update on offer, in the window instead of the browser: the update site's
/// changelog.html, which narrows itself to the releases being skipped and follows dark mode. Links
/// that leave the changelog open in the browser. Update & Restart in the footer, so you can read
/// and update from one place.
struct ReleaseNotesSheet: View {
    private var updater = Updater.shared
    @Environment(\.dismiss) private var dismiss
    @State private var load: Load = .loading
    /// Bumped by Try Again, to build the page anew.
    @State private var attempt = 0

    enum Load: Equatable { case loading, loaded, failed }

    /// Where a link in the release notes goes: stays on the changelog (its own Show all releases, a
    /// fragment), out to the browser (any other web page), or nowhere (anything else).
    enum Navigation: Equatable { case stay, browser, block }

    nonisolated static func releaseNotesNavigation(_ url: URL, page: URL) -> Navigation {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            // about:blank and friends that WebKit loads along the way are harmless, but go nowhere.
            return .block
        }
        let a = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let b = URLComponents(url: page, resolvingAgainstBaseURL: false)
        if let a, let b,
           a.scheme?.lowercased() == b.scheme?.lowercased(),
           a.host?.lowercased() == b.host?.lowercased(),
           a.port == b.port,
           a.path == b.path {
            return .stay
        }
        return .browser
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 560, height: 600)
        .background(Theme.editorBG)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("What's New in Maple Factory")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
            if let offered = updater.offeredVersion {
                Text("\(updater.notesInstalledVersion) → \(offered)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder private var content: some View {
        if let url = updater.releaseNotesURL {
            ZStack {
                ReleaseNotesWebView(url: url, load: $load)
                    .id(attempt)
                    .opacity(load == .loaded ? 1 : 0)
                switch load {
                case .loading:
                    ProgressView().controlSize(.small)
                case .failed:
                    ContentUnavailableView {
                        Label("Couldn't load the release notes", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text("Check your connection, or read them in the browser.")
                    } actions: {
                        HStack {
                            Button("Try Again") { load = .loading; attempt += 1 }
                            Button("Open in Browser") { NSWorkspace.shared.open(url) }
                        }
                        .fixedSize()
                    }
                case .loaded:
                    EmptyView()
                }
            }
        } else {
            ContentUnavailableView("No release notes for this update", systemImage: "doc.text")
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let url = updater.releaseNotesURL {
                Button("Open in Browser") { NSWorkspace.shared.open(url) }
            }
            Spacer()
            Button("Later") { dismiss() }
                .keyboardShortcut(.cancelAction)
            if let label = Self.updateButtonLabel(phase: updater.phase) {
                Button(label) {
                    updater.updateAndRestart()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// Update & Restart while an update is on offer, Restart once it's downloaded, nothing while it's busy.
    static func updateButtonLabel(phase: UpdatePhase) -> String? {
        switch phase {
        case .available: UpdatePhase.updateToastButtonLabel
        case .readyToRelaunch: "Restart"
        default: nil
        }
    }
}

/// The changelog page: a non-persistent store, its background left to the sheet's, and links that
/// leave it handed to the browser.
private struct ReleaseNotesWebView: NSViewRepresentable {
    let url: URL
    @Binding var load: ReleaseNotesSheet.Load

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.load(URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 15))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: ReleaseNotesWebView

        init(parent: ReleaseNotesWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let target = action.request.url else { return .cancel }
            // Subframes (an embed on a release's notes) load in place; only the page itself is policed.
            if action.targetFrame?.isMainFrame == false { return .allow }
            switch ReleaseNotesSheet.releaseNotesNavigation(target, page: parent.url) {
            case .stay: return .allow
            case .browser: NSWorkspace.shared.open(target); return .cancel
            case .block: return .cancel
            }
        }

        /// target="_blank" links: to the browser, by the same rule.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let target = action.request.url,
               ReleaseNotesSheet.releaseNotesNavigation(target, page: parent.url) != .block {
                NSWorkspace.shared.open(target)
            }
            return nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.load = .loaded
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            fail(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            fail(error)
        }

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            // A 404 (an update site without a changelog yet) is a failure too, not a blank page.
            if response.isForMainFrame, let http = response.response as? HTTPURLResponse, http.statusCode >= 400 {
                parent.load = .failed
                return .cancel
            }
            return .allow
        }

        private func fail(_ error: any Error) {
            // A link handed to the browser cancels its navigation; that's not the page failing.
            if (error as NSError).code == NSURLErrorCancelled { return }
            if (error as NSError).domain == "WebKitErrorDomain", (error as NSError).code == 102 { return }
            parent.load = .failed
        }
    }
}

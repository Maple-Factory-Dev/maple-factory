import AppKit
import SwiftTerm
import SwiftUI

/// A live session's terminal: SwiftTerm drawing the bytes the runner's tmux pane produces,
/// relayed through the factory. Typing goes back the same way.
struct LiveTerminal: NSViewRepresentable {
    let request: (Int, Int) -> URLRequest?
    @Binding var state: TerminalLink.State

    func makeCoordinator() -> TerminalLink { TerminalLink(request: request, state: $state) }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        view.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        view.nativeBackgroundColor = Term.nsBG
        view.nativeForegroundColor = Term.nsText
        view.caretColor = Term.nsCaret
        view.optionAsMetaKey = true
        context.coordinator.view = view
        // Connect once SwiftUI has sized the view, so the runner gets the real cols × rows.
        DispatchQueue.main.async { context.coordinator.connect() }
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {}

    static func dismantleNSView(_ view: TerminalView, coordinator: TerminalLink) {
        coordinator.close()
    }
}

/// The socket behind one terminal view.
@MainActor final class TerminalLink: NSObject {
    enum State: Equatable {
        case connecting
        case live
        case closed(String)
    }

    weak var view: TerminalView?
    private let request: (Int, Int) -> URLRequest?
    private let state: Binding<State>
    private var socket: URLSessionWebSocketTask?
    private var closing = false
    /// Attempts since the last good connection, for the backoff.
    private var retries = 0
    /// After a reconnect the replay repaints everything, so the screen starts clean.
    private var resetOnData = false

    init(request: @escaping (Int, Int) -> URLRequest?, state: Binding<State>) {
        self.request = request
        self.state = state
    }

    func connect() {
        guard let view else { return }
        let terminal = view.getTerminal()
        guard let request = request(terminal.cols, terminal.rows) else {
            state.wrappedValue = .closed("Not signed in.")
            return
        }
        let socket = URLSession.shared.webSocketTask(with: request)
        self.socket = socket
        socket.resume()
        state.wrappedValue = .connecting
        Task { await receive(socket) }
        view.window?.makeFirstResponder(view)
    }

    func close() {
        closing = true
        socket?.cancel(with: .normalClosure, reason: nil)
    }

    private func receive(_ socket: URLSessionWebSocketTask) async {
        while !closing {
            do {
                switch try await socket.receive() {
                case .data(let data):
                    if state.wrappedValue != .live { state.wrappedValue = .live }
                    retries = 0
                    if resetOnData {
                        resetOnData = false
                        view?.getTerminal().resetToInitialState()
                    }
                    view?.feed(byteArray: ArraySlice([UInt8](data)))
                case .string(let text):
                    // The server's own notes, e.g. {"type":"error","message":"That machine is offline."}
                    if let data = text.data(using: .utf8),
                       let note = try? JSONDecoder().decode([String: String].self, from: data), let message = note["message"] {
                        state.wrappedValue = .closed(message)
                    }
                @unknown default:
                    break
                }
            } catch {
                guard !closing else { return }
                state.wrappedValue = .closed(FactoryClient.describe(error, response: socket.response))
                // Try again on a backoff: a server restart or a network blip shouldn't need a click.
                retries += 1
                resetOnData = true
                let delay = min(pow(2, Double(min(retries, 4))), 15)
                try? await Task.sleep(for: .seconds(delay))
                if !closing { connect() }
                return
            }
        }
    }
}

extension TerminalLink: @preconcurrency TerminalViewDelegate {
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        socket?.send(.data(Data(data))) { _ in }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        let json = "{\"type\":\"session.resize\",\"cols\":\(newCols),\"rows\":\(newRows)}"
        socket?.send(.string(json)) { _ in }
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func bell(source: TerminalView) { NSSound.beep() }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

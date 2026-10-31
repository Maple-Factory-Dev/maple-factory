import MapleKit
import SwiftTerm
import SwiftUI
import UIKit

/// One live session's terminal on the phone: what the agent's tmux pane draws, relayed by the factory over
/// the same `/client/terminal` socket as the Mac's LiveSessionView. It attaches when the screen appears and
/// detaches when it goes. The machine's owner, admins and teammates it was shared with to type get a keyboard;
/// everyone else watches. The phone never resizes the agent's pane: it draws `SessionTerminal.columns` wide
/// and scrolls sideways.
struct SessionTerminalView: View {
    @Environment(FactoryStore.self) private var store
    let machineID: String
    let sessionID: String

    @State private var link: SessionLink.State = .connecting
    /// On screen: the socket is open only while it is.
    @State private var active = false
    /// The session as last seen live, so the header keeps its agent and folder after it ends.
    @State private var lastSeen: Wire.LiveSession?

    private var machine: Wire.Machine? { store.feed.machines.first { $0.id == machineID } }
    private var current: Wire.LiveSession? { machine?.sessions.first { $0.session.id == sessionID } }
    private var live: Wire.LiveSession? { current ?? lastSeen }
    private var ended: Bool { store.feed.hasSnapshot && current == nil }
    private var canType: Bool { store.canType(machine: machineID, session: sessionID) }
    /// How it's shared with you, when it's someone else's.
    private var myShare: Wire.SessionShare? {
        machine?.owner == store.me || store.isAdmin ? nil : live?.shares?.first { $0.login == store.me }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack(alignment: .bottom) {
                SwiftUI.Color(uiColor: SessionTerminal.background)
                GeometryReader { geo in
                    ScrollView(.horizontal) {
                        SessionTerminal(request: { store.terminalRequest(machine: machineID, session: sessionID) },
                                        demo: store.status == .demo ? DemoData.terminal(for: sessionID) : nil,
                                        state: $link, active: active, canType: canType)
                            .frame(width: SessionTerminal.width, height: geo.size.height)
                    }
                    .scrollIndicators(.visible)
                }
                .padding(.leading, 8)
                .padding(.top, 6)
                .opacity(ended ? 0.55 : 1)

                if let banner {
                    Label(banner.text, systemImage: banner.icon)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(banner.color.gradient))
                        .padding(.bottom, 12)
                        .accessibilityIdentifier("terminalBanner")
                }
            }
            statusLine
        }
        .navigationTitle(live?.session.taskId ?? live?.session.agent ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let task = live?.session.taskId {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink(value: TaskRoute(id: task)) { Label("Open task \(task)", systemImage: "arrow.up.forward.square") }
                        .accessibilityIdentifier("openTask")
                }
            }
        }
        .onAppear {
            lastSeen = current ?? lastSeen
            active = true
        }
        .onDisappear { active = false }
        .onChange(of: current) { _, now in if let now { lastSeen = now } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(live.map { [$0.session.agent, $0.session.taskId].compactMap { $0 }.joined(separator: " · ") } ?? sessionID)
                    .font(.headline)
                if let state = current?.activity?.state {
                    Label(state.rawValue, systemImage: "circle.fill")
                        .labelStyle(DotLabel())
                        .font(.caption)
                        .foregroundStyle(state == .waiting ? Theme.warning : Theme.approve)
                }
                Spacer()
                Text(canType ? "Typing" : "Watching")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill((canType ? Theme.state(.awaitingApproval) : Theme.accent).opacity(0.15)))
                    .foregroundStyle(canType ? Theme.state(.awaitingApproval) : Theme.accent)
                    .accessibilityIdentifier("typingPill")
            }
            Text([machine?.name ?? machineID, live?.session.cwd].compactMap { $0 }.joined(separator: " · "))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            if let message = current?.activity?.message {
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var banner: (text: String, icon: String, color: SwiftUI.Color)? {
        if ended { return ("Session ended", "stop.circle", .secondary) }
        if machine?.online == false { return ("\(machine?.name ?? "The machine") is offline", "wifi.slash", Theme.warning) }
        switch link {
        case .closed(let reason): return (reason, "wifi.slash", Theme.warning)
        case .refused(let reason): return (reason, "lock.fill", Theme.danger)
        case .connecting, .live: return nil
        }
    }

    private var statusLine: some View {
        let share = myShare.map { " · shared by @\($0.by) to \($0.canType ? "type" : "watch")" } ?? ""
        let (text, color): (String, SwiftUI.Color) = switch link {
        case _ where ended: ("Session ended", .secondary)
        case .connecting: ("Connecting…", .secondary)
        case .live: ("Live" + share, Theme.approve)
        case .closed(let reason): (reason, Theme.warning)
        case .refused(let reason): (reason, Theme.danger)
        }
        return Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .lineLimit(3)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("terminalStatus")
    }
}

private struct DotLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon.font(.system(size: 6)); configuration.title }
    }
}

/// SwiftTerm's iOS terminal on a session's socket.
struct SessionTerminal: UIViewRepresentable {
    /// The width agents' panes open at (the Mac's session default), so wide TUI output lines up.
    static let columns = 120
    static let font = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    static let background = UIColor(red: 0.08, green: 0.086, blue: 0.10, alpha: 1)
    /// `columns` cells of `font`, measured the way SwiftTerm does, with half a cell to spare.
    static var width: CGFloat {
        let scale = UIScreen.main.scale
        let cell = ("W".size(withAttributes: [.font: font]).width * scale).rounded() / scale
        return cell * CGFloat(columns) + cell / 2
    }

    let request: () -> URLRequest?
    /// The demo's transcript, played instead of opening a socket.
    let demo: String?
    @Binding var state: SessionLink.State
    let active: Bool
    let canType: Bool

    func makeCoordinator() -> SessionLink { SessionLink(request: request, demo: demo, state: $state) }

    func makeUIView(context: Context) -> PhoneTerminalView {
        let view = PhoneTerminalView(frame: .zero, font: Self.font)
        view.terminalDelegate = context.coordinator
        view.nativeBackgroundColor = Self.background
        view.nativeForegroundColor = UIColor(white: 0.86, alpha: 1)
        view.accessibilityIdentifier = "sessionTerminal"
        context.coordinator.view = view
        apply(to: view, context.coordinator)
        return view
    }

    func updateUIView(_ view: PhoneTerminalView, context: Context) {
        apply(to: view, context.coordinator)
    }

    private func apply(to view: PhoneTerminalView, _ link: SessionLink) {
        view.typing = canType
        link.canType = canType
        if !canType, view.isFirstResponder { _ = view.resignFirstResponder() }
        // After SwiftUI has laid it out, so it has its columns before the replay.
        DispatchQueue.main.async { link.setActive(active) }
    }

    static func dismantleUIView(_ view: PhoneTerminalView, coordinator: SessionLink) {
        coordinator.close()
    }
}

/// Takes the keyboard only when what's typed reaches the session.
final class PhoneTerminalView: TerminalView {
    var typing = false

    override var canBecomeFirstResponder: Bool { typing }

    /// The screen's text, for VoiceOver and UI tests.
    override var accessibilityValue: String? {
        get {
            String(data: getTerminal().getBufferAsData(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        set {}
    }
}

/// The socket behind one terminal view, ported from the Mac's TerminalLink: attach, feed what arrives,
/// and reconnect on a backoff unless the server refused who's asking.
@MainActor final class SessionLink: NSObject {
    enum State: Equatable {
        case connecting
        case live
        /// Dropped or a note from the server; it retries.
        case closed(String)
        /// Not allowed (a 403, or access revoked), in the server's words; it doesn't retry.
        case refused(String)
    }

    weak var view: TerminalView?
    var canType = false
    private let request: () -> URLRequest?
    private let demo: String?
    private let state: Binding<State>
    private var socket: URLSessionWebSocketTask?
    /// Bumped on every connect and close, so a stale receive loop or retry stands down.
    private var generation = 0
    private var open = false
    private var played = false
    /// Attempts since the last good connection, for the backoff.
    private var retries = 0
    /// After a reconnect the replay repaints everything, so the screen starts clean.
    private var resetOnData = false

    init(request: @escaping () -> URLRequest?, demo: String?, state: Binding<State>) {
        self.request = request
        self.demo = demo
        self.state = state
    }

    /// Attached while the screen is up, detached while it isn't.
    func setActive(_ on: Bool) {
        if on, !open { connect() } else if !on, open { close() }
    }

    func connect() {
        open = true
        generation += 1
        if let demo {
            if !played { view?.feed(text: demo); played = true }
            state.wrappedValue = .live
            return
        }
        guard let request = request() else {
            state.wrappedValue = .refused("Not signed in.")
            return
        }
        let socket = URLSession.shared.webSocketTask(with: request)
        self.socket = socket
        socket.resume()
        if state.wrappedValue != .live { state.wrappedValue = .connecting }
        let gen = generation
        Task { await receive(socket, gen: gen) }
    }

    func close() {
        open = false
        generation += 1
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        // Coming back attaches again and the replay repaints.
        resetOnData = true
    }

    private func receive(_ socket: URLSessionWebSocketTask, gen: Int) async {
        while gen == generation {
            do {
                switch try await socket.receive() {
                case .data(let data):
                    guard gen == generation else { return }
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
                guard gen == generation else { return }
                // Refused for who's asking (no share, or access revoked): say so, and don't retry.
                if let refusal = await FactoryAPI.terminalRefusal(socket) {
                    guard gen == generation else { return }
                    state.wrappedValue = .refused(refusal)
                    self.socket = nil
                    return
                }
                state.wrappedValue = .closed(FactoryAPI.describe(error, response: socket.response))
                // Try again on a backoff: a server restart or a network blip shouldn't need a tap.
                retries += 1
                resetOnData = true
                let delay = min(pow(2, Double(min(retries, 4))), 15)
                try? await Task.sleep(for: .seconds(delay))
                if gen == generation { connect() }
                return
            }
        }
    }
}

extension SessionLink: @preconcurrency TerminalViewDelegate {
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        // Watching only: nothing goes out (the server drops it anyway).
        guard canType else { return }
        socket?.send(.data(Data(data))) { _ in }
    }

    /// Never resized from the phone: the agent's pane keeps the width its owner gave it.
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func bell(source: TerminalView) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { UIApplication.shared.open(url) }
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        if let text = String(data: content, encoding: .utf8) { UIPasteboard.general.string = text }
    }
}

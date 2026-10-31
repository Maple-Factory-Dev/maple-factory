import Foundation
import MapleKit
import Observation
import UIKit

/// The iPhone app's factory: who you're signed in as, where, and the feed's state. Opens the same
/// `/client/connect` socket as the Mac app, applies what it says to a FeedState (MapleKit), and
/// sends the actions a phone can take.
@MainActor @Observable
final class FactoryStore {
    enum Status: Equatable {
        case signedOut, connecting, live, demo
        case reconnecting(attempt: Int, reason: String)
        case tooNew
    }

    private(set) var status: Status = .signedOut
    private(set) var feed = FeedState()
    private(set) var server: URL?
    private(set) var token: String?
    private(set) var saved: [SavedFactory] = []
    /// The toast or error to show, newest only.
    var notice: FeedState.Notice?
    /// A `maplefactory://` link waiting to be opened. Signing out keeps it, so a link opened on the
    /// sign-in screen opens once you're in; RootView takes it.
    var pendingLink: FactoryLink?
    /// Each task's diff once loaded, keyed by the change it was loaded for.
    private(set) var diffs: [String: (key: String, files: [DiffFile])] = [:]
    /// The last `stats` reply, for admins' Statistics (FeedState doesn't keep it).
    private(set) var stats: Wire.StatsSummary?

    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keychain: Keychain

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        keychain = Keychain(service: "dev.maplefactory.ios", defaults: defaults)
        saved = SavedFactories.load(defaults) ?? []
    }

    var isSignedIn: Bool { status != .signedOut }
    var me: String { feed.me?.login ?? "" }
    var isAdmin: Bool { feed.me?.role == "admin" }
    var factoryName: String { feed.name ?? (feed.org.isEmpty ? server?.host() ?? "Factory" : feed.org) }

    // MARK: Signing in

    /// Opens the most recently used saved factory, if its token is still here.
    func restore() {
        guard let factory = SavedFactories.fallback(saved), let token = keychain.read(account: factory.server.absoluteString) else { return }
        open(factory.server, token: token)
    }

    func signedIn(_ result: FactoryAPI.SignInResult) {
        keychain.write(result.token, account: result.server.absoluteString)
        let name = result.org.isEmpty || result.org == "local" ? result.server.host() ?? "Factory" : result.org
        saved = SavedFactories.upsert(SavedFactory(server: result.server, org: result.org, name: name, lastUsed: Date()), into: saved)
        SavedFactories.store(saved, defaults)
        open(result.server, token: result.token)
    }

    /// Switches to another saved factory.
    func switchTo(_ factory: SavedFactory) {
        guard let token = keychain.read(account: factory.server.absoluteString) else { return }
        var factory = factory
        factory.lastUsed = Date()
        saved = SavedFactories.upsert(factory, into: saved)
        SavedFactories.store(saved, defaults)
        open(factory.server, token: token)
    }

    func signOut() {
        if let server {
            keychain.delete(account: server.absoluteString)
            saved = SavedFactories.remove(server, from: saved)
            SavedFactories.store(saved, defaults)
        }
        close()
        if let next = SavedFactories.fallback(saved) { switchTo(next) }
    }

    /// Leaves the demo, or the factory, for the sign-in screen.
    func close() {
        disconnect()
        generation += 1
        server = nil
        token = nil
        feed = FeedState()
        diffs = [:]
        stats = nil
        status = .signedOut
    }

    private func open(_ server: URL, token: String) {
        close()
        self.server = server
        self.token = token
        connect()
    }

    /// A local dev server's sign-in (`/dev/token`); `-devAs <login>` signs in as that member instead.
    static func devSignIn(_ server: URL) async throws -> FactoryAPI.SignInResult {
        var url = server.appending(path: "/dev/token")
        if let login = UserDefaults.standard.string(forKey: "devAs"), !login.isEmpty { url.append(queryItems: [URLQueryItem(name: "as", value: login)]) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        var result: FactoryAPI.SignInResult = try await FactoryAPI.load(request)
        result.server = server
        return result
    }

    static var deviceLabel: String { UIDevice.current.name }

    // MARK: Feed

    func connect() {
        guard let server, let token else { return }
        disconnect()
        generation += 1
        let gen = generation
        if status != .live { status = attempt == 0 ? .connecting : status }
        var request = URLRequest(url: FactoryAPI.websocketURL(server, path: "/client/connect"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        self.socket = socket
        socket.resume()
        send(.subscribe)
        Task { await receive(socket, gen: gen) }
        Task { await keepAlive(socket, gen: gen) }
    }

    /// Pull to refresh: a fresh socket, so a fresh snapshot.
    func refresh() async {
        guard status != .demo, server != nil else { return }
        attempt = 0
        connect()
        for _ in 0..<30 where status != .live { try? await Task.sleep(for: .milliseconds(100)) }
    }

    private func disconnect() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func receive(_ socket: URLSessionWebSocketTask, gen: Int) async {
        let decoder = JSONDecoder()
        while gen == generation {
            do {
                let message = try await socket.receive()
                guard case .string(let text) = message else { continue }
                apply(try decoder.decode(Wire.ServerToClient.self, from: Data(text.utf8)))
            } catch {
                guard gen == generation else { return }
                if error is DecodingError {
                    NSLog("Maple Factory: can't read the factory's message: \(error)")
                    disconnect()
                    status = .tooNew
                    return
                }
                if (socket.response as? HTTPURLResponse)?.statusCode == 401 {
                    signOut()
                    notice = .error("Your sign-in expired.")
                    return
                }
                retry(reason: FactoryAPI.describe(error, response: socket.response))
                return
            }
        }
    }

    /// Pings keep proxies from dropping a quiet socket.
    private func keepAlive(_ socket: URLSessionWebSocketTask, gen: Int) async {
        while gen == generation {
            try? await Task.sleep(for: .seconds(20))
            guard gen == generation else { return }
            socket.sendPing { _ in }
        }
    }

    /// Tries again after 2, 4, 8… seconds, at most 30.
    private func retry(reason: String) {
        attempt += 1
        status = .reconnecting(attempt: attempt, reason: reason)
        let delay = min(pow(2, Double(min(attempt, 5))), 30)
        let gen = generation
        Task {
            try? await Task.sleep(for: .seconds(delay))
            if gen == generation { connect() }
        }
    }

    /// One message from the feed.
    func apply(_ message: Wire.ServerToClient) {
        if case .snapshot(let snapshot) = message {
            attempt = 0
            status = .live
            ErrorReports.tag(org: snapshot.org)
        }
        if case .stats(let reply) = message { stats = reply.summary }
        if let notice = feed.apply(message) { self.notice = notice }
    }

    func send(_ message: Wire.ClientMessage) {
        if status == .demo { return demoSend(message) }
        guard let socket, let data = try? JSONEncoder().encode(message), let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    // MARK: Actions

    func approvePlan(_ id: String) { send(.taskApprovePlan(.init(id: id))) }
    func approveChanges(_ id: String) { send(.taskApproveChanges(.init(id: id))) }
    func merge(_ id: String) { send(.taskMerge(.init(id: id))) }
    func holdMerge(_ id: String) { send(.taskHoldMerge(.init(id: id))) }
    func answer(_ id: String, text: String) { send(.taskAnswer(.init(id: id, text: text))) }
    func resolveHand(_ id: String, option: String?, note: String) { send(.taskResolveHand(.init(id: id, option: option, note: note))) }
    func comment(_ id: String, text: String) { send(.taskComment(.init(id: id, text: text))) }
    func steer(_ id: String, text: String) { send(.taskSteer(.init(id: id, text: text))) }
    func retryTask(_ id: String) { send(.taskRetry(.init(id: id))) }
    func cancel(_ id: String) { send(.taskCancel(.init(id: id))) }
    /// Sends a draft to planning, or picks up a backlog task.
    func plan(_ id: String) { send(.taskPlan(.init(id: id))) }
    /// Parks a draft (or a plan waiting for approval) in the backlog.
    func sendToBacklog(_ id: String) { send(.taskBacklog(.init(id: id))) }
    /// Moves a draft ahead of `before` ("top": first; nil: last) in its goal's drafts.
    func rankDraft(_ id: String, before: String?) { send(.taskRankDraft(.init(id: id, before: before))) }
    func follow(_ goal: String, _ following: Bool) { send(.goalFollow(.init(id: goal, following: following))) }
    /// Asks for the factory's statistics over the last `days`; the reply lands in `stats`.
    func loadStats(days: Int) { send(.statsGet(.init(days: UInt32(days), goal: nil))) }

    /// Tells the factory which task you're looking at, so others see you there.
    func viewing(_ id: String?) { send(.presence(.init(viewing: id))) }

    // MARK: HTTP

    /// A request to the factory with your token, for diffs and proof attachments.
    func request(_ path: String) -> URLRequest? {
        guard let server, let token else { return nil }
        return FactoryAPI(server: server, token: token).request(path)
    }

    /// Fetches a task's diff unless the one held is for the same change (`key`).
    func loadDiff(task id: String, key: String) async {
        if status == .demo { diffs[id] = (key, DemoData.diff(for: id)); return }
        guard diffs[id]?.key != key, let request = request("/api/tasks/\(id)/diff") else { return }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return }
        let files = await Task.detached { DiffFile.parse(String(decoding: data, as: UTF8.self)) }.value
        diffs[id] = (key, files)
    }

    /// An attachment's bytes (/attachments/<id>/<name>), with your token.
    func attachment(_ path: String) async -> Data? {
        guard let request = request(path) else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    // MARK: Demo

    /// Sample goals, tasks and machines, so the app renders fully with no server.
    func startDemo() {
        close()
        feed = DemoData.feed()
        status = .demo
    }

    /// The demo answers actions itself, the way a factory would.
    private func demoSend(_ message: Wire.ClientMessage) {
        func update(_ id: String, _ change: (inout Wire.Task) -> Void) {
            guard var task = feed.task(id) else { return }
            change(&task)
            task.updatedAt = DemoData.now
            feed.apply(.taskUpdated(.init(task: task)))
        }
        switch message {
        case .taskApprovePlan(let m):
            update(m.id) { $0.approvals.append(me); if $0.approvals.count >= $0.approvalsNeeded { $0.state = .building } }
            notice = .toast("Plan approved", taskId: m.id)
        case .taskApproveChanges(let m):
            update(m.id) { $0.reviews.append(me) }
            notice = .toast("Changes approved", taskId: m.id)
        case .taskMerge(let m):
            update(m.id) { $0.state = .merged; $0.mergeAt = nil }
            notice = .toast("Merged", taskId: m.id)
        case .taskHoldMerge(let m):
            update(m.id) { $0.mergeAt = nil }
        case .taskAnswer(let m):
            update(m.id) { $0.question = nil; $0.events.append(.init(who: me, text: "answered: \(m.text)", at: DemoData.now)) }
        case .taskResolveHand(let m):
            update(m.id) { $0.hand = nil; $0.events.append(.init(who: me, text: "resolved the hand: \(m.option ?? m.note)", at: DemoData.now)) }
        case .taskComment(let m):
            update(m.id) { $0.comments.append(.init(id: UUID().uuidString, author: me, text: m.text, at: DemoData.now)) }
        case .taskSteer(let m):
            update(m.id) { $0.changes.append(.init(id: UUID().uuidString, author: me, text: m.text, at: DemoData.now, status: .queued)) }
        case .taskPlan(let m):
            guard let state = feed.task(m.id)?.state, state == .drafting || state == .backlog else { return }
            update(m.id) { $0.state = .planning }
            notice = .toast("Sent to planning", taskId: m.id)
        case .taskBacklog(let m):
            guard let state = feed.task(m.id)?.state, state == .drafting || state == .awaitingApproval else { return }
            update(m.id) { $0.state = .backlog; $0.approvals = []; $0.waiting = nil }
            notice = .toast("Sent to the backlog", taskId: m.id)
        case .taskRankDraft(let m):
            guard let task = feed.task(m.id) else { return }
            let line = feed.tasks(in: task.goal).filter { $0.state == .drafting && $0.id != m.id }.sorted(by: Wire.Task.draftOrder)
            let target = m.before == "top" ? line.first : line.first { $0.id == m.before }
            let rank: Double
            if let target, let at = line.firstIndex(where: { $0.id == target.id }) {
                rank = at > 0 ? (line[at - 1].draftOrderRank + target.draftOrderRank) / 2 : target.draftOrderRank - 1000
            } else {
                rank = (line.map(\.draftOrderRank).max() ?? 0) + 1
            }
            update(m.id) { $0.draftRank = rank }
        case .goalFollow(let m):
            feed.follows[m.id] = m.following
        case .statsGet(let m):
            stats = DemoData.stats(days: Int(m.days))
        default:
            break
        }
    }
}

extension Wire.Task {
    /// Where a draft sits in its goal's drafts: its rank, or when it was made, as the factory orders them.
    var draftOrderRank: Double { draftRank ?? Double(createdAt) }

    /// A goal's drafts, first first.
    static func draftOrder(_ a: Wire.Task, _ b: Wire.Task) -> Bool {
        (a.draftOrderRank, a.id) < (b.draftOrderRank, b.id)
    }
}

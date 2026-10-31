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
    /// Answers the permission prompt the task's worker is waiting on: Yes or No in its session.
    func answerPrompt(_ id: String, choice: Wire.PromptChoice) { send(.taskAnswerPrompt(.init(id: id, choice: choice))) }
    /// Signs off a Done when item yourself (index from 0), with an optional note on why.
    func checkedIt(_ id: String, item: Int, note: String) {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        send(.taskCheckedIt(.init(id: id, item: UInt32(item), note: note.isEmpty ? nil : note)))
    }
    /// Asks the planner to change one of its mockups.
    func requestMockupChange(_ id: String, mockup: String, text: String) { send(.taskMockupChange(.init(id: id, mockup: mockup, text: text))) }
    func retryTask(_ id: String) { send(.taskRetry(.init(id: id))) }
    func cancel(_ id: String) { send(.taskCancel(.init(id: id))) }
    func follow(_ goal: String, _ following: Bool) { send(.goalFollow(.init(id: goal, following: following))) }
    /// Asks for the factory's statistics over the last `days`; the reply lands in `stats`.
    func loadStats(days: Int) { send(.statsGet(.init(days: UInt32(days), goal: nil))) }

    /// Starts a task in `goal`: handed to a planner now (`plan`), or kept as a draft. An empty brief
    /// sends the title as the brief, like the Mac's composer; `repo` counts only when it's one of the goal's.
    func createTask(goal: Wire.Goal, title: String, brief: String, repo: String?, priority: Wire.Priority?, plan: Bool) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let brief = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        send(.taskCreate(.init(goal: goal.id, title: title, brief: brief.isEmpty ? title : brief, shareable: false, plan: plan,
                               repo: repo.flatMap { goal.repos.contains($0) ? $0 : nil }, priority: priority)))
        notice = .toast(plan ? "Sent to planning" : "Saved as a draft", taskId: nil)
    }

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
        case .taskAnswerPrompt(let m):
            // The runner passes the answer to the session, which carries on.
            guard let worker = feed.task(m.id)?.worker, let mi = feed.machines.firstIndex(where: { $0.id == worker.machine }),
                  let si = feed.machines[mi].sessions.firstIndex(where: { $0.session.id == worker.session }) else { break }
            var machine = feed.machines[mi]
            machine.sessions[si].activity = .init(state: .working, message: m.choice == .yes ? "Allowed" : "Denied", at: DemoData.now)
            feed.apply(.machineUpdated(.init(machine: machine)))
        case .taskCheckedIt(let m):
            // As the server does: the item is proven by your word, with the note as its reason.
            guard let task = feed.task(m.id), task.doneWhen.indices.contains(Int(m.item)) else { break }
            let item = task.doneWhen[Int(m.item)]
            let reason = m.note
            update(m.id) {
                $0.doneWhen[Int(m.item)].status = .proven
                $0.doneWhen[Int(m.item)].evidence = .init(kind: item.proof, summary: "Attested by \(me)\(reason.map { ": \($0)" } ?? "")", by: me, at: DemoData.now, attested: true, reason: reason)
                $0.events.append(.init(who: me, text: "attested \"\(item.text)\"\(reason.map { ": \($0)" } ?? "")", at: DemoData.now))
            }
            notice = .toast("Marked as checked", taskId: m.id)
        case .taskMockupChange(let m):
            // As the server does: the mockup waits on a new version, the change is queued for the
            // planner, and a plan waiting for approval goes back to planning.
            guard let mockup = feed.task(m.id)?.mockups.first(where: { $0.id == m.mockup }) else { break }
            update(m.id) {
                if let i = $0.mockups.firstIndex(where: { $0.id == m.mockup }) { $0.mockups[i].status = .changesRequested }
                $0.changes.append(.init(id: "C\($0.changes.count + 1)", author: me, text: m.text, at: DemoData.now, anchor: "Mockup: \(mockup.title)", status: .queued))
                $0.events.append(.init(who: me, text: "asked for a change to the \"\(mockup.title)\" mockup", at: DemoData.now))
                if $0.state == .awaitingApproval { $0.approvals = []; $0.state = .planning }
            }
            notice = .toast("Change requested: the planner will post a new version", taskId: m.id)
        case .goalFollow(let m):
            feed.follows[m.id] = m.following
        case .taskCreate(let m):
            guard let goal = feed.goal(m.goal) else { return }
            let next = (feed.tasks(in: goal.id).compactMap { Int($0.id.split(separator: "-").last ?? "") }.max() ?? 0) + 1
            let task = Wire.Task(id: "\(goal.prefix)-\(next)", goal: goal.id, title: m.title, state: m.plan ? .planning : .drafting, owner: me,
                                 brief: m.brief, createdAt: DemoData.now, updatedAt: DemoData.now, planVersion: 0, approvalsNeeded: 1, reviewsNeeded: 1,
                                 events: [.init(who: me, text: "created the task", at: DemoData.now)],
                                 shareable: m.shareable, agent: m.agent ?? "claude", repo: m.repo, priority: m.priority)
            feed.apply(.taskUpdated(.init(task: task)))
        case .statsGet(let m):
            stats = DemoData.stats(days: Int(m.days))
        default:
            break
        }
    }
}

import Foundation
import Security

/// The app's connection to a real factory: who you are, the live machines, recent session ends, and
/// the goals and tasks. Views that were designed against mock data read the adapted copies
/// (`factoryTasks`, `factoryGoals`) when signed in.
@MainActor @Observable final class FactoryClient {
    enum Status: Equatable {
        case signedOut
        case connecting
        case live
        /// Lost the feed; trying again on a backoff.
        case reconnecting(attempt: Int, reason: String)
    }

    /// A session end as the feed reported it, kept newest first.
    struct EndRecord: Identifiable {
        let machine: String
        let end: Wire.SessionEnd
        var id: String { end.id }
    }

    private(set) var server: URL?
    private(set) var org = ""
    private(set) var me: Wire.Member?
    private(set) var machines: [Wire.Machine] = []
    private(set) var ends: [EndRecord] = []
    private(set) var members: [Wire.Member] = []
    private(set) var goals: [Wire.Goal] = []
    private(set) var tasks: [Wire.Task] = []
    /// The tasks and goals as the views' models, rebuilt when they change.
    private(set) var factoryTasks: [FactoryTask] = []
    private(set) var factoryGoals: [Goal] = []
    private(set) var online: [Wire.Presence] = []
    private(set) var intakeRequests: [Wire.IntakeRequest] = []
    /// Requests as the views' models, newest first.
    private(set) var intake: [IntakeRequest] = []
    /// Your Scratchpad, as the views' notes, newest first.
    private(set) var notes: [Note] = []
    /// Notes edited here whose save hasn't gone out yet; the server's echo of an older save mustn't undo typing.
    private var unsaved: [UUID: Task<Void, Never>] = [:]
    private(set) var policy: Wire.RiskPolicy?
    /// The org's repos: the GitHub App's, and any added by hand.
    private(set) var repos: [Wire.OrgRepo] = []

    /// Who this person keeps in their sidebar (Settings → People), per factory; nil until they pick.
    var sidebarPicks: [String]? {
        get { _ = picksChanged; return UserDefaults.standard.stringArray(forKey: picksKey) }
        set { UserDefaults.standard.set(newValue, forKey: picksKey); picksChanged += 1 }
    }
    private var picksChanged = 0
    private var picksKey: String { "sidebarPeople.\(server?.host() ?? "")\(server?.port.map { ":\($0)" } ?? "")" }

    /// The people in the sidebar: their picks, else whoever shares a GitHub team with them (everyone
    /// when they're on none). Always them first.
    var sidebarMembers: [Wire.Member] {
        guard let me else { return members }
        let others = members.filter { $0.login != me.login }
        let shown = sidebarPicks.map { picks in others.filter { picks.contains($0.login) } }
            ?? (me.teams.isEmpty ? others : others.filter { !Set($0.teams).isDisjoint(with: me.teams) })
        return [members.first { $0.login == me.login } ?? me] + shown
    }
    private(set) var acceptances: [Wire.RiskAcceptance] = []
    /// The policy and acceptances as the views' models.
    private(set) var riskPolicy: RiskPolicy?
    private(set) var riskAcceptances: [String: RiskAcceptance] = [:]
    /// A passing line from the factory ("ATL-3 merged"), for the app's toast.
    private(set) var toast: (text: String, taskID: String?, at: Date)?
    private(set) var status: Status = .signedOut
    /// The last thing the server refused, shown as a toast-like line.
    var notice: String?

    private var token: String?
    private var socket: URLSessionWebSocketTask?
    private var generation = 0
    private var attempt = 0

    var isSignedIn: Bool { server != nil && token != nil }

    /// The org's name, or the mockup's workspace when not signed in.
    var workspaceName: String {
        guard isSignedIn else { return "Studio Workspace" }
        return org.isEmpty || org == "local" ? server?.host() ?? "Factory" : org
    }

    init() {
        if let saved = UserDefaults.standard.string(forKey: "factoryURL"), let url = URL(string: saved),
           let token = Keychain.read(account: saved) {
            server = url
            self.token = token
            org = UserDefaults.standard.string(forKey: "factoryOrg") ?? ""
        }
    }

    // MARK: Session

    func signIn(_ result: SignInResult) {
        server = result.server
        token = result.token
        me = result.member
        org = result.org
        UserDefaults.standard.set(result.server.absoluteString, forKey: "factoryURL")
        UserDefaults.standard.set(result.org, forKey: "factoryOrg")
        Keychain.write(result.token, account: result.server.absoluteString)
        connect()
    }

    func signOut() {
        if let server { Keychain.delete(account: server.absoluteString) }
        UserDefaults.standard.removeObject(forKey: "factoryURL")
        disconnect()
        server = nil
        token = nil
        me = nil
        machines = []
        ends = []
        goals = []
        tasks = []
        rebuild()
        status = .signedOut
    }

    // MARK: Feed

    func connect() {
        guard let server, let token else { return }
        disconnect()
        generation += 1
        let gen = generation
        if status != .live { status = attempt == 0 ? .connecting : status }
        var request = URLRequest(url: Self.websocketURL(server, path: "/client/connect"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        self.socket = socket
        socket.resume()
        send(.subscribe)
        Task { await receive(socket, gen: gen) }
        Task { await keepAlive(socket, gen: gen) }
    }

    private func disconnect() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func receive(_ socket: URLSessionWebSocketTask, gen: Int) async {
        while gen == generation {
            do {
                let message = try await socket.receive()
                guard case .string(let text) = message, let data = text.data(using: .utf8) else { continue }
                apply(try JSONDecoder().decode(Wire.ServerToClient.self, from: data))
            } catch {
                guard gen == generation else { return }
                retry(reason: Self.describe(error, response: socket.response))
                return
            }
        }
    }

    /// Pings keep proxies from dropping a quiet socket, and notice a dead one sooner than TCP would.
    private func keepAlive(_ socket: URLSessionWebSocketTask, gen: Int) async {
        while gen == generation {
            try? await Task.sleep(for: .seconds(20))
            guard gen == generation else { return }
            socket.sendPing { _ in }
        }
    }

    private func retry(reason: String) {
        attempt += 1
        status = .reconnecting(attempt: attempt, reason: reason)
        for index in machines.indices { machines[index].online = false }
        let delay = min(pow(2, Double(min(attempt, 5))), 30)
        let gen = generation
        Task {
            try? await Task.sleep(for: .seconds(delay))
            if gen == generation { connect() }
        }
    }

    private func apply(_ message: Wire.ServerToClient) {
        switch message {
        case .snapshot(let snapshot):
            attempt = 0
            status = .live
            org = snapshot.org
            me = snapshot.me
            machines = snapshot.machines
            ends = snapshot.ended.map { EndRecord(machine: $0.machine, end: $0.end) }
            members = snapshot.members
            goals = snapshot.goals
            tasks = snapshot.tasks
            FactoryData.me = LiveAdapter.person(snapshot.me.login, members: members)
            policy = snapshot.policy
            acceptances = snapshot.acceptances
            online = snapshot.online
            notes = snapshot.notes.map(LiveAdapter.note)
            intakeRequests = snapshot.intake
            repos = snapshot.repos
            rebuild()
            if let viewing { send(.presence(.init(viewing: viewing))) }
        case .machineUpdated(let update):
            if let index = machines.firstIndex(where: { $0.id == update.machine.id }) {
                machines[index] = update.machine
            } else {
                machines.append(update.machine)
            }
        case .machineRemoved(let removed):
            machines.removeAll { $0.id == removed.id }
        case .sessionEnded(let ended):
            // The factory closing a session that reported back is how it's meant to go, not news.
            guard ended.end.by != "factory" else { break }
            ends.insert(EndRecord(machine: ended.machine, end: ended.end), at: 0)
            if ends.count > 50 { ends.removeLast(ends.count - 50) }
        case .taskUpdated(let update):
            if let index = tasks.firstIndex(where: { $0.id == update.task.id }) {
                tasks[index] = update.task
                factoryTasks[index] = adapt(update.task)
            } else {
                tasks.insert(update.task, at: 0)
                factoryTasks.insert(adapt(update.task), at: 0)
            }
        case .taskRemoved(let removed):
            tasks.removeAll { $0.id == removed.id }
            factoryTasks.removeAll { $0.id == removed.id }
        case .goalUpdated(let update):
            if let index = goals.firstIndex(where: { $0.id == update.goal.id }) {
                goals[index] = update.goal
            } else {
                goals.append(update.goal)
            }
            rebuild()
        case .intakeUpdated(let update):
            if let index = intakeRequests.firstIndex(where: { $0.id == update.request.id }) {
                intakeRequests[index] = update.request
            } else {
                intakeRequests.insert(update.request, at: 0)
            }
            intake = intakeRequests.map { LiveAdapter.request($0, goals: goals, members: members) }
        case .noteUpdated(let update):
            let note = LiveAdapter.note(update.note)
            guard unsaved[note.id] == nil else { break }
            if let index = notes.firstIndex(where: { $0.id == note.id }) { notes[index] = note } else { notes.insert(note, at: 0) }
        case .noteRemoved(let removed):
            notes.removeAll { $0.id.uuidString.lowercased() == removed.id.lowercased() }
        case .presence(let update):
            online = update.online
            applyPresence()
        case .reposUpdated(let update):
            repos = update.repos
        case .policyUpdated(let update):
            policy = update.policy
            acceptances = update.acceptances
            rebuild()
        case .toast(let toast):
            self.toast = (toast.text, toast.taskId, Date())
        case .error(let error):
            notice = error.message
        case .unknown:
            break
        }
    }

    private func adapt(_ task: Wire.Task) -> FactoryTask {
        var adapted = LiveAdapter.task(task, goals: goals, members: members, me: me?.login)
        adapted.viewers = online.filter { $0.viewing == task.id && $0.login != me?.login }.map { LiveAdapter.person($0.login, members: members) }
        return adapted
    }

    private func rebuild() {
        factoryGoals = goals.map { LiveAdapter.goal($0, members: members) }
        FactoryData.liveGoals = server == nil ? nil : factoryGoals
        FactoryData.livePeople = server == nil ? nil : members.map { LiveAdapter.person($0.login, members: members) }
        factoryTasks = tasks.map(adapt)
        applyPresence()
        intake = intakeRequests.map { LiveAdapter.request($0, goals: goals, members: members) }
        riskPolicy = policy.map(LiveAdapter.policy)
        riskAcceptances = Dictionary(acceptances.compactMap { a in
            goals.first { $0.id == a.goal }.map { goal in
                (goal.name, RiskAcceptance(autoMergeUpTo: LiveAdapter.riskLevel(a.upTo), acceptedBy: LiveAdapter.person(a.by, members: members),
                                           when: LiveAdapter.ago(a.at), note: a.note))
            }
        }, uniquingKeysWith: { a, _ in a })
    }

    func save(policy: RiskPolicy) {
        riskPolicy = policy
        send(.policySave(.init(policy: LiveAdapter.wire(policy))))
    }

    func acceptRisk(goal name: String, upTo: RiskLevel?, note: String?) {
        guard let goal = goal(named: name) else { return }
        send(.goalAcceptRisk(.init(goal: goal.id, upTo: upTo.map(LiveAdapter.wireLevel), note: note)))
    }

    /// Keeps edits to notes here at once and saves each one half a second after its last change.
    func update(notes edited: [Note]) {
        for note in edited where notes.first(where: { $0.id == note.id }).map({ $0.title != note.title || $0.body != note.body || $0.taskID != note.taskID }) ?? true {
            unsaved[note.id]?.cancel()
            unsaved[note.id] = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled, let me = self.me else { return }
                self.send(.noteSave(.init(note: LiveAdapter.wire(note, owner: me.login))))
                self.unsaved[note.id] = nil
            }
        }
        for gone in notes where !edited.contains(where: { $0.id == gone.id }) {
            send(.noteDelete(.init(id: gone.id.uuidString.lowercased())))
        }
        notes = edited
    }

    /// The task this app is showing, told to teammates.
    private var viewing: String?

    func view(task id: String?) {
        guard id != viewing else { return }
        viewing = id
        send(.presence(.init(viewing: id)))
    }

    /// Puts who's online on the sidebar and who's looking at each task on it.
    private func applyPresence() {
        let people = online.map { (person: LiveAdapter.person($0.login, members: members), viewing: $0.viewing) }
        FactoryData.livePresence = server == nil ? nil : people
        for index in factoryTasks.indices {
            let id = factoryTasks[index].id
            factoryTasks[index].viewers = people.filter { $0.viewing == id && $0.person.github != me?.login }.map(\.person)
        }
    }

    /// The goal a view knows by name.
    func goal(named name: String) -> Wire.Goal? { goals.first { $0.name == name } }

    func send(_ message: Wire.ClientMessage) {
        guard let socket, let data = try? JSONEncoder().encode(message), let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    // MARK: Commands

    func openSession(machine: String, agent: String, cwd: String) {
        send(.sessionOpen(.init(machine: machine, agent: agent, cwd: cwd, cols: 120, rows: 36)))
    }

    func killSession(machine: String, id: String) {
        send(.sessionKill(.init(machine: machine, id: id)))
    }

    /// The commands to run on a new machine, with a fresh one-time code.
    func enrollment() async throws -> Enrollment {
        try await api("/api/machines/enroll", method: "POST")
    }

    /// Forgets a machine and revokes its token. Its owner or an admin.
    func removeMachine(_ id: String) async {
        do {
            let _: Empty = try await api("/api/machines/\(id)", method: "DELETE")
        } catch {
            notice = FactoryClient.describe(error)
        }
    }

    private struct Empty: Decodable {}

    /// A socket request for one session's terminal.
    func terminalRequest(machine: String, session: String, cols: Int, rows: Int) -> URLRequest? {
        guard let server, let token else { return nil }
        var components = URLComponents(url: Self.websocketURL(server, path: "/client/terminal"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "machine", value: machine), .init(name: "session", value: session),
            .init(name: "cols", value: String(cols)), .init(name: "rows", value: String(rows)),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Each task's diff as last fetched, and the change it was fetched for.
    private(set) var diffs: [String: (key: String, files: [DiffFile])] = [:]

    /// Fetches a task's diff unless the one held is for the same change (`key`).
    /// Agent time per goal over the last week (`GET /api/usage/goals`).
    struct GoalTime: Decodable {
        struct TaskTime: Decodable { let id: String; let ms: Double }
        let goal: String
        let name: String
        let ms: Double
        let tasks: [TaskTime]
    }

    func goalTime() async -> [GoalTime] {
        (try? await api("/api/usage/goals")) ?? []
    }

    func loadDiff(task id: String, key: String) async {
        guard diffs[id]?.key != key, let server, let token else { return }
        var request = URLRequest(url: server.appending(path: "/api/tasks/\(id)/diff"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return }
        diffs[id] = (key, DiffFile.parse(String(decoding: data, as: UTF8.self)))
    }

    private func api<T: Decodable>(_ path: String, method: String = "GET") async throws -> T {
        guard let server, let token else { throw ClientError.message("Not signed in.") }
        var request = URLRequest(url: server.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await Self.load(request)
    }

    // MARK: Before signing in

    struct Health: Decodable {
        let ok: Bool
        let protocolVersion: Int
        let org: String?
        /// "github", "dev" (a local server signs you in as its DEV_LOGIN) or "unconfigured".
        let signIn: String
        let devLogin: String?

        enum CodingKeys: String, CodingKey { case ok, org, signIn, devLogin, protocolVersion = "protocol" }
    }

    struct SignInResult: Decodable {
        var server: URL = URL(string: "about:blank")!
        let token: String
        let member: Wire.Member
        let org: String

        enum CodingKeys: String, CodingKey { case token, member, org }
    }

    struct DeviceCode: Decodable {
        let deviceCode: String
        let userCode: String
        let verificationUri: URL
        let interval: Int
        let expiresIn: Int
    }

    struct Enrollment: Decodable {
        let code: String
        let expiresAt: Double
        let commands: [String]
    }

    enum ClientError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { text } else { nil } }
    }

    /// "localhost:8787" → http://localhost:8787; anything else is https unless it says otherwise.
    nonisolated static func serverURL(from typed: String) -> URL? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            let local = text.hasPrefix("localhost") || text.hasPrefix("127.0.0.1") || text.hasSuffix(".local") || text.contains(".local:")
            text = (local ? "http://" : "https://") + text
        }
        guard let url = URL(string: text), url.host() != nil else { return nil }
        return url
    }

    nonisolated static func websocketURL(_ server: URL, path: String) -> URL {
        var components = URLComponents(url: server.appending(path: path), resolvingAgainstBaseURL: false)!
        components.scheme = server.scheme == "https" ? "wss" : "ws"
        return components.url!
    }

    nonisolated static func probe(_ server: URL) async throws -> (Health, Duration) {
        let clock = ContinuousClock()
        let start = clock.now
        var request = URLRequest(url: server.appending(path: "/healthz"))
        request.timeoutInterval = 8
        let health: Health = try await load(request)
        return (health, clock.now - start)
    }

    nonisolated static func devSignIn(_ server: URL) async throws -> SignInResult {
        var request = URLRequest(url: server.appending(path: "/dev/token"))
        request.httpMethod = "POST"
        var result: SignInResult = try await load(request)
        result.server = server
        return result
    }

    nonisolated static func startDeviceFlow(_ server: URL) async throws -> DeviceCode {
        var request = URLRequest(url: server.appending(path: "/auth/device/start"))
        request.httpMethod = "POST"
        return try await load(request)
    }

    /// Nil while GitHub is still waiting on the person.
    nonisolated static func pollDeviceFlow(_ server: URL, code: String) async throws -> SignInResult? {
        var request = URLRequest(url: server.appending(path: "/auth/device/poll"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["deviceCode": code, "label": Host.current().localizedName ?? "Mac"])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 202 { return nil }
        guard status == 200 else { throw ClientError.message(String(data: data, encoding: .utf8) ?? "Sign-in failed (\(status)).") }
        var result = try JSONDecoder().decode(SignInResult.self, from: data)
        result.server = server
        return result
    }

    nonisolated private static func load<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 204 { return try JSONDecoder().decode(T.self, from: Data("{}".utf8)) }
        guard (200..<300).contains(status) else {
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ClientError.message(text.isEmpty || text.hasPrefix("<") ? "The server answered \(status)." : text)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ClientError.message("That doesn't look like a Maple factory.")
        }
    }

    nonisolated static func describe(_ error: Error, response: URLResponse? = nil) -> String {
        if let http = response as? HTTPURLResponse, http.statusCode == 401 { return "Your sign-in expired." }
        let ns = error as NSError
        switch ns.code {
        case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost: return "Can't reach the factory."
        case NSURLErrorNotConnectedToInternet: return "You're offline."
        case NSURLErrorTimedOut: return "The factory took too long to answer."
        case NSURLErrorNetworkConnectionLost: return "The connection dropped."
        default: return (error as? LocalizedError)?.errorDescription ?? ns.localizedDescription
        }
    }
}

/// The factory token, in the login keychain under the factory's URL. A plain-http (local dev)
/// factory's token goes in defaults instead: every rebuild of an unsigned dev app would otherwise
/// ask for keychain access, and a localhost dev token guards nothing.
enum Keychain {
    private static let service = "dev.maplefactory.app"
    private static let devKey = "devFactoryTokens"

    private static func isDev(_ account: String) -> Bool { account.hasPrefix("http://") }

    static func read(account: String) -> String? {
        if isDev(account) { return (UserDefaults.standard.dictionary(forKey: devKey) as? [String: String])?[account] }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        delete(account: account)
        if isDev(account) {
            var tokens = UserDefaults.standard.dictionary(forKey: devKey) as? [String: String] ?? [:]
            tokens[account] = value
            UserDefaults.standard.set(tokens, forKey: devKey)
            return
        }
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete(account: String) {
        if isDev(account) {
            var tokens = UserDefaults.standard.dictionary(forKey: devKey) as? [String: String] ?? [:]
            tokens[account] = nil
            UserDefaults.standard.set(tokens, forKey: devKey)
            return
        }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

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
            rebuild()
        case .machineUpdated(let update):
            if let index = machines.firstIndex(where: { $0.id == update.machine.id }) {
                machines[index] = update.machine
            } else {
                machines.append(update.machine)
            }
        case .machineRemoved(let removed):
            machines.removeAll { $0.id == removed.id }
        case .sessionEnded(let ended):
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
        case .toast(let toast):
            self.toast = (toast.text, toast.taskId, Date())
        case .error(let error):
            notice = error.message
        case .unknown:
            break
        }
    }

    private func adapt(_ task: Wire.Task) -> FactoryTask {
        LiveAdapter.task(task, goals: goals, members: members, me: me?.login)
    }

    private func rebuild() {
        factoryGoals = goals.map { LiveAdapter.goal($0, members: members) }
        FactoryData.liveGoals = server == nil ? nil : factoryGoals
        factoryTasks = tasks.map(adapt)
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

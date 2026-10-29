import AppKit
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
        /// The factory sent something this build can't read: it's newer than the app.
        case tooNew
    }

    /// A session end as the feed reported it, kept newest first.
    struct EndRecord: Identifiable {
        let machine: String
        let end: Wire.SessionEnd
        var id: String { end.id }
    }

    private(set) var server: URL?
    private(set) var org = ""
    /// Every factory signed into on this Mac, the current one among them. Each token stays in the
    /// Keychain under its factory's URL, so switching back doesn't ask to sign in again.
    private(set) var savedFactories: [SavedFactory] = [] {
        didSet { SavedFactories.store(savedFactories) }
    }
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
    /// Your Draft with AI runs, by id.
    private(set) var drafts: [String: Wire.Draft] = [:]
    /// Goals you chose to follow (true) or stop following (false), by id.
    private(set) var follows: [String: Bool] = [:]
    /// Notes edited here whose save hasn't gone out yet; the server's echo of an older save mustn't undo typing.
    private var unsaved: [UUID: Task<Void, Never>] = [:]
    private(set) var policy: Wire.RiskPolicy?
    /// The org's repos: the GitHub App's, and any added by hand.
    private(set) var repos: [Wire.OrgRepo] = []
    /// The newest released runner, when the factory has a release to offer.
    private(set) var runnerLatest: String?
    /// This factory's maple-server version, and a newer one when there is (admins only).
    private(set) var serverVersion: String?
    private(set) var serverUpdate: Wire.ServerUpdate?

    /// Who this person keeps in their sidebar (Settings → People), per factory; nil until they pick.
    var sidebarPicks: [String]? {
        get { _ = picksChanged; return AppDefaults.stringArray(forKey: picksKey) }
        set { AppDefaults.set(newValue, forKey: picksKey); picksChanged += 1 }
    }
    private var picksChanged = 0
    private var picksKey: String { "sidebarPeople.\(serverKey)" }

    /// The order this person put their sidebar goals in, by goal id, per factory; nil until they move one.
    var goalOrder: [String]? {
        get { _ = goalOrderChanged; return AppDefaults.stringArray(forKey: goalOrderKey) }
        set { AppDefaults.set(newValue, forKey: goalOrderKey); goalOrderChanged += 1 }
    }
    private var goalOrderChanged = 0
    private var goalOrderKey: String { "sidebarGoalOrder.\(serverKey)" }
    private var serverKey: String { "\(server?.host() ?? "")\(server?.port.map { ":\($0)" } ?? "")" }

    /// The people in the sidebar: their picks, else whoever shares a GitHub team with them (everyone
    /// when they're on none). Always them first.
    var sidebarMembers: [Wire.Member] {
        guard let me else { return members }
        let others = members.filter { $0.login != me.login }
        let shown = sidebarPicks.map { picks in others.filter { picks.contains($0.login) } }
            ?? (me.teams.isEmpty ? others : others.filter { !Set($0.teams).isDisjoint(with: me.teams) })
        return [members.first { $0.login == me.login } ?? me] + shown
    }

    /// The machines in the sidebar: yours, then teammates' that have team slots open. The Machines page
    /// still lists them all.
    var sidebarMachines: [Wire.Machine] { Self.sidebarMachines(machines, me: me?.login) }

    static func sidebarMachines(_ machines: [Wire.Machine], me: String?) -> [Wire.Machine] {
        guard let me else { return machines }
        let mine = machines.filter { $0.owner == me }
        let shared = machines.filter { $0.owner != me && isShared($0) }
        return mine + shared
    }

    /// Whether a machine lends anything to the team; one with no settings yet lends nothing.
    static func isShared(_ machine: Wire.Machine) -> Bool {
        guard let settings = machine.settings else { return false }
        return settings.teamSlots > 0 || settings.lendIdle
    }
    private(set) var acceptances: [Wire.RiskAcceptance] = []
    /// The policy and acceptances as the views' models.
    private(set) var riskPolicy: RiskPolicy?
    private(set) var riskAcceptances: [String: RiskAcceptance] = [:]
    /// A passing line from the factory ("ATL-3 merged"), for the app's toast.
    private(set) var toast: (text: String, taskID: String?, at: Date)?
    private(set) var status: Status = .signedOut
    /// Whether this factory's first snapshot has landed. A reconnect keeps it, so the old content stays up.
    private(set) var hasSnapshot = false
    /// The last thing the server refused, shown as a toast-like line.
    var notice: String?

    private var token: String?
    private var socket: URLSessionWebSocketTask?
    private var generation = 0
    private var attempt = 0
    /// When the feed last answered: a message, or a pong to a keep-alive ping.
    private var lastHeard = Date()

    var isSignedIn: Bool { server != nil && token != nil }

    /// The org's name, or the mockup's workspace when not signed in.
    var workspaceName: String {
        guard isSignedIn else { return "Studio Workspace" }
        return org.isEmpty || org == "local" ? server?.host() ?? "Factory" : org
    }

    init() {
        let defaults = AppDefaults
        savedFactories = SavedFactories.migrate(SavedFactories.load(), currentURL: defaults.string(forKey: "factoryURL"),
                                                currentOrg: defaults.string(forKey: "factoryOrg"))
        if let saved = defaults.string(forKey: "factoryURL"), let url = URL(string: saved),
           let token = Keychain.read(account: saved) {
            server = url
            self.token = token
            org = defaults.string(forKey: "factoryOrg") ?? ""
        }
        // A socket can die quietly while the Mac sleeps or the app sits in the background; catch up
        // with a fresh snapshot rather than leave every list as it was.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.catchUp(force: true) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.catchUp(force: false) }
        }
    }

    /// Reconnects (and so resubscribes) after a wake, or when the feed has been quiet longer than its pings allow.
    private func catchUp(force: Bool) {
        guard isSignedIn, force || Date().timeIntervalSince(lastHeard) > 45 else { return }
        attempt = 0
        connect()
    }

    /// Shows a change before the factory echoes it (a card dropped in the queue lands at once);
    /// the task's next `task.updated` replaces it with what the factory did.
    func expect(_ id: String, _ change: (inout FactoryTask) -> Void) {
        guard let index = factoryTasks.firstIndex(where: { $0.id == id }) else { return }
        change(&factoryTasks[index])
    }

    // MARK: Session

    func signIn(_ result: SignInResult) {
        if result.server != server { resetFactoryState() }
        server = result.server
        token = result.token
        me = result.member
        org = result.org
        AppDefaults.set(result.server.absoluteString, forKey: "factoryURL")
        AppDefaults.set(result.org, forKey: "factoryOrg")
        Keychain.write(result.token, account: result.server.absoluteString)
        remember()
        connect()
    }

    /// Opens another saved factory with its kept token. False when there's no token for it, so the
    /// caller can send the person to sign in again.
    @discardableResult
    func switchTo(_ factory: SavedFactory) -> Bool {
        guard SavedFactory.key(factory.server) != serverKey || !isSignedIn else { return true }
        guard let token = Keychain.read(account: factory.server.absoluteString) else { return false }
        disconnect()
        resetFactoryState()
        server = factory.server
        self.token = token
        org = factory.org
        AppDefaults.set(factory.server.absoluteString, forKey: "factoryURL")
        AppDefaults.set(factory.org, forKey: "factoryOrg")
        remember()
        connect()
        return true
    }

    /// Signs out of this factory only; the most recent other one opens in its place, when there is one.
    func signOut() {
        if let server {
            Keychain.delete(account: server.absoluteString)
            savedFactories = SavedFactories.remove(server, from: savedFactories)
        }
        if let next = SavedFactories.fallback(savedFactories), switchTo(next) { return }
        AppDefaults.removeObject(forKey: "factoryURL")
        AppDefaults.removeObject(forKey: "factoryOrg")
        disconnect()
        generation += 1
        server = nil
        token = nil
        resetFactoryState()
        status = .signedOut
    }

    /// Puts the current factory at the front of the saved list, as the last one used.
    private func remember() {
        guard let server else { return }
        savedFactories = SavedFactories.upsert(SavedFactory(server: server, org: org, name: workspaceName, lastUsed: Date()), into: savedFactories)
    }

    /// Forgets everything the last factory sent, so none of it shows under the next one.
    private func resetFactoryState() {
        for task in unsaved.values { task.cancel() }
        unsaved = [:]
        me = nil
        machines = []
        ends = []
        members = []
        goals = []
        tasks = []
        online = []
        intakeRequests = []
        notes = []
        drafts = [:]
        follows = [:]
        policy = nil
        acceptances = []
        repos = []
        runnerLatest = nil
        serverVersion = nil
        serverUpdate = nil
        toast = nil
        notice = nil
        viewing = nil
        attempt = 0
        rebuild()
        hasSnapshot = false
        status = .connecting
    }

    // MARK: Feed

    func connect() {
        guard let server, let token else { return }
        disconnect()
        generation += 1
        let gen = generation
        if status != .live && status != .tooNew { status = attempt == 0 ? .connecting : status }
        var request = URLRequest(url: Self.websocketURL(server, path: "/client/connect"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        self.socket = socket
        lastHeard = Date()
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
                lastHeard = Date()
                guard case .string(let text) = message, let data = text.data(using: .utf8) else { continue }
                apply(try JSONDecoder().decode(Wire.ServerToClient.self, from: data))
            } catch {
                guard gen == generation else { return }
                if error is DecodingError {
                    NSLog("Maple Factory: can't read the factory's message: \(error)")
                    tooNew()
                    return
                }
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
            socket.sendPing { error in
                guard error == nil else { return }
                Task { @MainActor in self.lastHeard = Date() }
            }
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

    /// Only an app update (or the server rolling back) fixes a message this build can't read, so this
    /// tries again slowly rather than on the usual backoff.
    private func tooNew() {
        disconnect()
        status = .tooNew
        for index in machines.indices { machines[index].online = false }
        let gen = generation
        Task {
            try? await Task.sleep(for: .seconds(60))
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
            follows = Dictionary(snapshot.follows.map { ($0.goal, $0.following) }, uniquingKeysWith: { _, last in last })
            intakeRequests = snapshot.intake
            repos = snapshot.repos
            runnerLatest = snapshot.runnerLatest
            serverVersion = snapshot.serverVersion
            serverUpdate = snapshot.serverUpdate
            rebuild()
            hasSnapshot = true
            remember()
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
            let previous = tasks.first { $0.id == update.task.id }
            defer { notify(was: previous, now: update.task) }
            if let index = tasks.firstIndex(where: { $0.id == update.task.id }) {
                tasks[index] = update.task
                factoryTasks[index] = adapt(update.task)
            } else {
                tasks.insert(update.task, at: 0)
                factoryTasks.insert(adapt(update.task), at: 0)
                // A new task of yours puts its goal in your sidebar.
                if update.task.owner == me?.login { rebuildGoals() }
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
        case .draftUpdated(let update):
            drafts[update.draft.id] = update.draft
        case .followsUpdated(let update):
            follows = Dictionary(update.follows.map { ($0.goal, $0.following) }, uniquingKeysWith: { _, last in last })
            rebuildGoals()
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

    /// A banner when a task newly needs you; the snapshot never calls this, so reconnecting stays quiet.
    private func notify(was old: Wire.Task?, now task: Wire.Task) {
        let me = me?.login
        let needed = old.map { LiveAdapter.needsYou($0, me: me) } ?? false
        let needs = LiveAdapter.needsYou(task, me: me)
        let handRaised = old?.hand == nil && task.hand != nil && task.hand?.assignee == me
        guard needs else {
            if needed { Notifier.shared.clear(task: task.id) }
            return
        }
        guard !needed || handRaised else { return }
        let reason: Notifier.Reason
        if task.hand?.assignee == me, let hand = factoryTasks.first(where: { $0.id == task.id })?.hand {
            reason = .hand(hand.reason)
        } else if task.question != nil && task.owner == me {
            reason = .question
        } else if task.state == .awaitingApproval {
            reason = .approval
        } else {
            reason = .review
        }
        Notifier.shared.notify(task: task, reason: reason)
    }

    private func adapt(_ task: Wire.Task) -> FactoryTask {
        var adapted = LiveAdapter.task(task, goals: goals, members: members, me: me?.login)
        adapted.viewers = online.filter { $0.viewing == task.id && $0.login != me?.login }.map { LiveAdapter.person($0.login, members: members) }
        return adapted
    }

    /// Whether a goal is in your sidebar: what you chose, else whether you lead it, are on its team,
    /// or own or reviewed a task in it.
    func isFollowing(_ goal: Wire.Goal) -> Bool {
        if let chosen = follows[goal.id] { return chosen }
        guard let me else { return true }
        if goal.lead == me.login { return true }
        if let team = goal.team, me.teams.contains(where: { $0.caseInsensitiveCompare(team) == .orderedSame }) { return true }
        return tasks.contains { $0.goal == goal.id && ($0.owner == me.login || $0.reviews.contains(me.login)) }
    }

    func follow(goal name: String, _ following: Bool) {
        guard let goal = goal(named: name) else { return }
        follows[goal.id] = following
        rebuildGoals()
        send(.goalFollow(.init(id: goal.id, following: following)))
    }

    /// Every GitHub team someone in the org is on, for a goal's team.
    var teams: [String] { Array(Set(members.flatMap(\.teams) + (me?.teams ?? []))).sorted() }

    private func rebuildGoals() {
        factoryGoals = goals.map { LiveAdapter.goal($0, members: members, following: isFollowing($0)) }
        FactoryData.liveGoals = server == nil ? nil : factoryGoals
    }

    private func rebuild() {
        rebuildGoals()
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
            // A save still waiting out its delay would otherwise go after the delete and bring the note back.
            unsaved[gone.id]?.cancel()
            unsaved[gone.id] = nil
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

    /// A file pasted or dropped into a brief or note, as the factory keeps it (`POST /api/attachments`).
    struct Attachment: Decodable {
        let id: String
        let name: String
        let mime: String
        let size: Int
        /// `/attachments/<id>/<name>`: what the note links to.
        let path: String
    }

    /// The factory's limit for one attachment.
    nonisolated static let maxAttachment = 25 * 1024 * 1024

    func upload(data: Data, filename: String, mime: String) async throws -> Attachment {
        guard let server, let token else { throw ClientError.message("Not signed in.") }
        guard data.count <= Self.maxAttachment else { throw ClientError.message("It's over 25 MB.") }
        var components = URLComponents(url: server.appending(path: "/api/attachments"), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "name", value: filename)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(mime, forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        return try await Self.load(request)
    }

    /// Attachments fetched this run, by path; they never change once stored.
    private static let attachmentCache = NSCache<NSString, NSData>()

    /// An attachment's bytes (`/attachments/…`), with this app's token: AsyncImage can't send one.
    func attachment(_ path: String) async throws -> Data {
        if let cached = Self.attachmentCache.object(forKey: path as NSString) { return cached as Data }
        guard let server, let token else { throw ClientError.message("Not signed in.") }
        guard Self.attachmentLink(path) != nil, let url = URL(string: path, relativeTo: server)?.absoluteURL else {
            throw ClientError.message("Not an attachment.")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ClientError.message(status == 404 ? "It isn't there anymore." : "The server answered \(status).") }
        Self.attachmentCache.setObject(data as NSData, forKey: path as NSString)
        return data
    }

    /// `/attachments/<uuid>/<name>`, as the server's LINK pattern has it: its id and name, or nil for
    /// anything else (`..`, other server paths), so the token never goes elsewhere.
    nonisolated static func attachmentLink(_ path: String) -> (id: String, name: String)? {
        guard let match = path.wholeMatch(of: /\/attachments\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\/([\w.\-]{1,120})/),
              !match.2.contains(".."), !match.2.hasPrefix(".") else { return nil }
        return (String(match.1), String(match.2))
    }

    /// Opened in their app with a click; anything else (scripts, .command, .app, .jar…) is only shown in Finder.
    nonisolated static let safeToOpen: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "pdf",
                                                      "txt", "log", "md", "json", "csv", "mp4", "mov", "webm"]

    /// Saves an attachment to a temporary folder, quarantined like a browser download, then opens it in
    /// its app if it's a known-safe type or shows it in Finder otherwise.
    func open(attachment path: String) async {
        do {
            guard let link = Self.attachmentLink(path) else { throw ClientError.message("Not an attachment.") }
            let data = try await attachment(path)
            let folder = FileManager.default.temporaryDirectory.appending(path: "maple-attachments/\(link.id)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: link.name)
            try data.write(to: file)
            Self.quarantine(file)
            if Self.safeToOpen.contains(file.pathExtension.lowercased()) {
                NSWorkspace.shared.open(file)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([file])
            }
        } catch {
            notice = Self.describe(error)
        }
    }

    /// Marks a file as downloaded (`com.apple.quarantine`), so Gatekeeper checks it before it runs.
    nonisolated static func quarantine(_ file: URL) {
        let stamp = String(format: "0083;%08x;Maple Factory;", Int(Date().timeIntervalSince1970))
        _ = file.withUnsafeFileSystemRepresentation { path in
            stamp.withCString { setxattr(path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
        }
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

    nonisolated static let tooNewMessage = "This factory is newer than this app — update Maple Factory."

    nonisolated static func describe(_ error: Error, response: URLResponse? = nil) -> String {
        if let http = response as? HTTPURLResponse, http.statusCode == 401 { return "Your sign-in expired." }
        if error is DecodingError { return tooNewMessage }
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

/// A factory signed into on this Mac. Its token is in the Keychain under `server`.
struct SavedFactory: Codable, Equatable, Identifiable, Sendable {
    var server: URL
    var org: String
    /// The org's name, or the host when it has none.
    var name: String
    var lastUsed: Date

    var id: String { Self.key(server) }
    var host: String { id }

    /// One entry per host and port: http and https to the same place are the same factory.
    static func key(_ url: URL) -> String { "\(url.host() ?? "")\(url.port.map { ":\($0)" } ?? "")" }
}

/// The saved-factory list's rules, kept pure so they can be tested; stored in defaults under `factories`.
enum SavedFactories {
    static let defaultsKey = "factories"

    static func load(_ defaults: UserDefaults = AppDefaults) -> [SavedFactory]? {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode([SavedFactory].self, from: $0) }
    }

    static func store(_ list: [SavedFactory], _ defaults: UserDefaults = AppDefaults) {
        defaults.set(try? JSONEncoder().encode(list), forKey: defaultsKey)
    }

    /// The list as saved, or, before there was one, the single factory this Mac was signed into.
    static func migrate(_ saved: [SavedFactory]?, currentURL: String?, currentOrg: String?, now: Date = Date()) -> [SavedFactory] {
        if let saved { return saved }
        guard let currentURL, let url = URL(string: currentURL), url.host() != nil else { return [] }
        let org = currentOrg ?? ""
        let name = org.isEmpty || org == "local" ? url.host() ?? "Factory" : org
        return [SavedFactory(server: url, org: org, name: name, lastUsed: now)]
    }

    /// Adds the factory, or replaces the entry for the same host and port where it stands.
    static func upsert(_ factory: SavedFactory, into list: [SavedFactory]) -> [SavedFactory] {
        var list = list
        if let index = list.firstIndex(where: { $0.id == factory.id }) {
            list[index] = factory
        } else {
            list.append(factory)
        }
        return list
    }

    static func remove(_ server: URL, from list: [SavedFactory]) -> [SavedFactory] {
        list.filter { $0.id != SavedFactory.key(server) }
    }

    /// The factory to open after signing out of one: the most recently used of those left.
    static func fallback(_ list: [SavedFactory]) -> SavedFactory? {
        list.max { $0.lastUsed < $1.lastUsed }
    }
}

/// The factory token, in the login keychain under the factory's URL. A plain-http (local dev)
/// factory's token goes in defaults instead: every rebuild of an unsigned dev app would otherwise
/// ask for keychain access, and a localhost dev token guards nothing. A headless run keeps every
/// token in its own wiped defaults, so it never replaces the real app's keychain item for a URL.
enum Keychain {
    private static let service = "dev.maplefactory.app"
    private static let devKey = "devFactoryTokens"

    static func isDev(_ account: String, headless: Bool = Headless.isOn) -> Bool { headless || account.hasPrefix("http://") }

    static func read(account: String) -> String? {
        if isDev(account) { return (AppDefaults.dictionary(forKey: devKey) as? [String: String])?[account] }
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
            var tokens = AppDefaults.dictionary(forKey: devKey) as? [String: String] ?? [:]
            tokens[account] = value
            AppDefaults.set(tokens, forKey: devKey)
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
            var tokens = AppDefaults.dictionary(forKey: devKey) as? [String: String] ?? [:]
            tokens[account] = nil
            AppDefaults.set(tokens, forKey: devKey)
            return
        }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

extension FactoryClient {
    /// Whether the machine's runner is older than the latest release ("0.2.0" < "0.10.1").
    func runnerOutdated(_ machine: Wire.Machine) -> Bool {
        guard let version = machine.version, let latest = runnerLatest else { return false }
        let parts = { (v: String) in v.split(separator: "-")[0].split(separator: ".").map { Int($0) ?? 0 } }
        let (a, b) = (parts(version), parts(latest))
        for i in 0..<max(a.count, b.count) {
            let (x, y) = (i < a.count ? a[i] : 0, i < b.count ? b[i] : 0)
            if x != y { return x < y }
        }
        return false
    }
}

extension FactoryClient {
    /// This Mac's machine in this factory, when its runner is enrolled here.
    var thisMac: Wire.Machine? {
        guard let server, LocalRunner.isEnrolled(with: server), let id = LocalRunner.enrolled?.runnerId else { return nil }
        return machines.first { $0.id == id }
    }
}

extension FactoryClient {
    /// A machine's nickname (or id, when it has none or isn't known).
    func machineName(_ id: String) -> String {
        machines.first { $0.id == id }?.name ?? id
    }
}

extension FactoryClient {
    /// What the task's worker session is doing, from its machine's live sessions: nil when there's no
    /// worker, its machine isn't known, or the machine doesn't list that session.
    func workerActivity(for worker: FactoryTask.Worker?) -> Wire.Activity? {
        guard let worker else { return nil }
        return machines.first { $0.id == worker.machine }?.sessions.first { $0.session.id == worker.session }?.activity ?? nil
    }

    /// Answers the permission prompt the task's worker is waiting on: Yes or No in its session.
    func answerPrompt(taskID: String, choice: Wire.PromptChoice) {
        send(.taskAnswerPrompt(.init(id: taskID, choice: choice)))
    }
}

/// What a waiting agent wants permission for, from the runner's `question.permission`.
struct PermissionPrompt: Equatable {
    let tool: String
    let summary: String
    let detail: String?
    let warning: String?
}

extension Wire.Activity {
    /// The permission prompt it's stopped at, when it's waiting on one.
    var permission: PermissionPrompt? {
        guard state == .waiting, case .object(let q)? = question, case .object(let p)? = q["permission"], case .string(let tool)? = p["tool"] else { return nil }
        let text = { (key: String) -> String? in
            if case .string(let s)? = p[key], !s.isEmpty { return s }
            return nil
        }
        return PermissionPrompt(tool: tool, summary: text("summary") ?? tool, detail: text("detail"), warning: text("warning"))
    }
}
